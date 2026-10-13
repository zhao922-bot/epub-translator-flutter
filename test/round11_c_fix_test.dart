import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/io/settings_file_lock.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// Round 11, area C regression tests (Spark).
// ---------------------------------------------------------------------------

class _FakeSecretStore implements SettingsSecretStore {
  final Map<SettingsSecretSlot, String?> values = {};
  bool hangReads = false;
  bool hangWrites = false;

  Future<void> _maybeHang(bool hang) async {
    if (hang) await Completer<void>().future;
  }

  @override
  Future<String?> readApiKey() async {
    await _maybeHang(hangReads);
    return values[SettingsSecretSlot.legacy];
  }

  @override
  Future<void> writeApiKey(String value) async {
    await _maybeHang(hangWrites);
    values[SettingsSecretSlot.legacy] = value;
  }

  @override
  Future<void> deleteApiKey() async {
    await _maybeHang(hangWrites);
    values.remove(SettingsSecretSlot.legacy);
  }

  @override
  Future<String?> readDeepSeekApiKey() async {
    await _maybeHang(hangReads);
    return values[SettingsSecretSlot.deepSeek];
  }

  @override
  Future<void> writeDeepSeekApiKey(String value) async {
    await _maybeHang(hangWrites);
    values[SettingsSecretSlot.deepSeek] = value;
  }

  @override
  Future<void> deleteDeepSeekApiKey() async {
    await _maybeHang(hangWrites);
    values.remove(SettingsSecretSlot.deepSeek);
  }

  @override
  Future<String?> readCustomApiKey() async {
    await _maybeHang(hangReads);
    return values[SettingsSecretSlot.custom];
  }

  @override
  Future<void> writeCustomApiKey(String value) async {
    await _maybeHang(hangWrites);
    values[SettingsSecretSlot.custom] = value;
  }

  @override
  Future<void> deleteCustomApiKey() async {
    await _maybeHang(hangWrites);
    values.remove(SettingsSecretSlot.custom);
  }

  @override
  Future<String?> readProxyAuthentication() async {
    await _maybeHang(hangReads);
    return values[SettingsSecretSlot.proxy];
  }

  @override
  Future<void> writeProxyAuthentication(String value) async {
    await _maybeHang(hangWrites);
    values[SettingsSecretSlot.proxy] = value;
  }

  @override
  Future<void> deleteProxyAuthentication() async {
    await _maybeHang(hangWrites);
    values.remove(SettingsSecretSlot.proxy);
  }
}

Future<List<File>> _badHistoryBackups(Directory temp) => temp
    .list()
    .where(
      (entity) =>
          entity is File &&
          p.basename(entity.path).startsWith('job-history.json.bad-'),
    )
    .cast<File>()
    .toList();

void main() {
  group('P1-#3 corrupt-history restore race', () {
    test(
      'restore does not overwrite a history committed during the race window',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p13_');
        addTearDown(() => temp.delete(recursive: true));
        final file = File(p.join(temp.path, 'job-history.json'));
        final store = JobHistoryStore(historyFileProvider: () async => file);

        await file.writeAsString('NOT-JSON{{{');
        final repaired = jsonEncode(<String, Object?>{
          'version': 2,
          'clearedAt': 1,
          'jobs': <Object?>[],
        });
        final newer = jsonEncode(<String, Object?>{
          'version': 2,
          'clearedAt': 2,
          'jobs': <Object?>[],
        });
        store.onBeforeCorruptRenameForTest = () async {
          // Writer B repairs the file between the precheck and the rename.
          await file.writeAsString(repaired);
        };
        // Hold the cross-process history lock from a *separate process* so
        // the restore branch blocks inside it (POSIX locks are per-process,
        // so the same-process lock would not block); writer C commits a
        // newer history while it is blocked.
        final lockPath = '${file.path}.lock';
        final helper = File(p.join(temp.path, 'hold_lock.dart'));
        await helper.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final handle = await File(args[0]).open(mode: FileMode.write);
  await handle.lock(FileLock.exclusive);
  print('LOCKED');
  await stdin.first;
  await handle.unlock();
  await handle.close();
}
''');
        final holder = await Process.start('dart', [
          helper.path,
          lockPath,
        ]);
        addTearDown(() => holder.kill());
        await holder.stdout
            .transform(const SystemEncoding().decoder)
            .firstWhere((line) => line.contains('LOCKED'));
        final loadFuture = store.loadWithTombstone();
        // Wait until the loader is blocked in the restore branch: it has
        // renamed the repaired file aside (file absent) but not yet
        // completed.
        for (int i = 0; i < 100 && await file.exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(await file.exists(), isFalse);
        // Writer C commits a newer history during the race window.
        await file.writeAsString(newer);
        holder.stdin.close();
        await loadFuture;

        // The newer history wins; it is not overwritten by the stale backup.
        expect(await file.readAsString(), newer);
        // The moved-aside repaired history is preserved as a backup.
        final backups = await _badHistoryBackups(temp);
        expect(backups, hasLength(1));
        expect(await backups.single.readAsString(), repaired);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('P1-#4 legacy credential slot attribution', () {
    test(
      'lost settings.json does not rebind a legacy key to the default DeepSeek slot',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p14_');
        addTearDown(() => temp.delete(recursive: true));
        final secrets = _FakeSecretStore();
        // A Custom user's key from before the provider-slot migration,
        // living only in the legacy slot.
        secrets.values[SettingsSecretSlot.legacy] = 'sk-legacy-custom-key';
        // No settings.json: the provider association is unknown.
        final store = SettingsStore(
          settingsFileProvider: () async =>
              File(p.join(temp.path, 'settings.json')),
          secretStore: secrets,
        );

        final config = await store.load();

        // Nothing is filled cross-slot: the key must not end up in the
        // default DeepSeek slot (which would send it to api.deepseek.com).
        expect(config.deepseekApiKey, isEmpty);
        expect(config.customApiKey, isEmpty);
        expect(config.apiKey, isEmpty);
        expect(secrets.values[SettingsSecretSlot.deepSeek], isNull);
        expect(secrets.values[SettingsSecretSlot.custom], isNull);
        // The legacy key itself is preserved, not deleted or moved.
        expect(
          secrets.values[SettingsSecretSlot.legacy],
          'sk-legacy-custom-key',
        );
      },
    );

    test(
      'existing settings.json keeps the legacy key on its own provider slot',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p14b_');
        addTearDown(() => temp.delete(recursive: true));
        final secrets = _FakeSecretStore();
        secrets.values[SettingsSecretSlot.legacy] = 'sk-legacy-custom-key';
        final file = File(p.join(temp.path, 'settings.json'));
        await file.writeAsString(
          jsonEncode(
            TranslationConfig.defaults()
                .copyWith(apiProviderSelection: ApiProviderSelection.custom)
                .toJson(),
          ),
        );
        final store = SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );

        final config = await store.load();

        // The trusted provider association (custom) is honored.
        expect(config.customApiKey, 'sk-legacy-custom-key');
        expect(config.deepseekApiKey, isEmpty);
      },
    );
  });

  group('P2-#25 undecodable history bytes', () {
    test(
      'invalid UTF-8 inside a JSON string takes the backup path',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p25_');
        addTearDown(() => temp.delete(recursive: true));
        final file = File(p.join(temp.path, 'job-history.json'));
        final store = JobHistoryStore(historyFileProvider: () async => file);
        // Invalid UTF-8 inside a JSON string value: allowMalformed would
        // substitute U+FFFD and jsonDecode would still succeed.
        final bytes = <int>[
          ...utf8.encode('{"version":2,"clearedAt":0,"jobs":[{"id":"a'),
          0xff,
          ...utf8.encode('b","inputPath":"x","outputPath":"y"}]}'),
        ];
        await file.writeAsBytes(bytes);

        final loaded = await store.loadWithTombstone();

        expect(loaded.jobs, isEmpty);
        // The original bytes are preserved in a backup, not silently
        // overwritten by the U+FFFD-substituted text on the next save.
        expect(await file.exists(), isFalse);
        final backups = await _badHistoryBackups(temp);
        expect(backups, hasLength(1));
        expect(await backups.single.readAsBytes(), bytes);
      },
    );
  });

  group('P2-#34 structurally invalid history', () {
    test(
      'valid JSON with a non-list jobs node is backed up, not silently emptied',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p34_');
        addTearDown(() => temp.delete(recursive: true));
        final file = File(p.join(temp.path, 'job-history.json'));
        final store = JobHistoryStore(historyFileProvider: () async => file);
        const bad = '{"version":2,"jobs":{"not":"a list"}}';
        await file.writeAsString(bad);

        final loaded = await store.loadWithTombstone();

        expect(loaded.jobs, isEmpty);
        expect(await file.exists(), isFalse);
        final backups = await _badHistoryBackups(temp);
        expect(backups, hasLength(1));
        expect(await backups.single.readAsString(), bad);
      },
    );

    test('saveMerged backs up structurally invalid history', () async {
      final temp = await Directory.systemTemp.createTemp('c11_p34b_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(p.join(temp.path, 'job-history.json'));
      final store = JobHistoryStore(historyFileProvider: () async => file);
      const bad = '{"version":2,"jobs":{"not":"a list"}}';
      await file.writeAsString(bad);

      // saveMerged must not silently merge "empty" over the bad file.
      final result = await store.saveMerged(
        merge: (jobs, clearedAt) => jobs,
        clearedAtEpochMs: 0,
      );

      expect(result.written, isTrue);
      final backups = await _badHistoryBackups(temp);
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), bad);
    });
  });

  group('P2-#32 secret store timeout', () {
    test(
      'a hung secret read fails instead of hanging the load forever',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p32_');
        addTearDown(() => temp.delete(recursive: true));
        final secrets = _FakeSecretStore()..hangReads = true;
        final store = SettingsStore(
          settingsFileProvider: () async =>
              File(p.join(temp.path, 'settings.json')),
          secretStore: secrets,
        );

        // Must complete (with per-slot read failures), not hang.
        final config = await store
            .load()
            .timeout(
              const Duration(seconds: 45),
              onTimeout: () => throw StateError('load hung'),
            );

        expect(config, isA<TranslationConfig>());
        expect(
          store.secretReadFailed(SettingsSecretSlot.deepSeek),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a hung secret write fails instead of hanging the save forever',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p32b_');
        addTearDown(() => temp.delete(recursive: true));
        final secrets = _FakeSecretStore()..hangWrites = true;
        final file = File(p.join(temp.path, 'settings.json'));
        final store = SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        await store.load();

        await expectLater(
          store
              .save(
                TranslationConfig.defaults().copyWith(
                  deepseekApiKey: 'sk-test',
                ),
                explicitSecretMutations: const {SettingsSecretSlot.deepSeek},
              )
              .timeout(
                const Duration(seconds: 45),
                onTimeout: () => throw StateError('save hung'),
              ),
          throwsA(isA<SettingsSecretSaveException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('P2-#31 settings file lock cross-isolate note', () {
    test(
      'concurrent lock holders on the same path are serialized in-process',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p31_');
        addTearDown(() => temp.delete(recursive: true));
        final file = File(p.join(temp.path, 'settings.json'));
        final order = <String>[];
        await Future.wait([
          withSettingsFileLock(file, () async {
            order.add('first-enter');
            await Future<void>.delayed(const Duration(milliseconds: 100));
            order.add('first-exit');
          }),
          withSettingsFileLock(file, () async {
            order.add('second-enter');
            order.add('second-exit');
          }),
        ]);
        expect(order, [
          'first-enter',
          'first-exit',
          'second-enter',
          'second-exit',
        ]);
      },
    );
  });

  group('P2-#33 lock acquisition uses a monotonic clock', () {
    test(
      'a held lock times out the waiter instead of blocking forever',
      () async {
        final temp = await Directory.systemTemp.createTemp('c11_p33_');
        addTearDown(() => temp.delete(recursive: true));
        final file = File(p.join(temp.path, 'settings.json'));
        await file.parent.create(recursive: true);
        // Hold the OS lock from a *separate process* so withSettingsFileLock
        // must wait (POSIX locks are per-process).
        final lockPath = '${File(file.path).absolute.path}.lock';
        final helper = File(p.join(temp.path, 'hold_lock.dart'));
        await helper.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final handle = await File(args[0]).open(mode: FileMode.write);
  await handle.lock(FileLock.exclusive);
  print('LOCKED');
  await stdin.first;
  await handle.unlock();
  await handle.close();
}
''');
        final holder = await Process.start('dart', [helper.path, lockPath]);
        addTearDown(() => holder.kill());
        await holder.stdout
            .transform(const SystemEncoding().decoder)
            .firstWhere((line) => line.contains('LOCKED'));
        try {
          final stopwatch = Stopwatch()..start();
          await expectLater(
            withSettingsFileLock(file, () async {}),
            throwsA(isA<FileSystemException>()),
          );
          stopwatch.stop();
          // The 10s timeout is monotonic: it fires after ~10s of waiting,
          // not after a wall-clock deadline that a clock rollback could
          // stretch. (Uses a wide bound to avoid flakiness.)
          expect(stopwatch.elapsed, greaterThan(const Duration(seconds: 8)));
          expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
        } finally {
          holder.stdin.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('P2-#30 security -i quoting', () {
    test(
      'backslash and single quote survive the security -i tokenizer',
      () {
        // security -i is not a shell: it splits on whitespace, groups
        // double-quoted segments, and lets backslash escape " and \.
        // POSIX single-quote wrapping stored `ab\\cd` as `abcd`.
        expect(
          NativePlatformBridge.securityInteractiveQuote(r'ab\cd'),
          r'"ab\\cd"',
        );
        expect(
          NativePlatformBridge.securityInteractiveQuote("it's"),
          '"it\'s"',
        );
        expect(
          NativePlatformBridge.securityInteractiveQuote('a"b'),
          r'"a\"b"',
        );
        expect(NativePlatformBridge.securityInteractiveQuote(''), '""');
      },
    );

    test('store command double-quotes every value', () {
      expect(
        NativePlatformBridge.macosSecretStoreCommand(
          'epub-translator',
          'api_key',
          r'ab\cd',
        ),
        r'add-generic-password -a "api_key" -s "epub-translator" -U -w "ab\\cd"',
      );
    });
  });

  group('P2-#24 failed digest read keeps the old baseline', () {
    test('mtime baseline does not advance when the digest read fails',
        () async {
      final root = await Directory.systemTemp.createTemp('c11_p24_');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026);
      bool sabotage = false;
      final store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 100000,
        now: () => now,
        onMaintenanceScan: () async {
          if (sabotage) {
            // Swap the listed file for a directory after the listing so the
            // digest openRead() fails.
            final file = File(p.join(root.path, 'blocks', 'aa', 'aa01.html'));
            await file.delete();
            await Directory(
              p.join(root.path, 'blocks', 'aa', 'aa01.html'),
            ).create();
          }
        },
      );
      await store.putBlockTranslation('aa01', 'x' * 100);
      await store.waitForMaintenanceForTest();
      final filePath = p.join(root.path, 'blocks', 'aa', 'aa01.html');
      final baseline = store.mtimeBaselineForTest(filePath);
      expect(baseline, isNotNull);

      // Externally rewrite (new mtime), then sabotage the digest read.
      now = now.add(const Duration(minutes: 10));
      await File(filePath).writeAsString('y' * 100);
      sabotage = true;
      now = now.add(const Duration(minutes: 6));
      await store.putBlockTranslation('aa02', 'z' * 10);
      await store.waitForMaintenanceForTest();
      sabotage = false;

      // The digest could not be read: the mtime baseline must not advance
      // past the stale digest.
      expect(store.mtimeBaselineForTest(filePath), baseline);
    });
  });

  group('P2-#27 atomic checkpoint pair deletion', () {
    Future<void> writePair(
      Directory jobsDir,
      String jobKey,
      DateTime modified,
    ) async {
      final job = File(p.join(jobsDir.path, '$jobKey.json'));
      await job.writeAsString('{"jobKey":"$jobKey"}');
      await job.setLastModified(modified);
      final memoryKey = sha256
          .convert(utf8.encode('$jobKey:book-memory'))
          .toString();
      final memory = File(p.join(jobsDir.path, '$memoryKey.json'));
      await memory.writeAsString(
        '{"status":"book-memory","inputFingerprint":"$jobKey"}',
      );
      await memory.setLastModified(modified);
    }

    test('refreshing one member keeps the whole pair', () async {
      final root = await Directory.systemTemp.createTemp('c11_p27_');
      addTearDown(() => root.delete(recursive: true));
      final store = TranslationCacheStore(cacheRoot: root);
      final jobsDir = await Directory(p.join(root.path, 'jobs')).create();
      final old = DateTime.now().subtract(const Duration(minutes: 10));
      await writePair(jobsDir, 'job-a', old);
      await writePair(jobsDir, 'job-b', old);
      final memoryA = File(
        p.join(
          jobsDir.path,
          '${sha256.convert(utf8.encode('job-a:book-memory'))}.json',
        ),
      );

      // A concurrent save refreshes memory-a between listing and deletion:
      // the pair must be kept whole, never half-deleted.
      await store.pruneJobCheckpointsForTest(
        jobsDir,
        maxCheckpoints: 0,
        onListedForTest: () async {
          await memoryA.writeAsString(
            '{"status":"book-memory","inputFingerprint":"job-a","v":2}',
          );
        },
      );

      expect(await File(p.join(jobsDir.path, 'job-a.json')).exists(), isTrue);
      expect(await memoryA.exists(), isTrue);
      // The untouched pair is still deleted.
      expect(await File(p.join(jobsDir.path, 'job-b.json')).exists(), isFalse);
      expect(
        await File(
          p.join(
            jobsDir.path,
            '${sha256.convert(utf8.encode('job-b:book-memory'))}.json',
          ),
        ).exists(),
        isFalse,
      );
    });
  });

  group('P2-#28 checkpoint cap counts tasks', () {
    test('20 pairs are kept, not pruned to ~10', () async {
      final root = await Directory.systemTemp.createTemp('c11_p28_');
      addTearDown(() => root.delete(recursive: true));
      final store = TranslationCacheStore(cacheRoot: root);
      final jobsDir = await Directory(p.join(root.path, 'jobs')).create();
      final old = DateTime.now().subtract(const Duration(minutes: 10));
      for (int i = 0; i < 20; i++) {
        final jobKey = 'job-$i';
        final job = File(p.join(jobsDir.path, '$jobKey.json'));
        await job.writeAsString('{"jobKey":"$jobKey"}');
        await job.setLastModified(old.subtract(Duration(seconds: i)));
        final memory = File(
          p.join(
            jobsDir.path,
            '${sha256.convert(utf8.encode('$jobKey:book-memory'))}.json',
          ),
        );
        await memory.writeAsString(
          '{"status":"book-memory","inputFingerprint":"$jobKey"}',
        );
        await memory.setLastModified(old.subtract(Duration(seconds: i)));
      }

      await store.pruneJobCheckpointsForTest(jobsDir, maxCheckpoints: 20);

      // 20 tasks (40 files) fit the cap: nothing pruned.
      int countFiles() => Directory(jobsDir.path)
          .listSync()
          .whereType<File>()
          .length;
      expect(countFiles(), 40);

      // 21 tasks: the oldest pair goes, 20 tasks remain
      // (19 pairs + job-new = 39 files).
      final jobKey = 'job-new';
      final job = File(p.join(jobsDir.path, '$jobKey.json'));
      await job.writeAsString('{"jobKey":"$jobKey"}');
      await store.pruneJobCheckpointsForTest(jobsDir, maxCheckpoints: 20);
      final afterSecond = Directory(jobsDir.path).listSync().whereType<File>().length;
      expect(afterSecond, 39);
      expect(await File(p.join(jobsDir.path, 'job-19.json')).exists(), isFalse);
      expect(await File(p.join(jobsDir.path, 'job-0.json')).exists(), isTrue);
    });
  });

  group('P2-#29 lightweight quota pass during backoff', () {
    test('puts still enforce the quota while the backoff skips full scans',
        () async {
      final root = await Directory.systemTemp.createTemp('c11_p29_');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026);
      int scans = 0;
      final scanGate = Completer<void>();
      final store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 1000,
        now: () => now,
        onMaintenanceScan: () async {
          scans++;
          // Hold the baseline until all puts are in, so it deterministically
          // observes the over-capacity cache and arms the backoff.
          await scanGate.future;
          throw StateError('simulated unscannable cache');
        },
      );

      for (int i = 1; i <= 6; i++) {
        await store.putBlockTranslation('aa0$i', 'x' * 100);
      }
      scanGate.complete();
      await store.waitForMaintenanceForTest();
      // The throwing scan armed the backoff.
      expect(scans, 1);
      expect(store.estimatedCacheBytesForTest, greaterThan(1000));

      // Interval still active, backoff active, still over capacity: the old
      // code returned here and let the cache grow unbounded. The fix runs
      // the lightweight pass instead of the full scan.
      await store.putBlockTranslation('aa07', 'y' * 100);
      await store.waitForMaintenanceForTest();

      expect(scans, 1, reason: 'no full scan during backoff');
      expect(
        store.estimatedCacheBytesForTest,
        lessThanOrEqualTo(900),
        reason: 'lightweight pass evicted down to 90% of cap',
      );
    });
  });

  group('perf-#42 rollback digest memo', () {
    test('memoized rollback digest still forms a cohort', () async {
      final root = await Directory.systemTemp.createTemp('c11_p42_');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026);
      final store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 100000,
        now: () => now,
      );
      await store.putBlockTranslation('aa01', 'x' * 100);
      await store.putBlockTranslation('aa02', 'y' * 100);
      await store.waitForMaintenanceForTest();
      final pathA = p.join(root.path, 'blocks', 'aa', 'aa01.html');
      final pathB = p.join(root.path, 'blocks', 'aa', 'aa02.html');
      final baseA = store.mtimeBaselineForTest(pathA)!;
      final baseB = store.mtimeBaselineForTest(pathB)!;

      // Roll back A alone: lone rollback, digest memoized.
      final back = const Duration(hours: 1);
      await File(pathA).setLastModified(baseA.subtract(back));
      now = now.add(const Duration(minutes: 6));
      await store.putBlockTranslation('aa03', 'z' * 10);
      await store.waitForMaintenanceForTest();
      // Lone rollback: baseline untouched.
      expect(store.mtimeBaselineForTest(pathA), baseA);

      // Now roll back B by the same offset: the memoized digest of A must
      // still let them form a cohort.
      await File(pathB).setLastModified(baseB.subtract(back));
      now = now.add(const Duration(minutes: 6));
      await store.putBlockTranslation('aa04', 'w' * 10);
      await store.waitForMaintenanceForTest();
      // Both adopted the rolled-back mtimes: cohort formed.
      expect(store.mtimeBaselineForTest(pathA), baseA.subtract(back));
      expect(store.mtimeBaselineForTest(pathB), baseB.subtract(back));
    });
  });

  group('perf-#43 checkpoint prune throttle', () {
    JobResumeState jobState(String key) => JobResumeState(
          jobKey: key,
          inputFingerprint: 'fp',
          inputPath: '/in.epub',
          outputPath: '/out.epub',
          status: 'running',
          completedFiles: 1,
          totalFiles: 3,
          completedBlocks: 10,
          totalBlocks: 30,
          cachedBlocks: 5,
          resumedBlocks: 2,
          currentChapter: 'ch2',
          updatedAtIso8601: '2026-10-12T00:00:00Z',
        );

    Future<int> jobFileCount(Directory jobsDir) =>
        jobsDir.list().where((e) => e is File).length;

    test('rapid saves do not scan the jobs directory every time', () async {
      final root = await Directory.systemTemp.createTemp('c11_p43_');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026);
      final store = TranslationCacheStore(cacheRoot: root, now: () => now);
      final jobsDir = Directory(p.join(root.path, 'jobs'));
      await jobsDir.create(recursive: true);
      final old = now.subtract(const Duration(minutes: 10));
      for (int i = 0; i < 25; i++) {
        final file = File(p.join(jobsDir.path, 'old-$i.json'));
        await file.writeAsString('{"jobKey":"old-$i"}');
        await file.setLastModified(old);
      }

      await store.saveJobState(jobState('live'));
      // First save pruned: 25 old + 1 fresh = 26 tasks -> 20 kept.
      expect(await jobFileCount(jobsDir), 20);

      for (int i = 25; i < 30; i++) {
        final file = File(p.join(jobsDir.path, 'old-$i.json'));
        await file.writeAsString('{"jobKey":"old-$i"}');
        await file.setLastModified(old);
      }
      await store.saveJobState(jobState('live'));
      // Throttled (same `now`): no prune scan.
      expect(await jobFileCount(jobsDir), 25);

      now = now.add(const Duration(minutes: 2));
      await store.saveJobState(jobState('live'));
      // Throttle expired: prune runs again.
      expect(await jobFileCount(jobsDir), 20);
    });
  });

  _controllerTests();
}

class _ControllerStore extends SettingsStore {
  TranslationConfig persisted = TranslationConfig.defaults();
  int failSaves = 0;
  Object failError = StateError('injected failure');
  Object? loadError;
  Completer<void>? loadGate;
  final List<String> attempts = [];

  @override
  Object? get configLoadError => loadError;

  @override
  Future<TranslationConfig> load() async {
    final gate = loadGate;
    if (gate != null) await gate.future;
    loadError = null;
    return persisted;
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attempts.add(config.outputSuffix);
    if (failSaves > 0) {
      failSaves--;
      final error = failError;
      if (error is SettingsWriteConflict) loadError = error;
      throw error;
    }
    persisted = config;
  }
}

class _FakeRepository implements TranslationRepository {
  _FakeRepository(this.testConnectionResult);

  final Future<String> Function(TranslationConfig config) testConnectionResult;

  @override
  Future<String> testConnection({required TranslationConfig config}) =>
      testConnectionResult(config);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _controllerTests() {
  group('P1-#5 connection test result redaction', () {
    test('success result redacts the configured API key', () async {
      const apiKey = 'sk-test-key-12345';
      final repo = _FakeRepository(
        (config) async => 'Connected! Using key $apiKey for auth.',
      );
      final controller = ConnectionTestController(repo);
      addTearDown(controller.dispose);
      final config = TranslationConfig.defaults().copyWith(apiKey: apiKey);

      await controller.run(config);

      final state = controller.state;
      expect(state, isA<AsyncData<String?>>());
      final value = (state as AsyncData<String?>).value;
      expect(value, isNotNull);
      expect(value, isNot(contains(apiKey)));
    });
  });

  group('P2-#22 replay drops already-applied entries', () {
    test('a failed-then-succeeded entry is not replayed again', () async {
      final store = _ControllerStore()
        ..failSaves = 2
        ..failError = SettingsWriteConflict();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(await controller.setOutputSuffix('_first'), isFalse);
      // Clear the load error so the second edit does not trigger an inline
      // replay; we want both edits queued for the explicit reload below.
      store.loadError = null;
      expect(await controller.setOutputSuffix('_second'), isFalse);
      expect(store.attempts, ['_first', '_second']);
      store.attempts.clear();

      // During replay: first fails with a transient (non-conflict) error,
      // second succeeds. The failed entry was already applied to the state
      // and must be dropped, not replayed again.
      store
        ..failSaves = 1
        ..failError = StateError('disk full');
      await controller.reloadSettings();

      expect(store.attempts, ['_first', '_second']);
      expect(store.persisted.outputSuffix, '_second');
      expect(controller.state.outputSuffix, '_second');
      store.attempts.clear();

      // The failed `_first` was already applied-then-dropped; it must not
      // come back and clobber the successful `_second`.
      await controller.reloadSettings();

      expect(store.attempts, isEmpty);
      expect(store.persisted.outputSuffix, '_second');
      expect(controller.state.outputSuffix, '_second');
    });
  });

  group('P2-#23 debounced edit queued on replay conflict', () {
    test('a slider move during replay is queued, not lost', () async {
      final store = _ControllerStore()
        ..failSaves = 1
        ..failError = SettingsWriteConflict();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(await controller.setOutputSuffix('_first'), isFalse);

      // Stall the reload's load; move the slider while it is stalled so the
      // debounced edit is pending when the replay swallows it.
      store.loadGate = Completer<void>();
      store.failSaves = 1;
      store.failError = SettingsWriteConflict();
      final reload = controller.reloadSettings();
      controller.setChunkSize(50);
      store.loadGate!.complete();
      await reload;

      // Both the original edit and the swallowed debounced edit replayed.
      store.failSaves = 0;
      await controller.reloadSettings();

      expect(controller.state.outputSuffix, '_first');
      expect(controller.state.chunkSize, 50);
      expect(store.persisted.outputSuffix, '_first');
      expect(store.persisted.chunkSize, 50);
    });
  });

  group('P2-#26 reload flushes debounced edits first', () {
    test('a pending slider edit is saved before the reload load', () async {
      final store = _ControllerStore();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      // Move the slider but do not wait for the 400ms debounce timer.
      final sliderFuture = controller.setChunkSize(50);
      await controller.reloadSettings();
      await sliderFuture;

      expect(controller.state.chunkSize, 50);
      expect(store.persisted.chunkSize, 50);
    });
  });
}
