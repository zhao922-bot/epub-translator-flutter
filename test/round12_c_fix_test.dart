import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/api_provider_preset.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// Round 12, area C regression tests (Spark). Settings + cache fixes.
// ---------------------------------------------------------------------------

/// Configurable fake secret store for settings tests.
class _FakeSecretStore implements SettingsSecretStore {
  final Map<SettingsSecretSlot, String?> values = {};
  bool failReads = false;
  bool failWrites = false;
  bool failCustomReads = false;
  bool failCustomWrites = false;

  /// When non-null, writes to [hangSlot] block until the completer completes.
  Completer<void>? hangWrite;
  SettingsSecretSlot? hangSlot;
  bool writeStarted = false;

  final List<String> writeLog = [];

  bool _shouldFailRead(SettingsSecretSlot slot) {
    if (failReads) return true;
    if (slot == SettingsSecretSlot.custom && failCustomReads) return true;
    return false;
  }

  bool _shouldFailWrite(SettingsSecretSlot slot) {
    if (failWrites) return true;
    if (slot == SettingsSecretSlot.custom && failCustomWrites) return true;
    return false;
  }

  Future<String?> _read(SettingsSecretSlot slot) async {
    if (_shouldFailRead(slot)) throw StateError('read failed');
    return values[slot];
  }

  Future<void> _write(SettingsSecretSlot slot, String value) async {
    writeStarted = true;
    final Completer<void>? hang = hangWrite;
    if (hang != null && hangSlot == slot) {
      await hang.future;
    }
    if (_shouldFailWrite(slot)) throw StateError('write failed');
    values[slot] = value;
    writeLog.add('${slot.name}=$value');
  }

  Future<void> _delete(SettingsSecretSlot slot) async {
    if (_shouldFailWrite(slot)) throw StateError('delete failed');
    values.remove(slot);
    writeLog.add('${slot.name}=<deleted>');
  }

  @override
  Future<String?> readApiKey() => _read(SettingsSecretSlot.legacy);
  @override
  Future<void> writeApiKey(String value) =>
      _write(SettingsSecretSlot.legacy, value);
  @override
  Future<void> deleteApiKey() => _delete(SettingsSecretSlot.legacy);

  @override
  Future<String?> readDeepSeekApiKey() => _read(SettingsSecretSlot.deepSeek);
  @override
  Future<void> writeDeepSeekApiKey(String value) =>
      _write(SettingsSecretSlot.deepSeek, value);
  @override
  Future<void> deleteDeepSeekApiKey() => _delete(SettingsSecretSlot.deepSeek);

  @override
  Future<String?> readCustomApiKey() => _read(SettingsSecretSlot.custom);
  @override
  Future<void> writeCustomApiKey(String value) =>
      _write(SettingsSecretSlot.custom, value);
  @override
  Future<void> deleteCustomApiKey() => _delete(SettingsSecretSlot.custom);

  @override
  Future<String?> readProxyAuthentication() =>
      _read(SettingsSecretSlot.proxy);
  @override
  Future<void> writeProxyAuthentication(String value) =>
      _write(SettingsSecretSlot.proxy, value);
  @override
  Future<void> deleteProxyAuthentication() =>
      _delete(SettingsSecretSlot.proxy);
}


SettingsController _makeController(
  SettingsStore store, {
  void Function(Object? error)? onSaveError,
  void Function()? onWriteConflict,
  void Function()? onReplayBlocked,
}) {
  return SettingsController(
    store,
    onSaveError: onSaveError,
    onWriteConflict: onWriteConflict,
    onReplayBlocked: onReplayBlocked,
  );
}

void main() {
  group('P1-#4 credential operation generations', () {
    test(
      'a timed-out write that lands late cannot overwrite a retried save',
      () async {
        final temp = await Directory.systemTemp.createTemp('c12_p14_');
        addTearDown(() => temp.delete(recursive: true));
        final secrets = _FakeSecretStore();
        final file = File(p.join(temp.path, 'settings.json'));
        final store = SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        await store.load();

        // Save #1 with a hanging backend write for the custom slot.
        final hang = Completer<void>();
        secrets.hangWrite = hang;
        secrets.hangSlot = SettingsSecretSlot.custom;
        secrets.writeStarted = false;
        final save1 = store.save(
          TranslationConfig.defaults().copyWith(customApiKey: 'K1-old'),
          explicitSecretMutations: const {SettingsSecretSlot.custom},
        );
        // Wait until the backend write is actually issued (hanging).
        for (int i = 0; i < 100 && !secrets.writeStarted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(secrets.writeStarted, isTrue);

        // The save must fail with the 30s secret timeout, not hang.
        await expectLater(
          save1.timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw StateError('save hung'),
          ),
          throwsA(isA<SettingsSecretSaveException>()),
        );

        // Retry with the new value: succeeds.
        secrets.hangWrite = null;
        await store.save(
          TranslationConfig.defaults().copyWith(customApiKey: 'K2-new'),
          explicitSecretMutations: const {SettingsSecretSlot.custom},
        );
        expect(secrets.values[SettingsSecretSlot.custom], 'K2-new');

        // Now let the old (timed-out) write land late.
        hang.complete();
        await Future<void>.delayed(const Duration(seconds: 1));

        // The stale write must not win: the backend still holds the new
        // value (re-asserted by the stale-operation watcher).
        expect(secrets.values[SettingsSecretSlot.custom], 'K2-new');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('lastPersistedSecretSlots omits slots skipped as unreadable',
        () async {
      final temp = await Directory.systemTemp.createTemp('c12_p14b_');
      addTearDown(() => temp.delete(recursive: true));
      final secrets = _FakeSecretStore()..failCustomReads = true;
      final file = File(p.join(temp.path, 'settings.json'));
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final loaded = await store.load();
      expect(store.secretReadFailed(SettingsSecretSlot.custom), isTrue);

      // A non-credential save: the custom slot is skipped (read failure, not
      // explicit), so it must not be reported as persisted.
      await store.save(loaded.copyWith(themeMode: AppThemeMode.dark));
      expect(
        store.lastPersistedSecretSlots,
        isNot(contains(SettingsSecretSlot.custom)),
      );
    });
  });

  group('P2-#35 conflict rethrown for re-queueing', () {
    test('a save after a conflict throws conflict, not StateError', () async {
      final temp = await Directory.systemTemp.createTemp('c12_p235_');
      addTearDown(() => temp.delete(recursive: true));
      final secrets = _FakeSecretStore();
      SettingsStore makeStore() => SettingsStore(
            settingsFileProvider: () async =>
                File(p.join(temp.path, 'settings.json')),
            secretStore: secrets,
          );
      final storeA = makeStore();
      final storeB = makeStore();
      await storeA.load();
      await storeB.load();

      await storeA.save(
        TranslationConfig.defaults().copyWith(themeMode: AppThemeMode.dark),
      );
      // storeB's snapshot is stale (it never reloaded); both saves conflict.
      await expectLater(
        storeB.save(
          TranslationConfig.defaults().copyWith(themeMode: AppThemeMode.light),
        ),
        throwsA(isA<SettingsWriteConflict>()),
      );
      // A subsequent save while the conflict is unresolved must surface as
      // a conflict (so the caller queues the edit) — not a StateError.
      await expectLater(
        storeB.save(
          TranslationConfig.defaults().copyWith(themeMode: AppThemeMode.system),
        ),
        throwsA(isA<SettingsWriteConflict>()),
      );
      // A genuine (non-conflict) load error still refuses with StateError.
      // (Covered by existing settings_store_test.dart cases.)
    });
  });

  group('P1-#5 setApiBaseUrl key handling', () {
    test('changing the endpoint copies the active key (N8/F3 behavior)',
        () async {
      final temp = await Directory.systemTemp.createTemp('c12_p15_');
      addTearDown(() => temp.delete(recursive: true));
      final secrets = _FakeSecretStore();
      final store = SettingsStore(
        settingsFileProvider: () async =>
            File(p.join(temp.path, 'settings.json')),
        secretStore: secrets,
      );
      final controller = _makeController(store);
      await controller.ready;

      // Start on DeepSeek with a key.
      await controller.applyApiProviderPreset(ApiProviderPreset.deepseek);
      await controller.setApiKey('ds-key-2');
      // Change the URL: the active key moves to the custom slot (N8/F3).
      final ok = await controller.setApiBaseUrl('https://new.example/v1');
      expect(ok, isTrue);
      expect(
        controller.state.customApiKey,
        'ds-key-2',
        reason: 'setApiBaseUrl copies the active key to the custom slot',
      );
      expect(
        controller.state.apiKey,
        'ds-key-2',
        reason: 'the active key follows the custom slot',
      );
      expect(controller.state.apiBaseUrl, 'https://new.example/v1');
      controller.dispose();
    });

    test('replay uses the edit-time key, not another instance\'s key',
        () async {
      final temp = await Directory.systemTemp.createTemp('c12_p15b_');
      addTearDown(() => temp.delete(recursive: true));
      final secrets = _FakeSecretStore();
      SettingsStore makeStore() => SettingsStore(
            settingsFileProvider: () async =>
                File(p.join(temp.path, 'settings.json')),
            secretStore: secrets,
          );
      final controller1 = _makeController(makeStore());
      await controller1.ready;
      final controller2 = _makeController(makeStore());
      await controller2.ready;

      // Both on custom with the same key.
      await controller1.applyApiProviderPreset(ApiProviderPreset.custom);
      await controller1.setApiKey('shared-key');
      await controller2.reloadSettings();
      expect(controller2.state.customApiKey, 'shared-key');

      // Instance 1 changes the custom key.
      await controller1.setApiKey('instance1-key');

      // Instance 2 types a new endpoint (edit-time key is 'shared-key');
      // the save conflicts and the edit is queued.
      final ok = await controller2.setApiBaseUrl('https://new.example/v1');
      expect(ok, isFalse);

      // Reload + replay: the closure must bind the edit-time key, not
      // instance 1's newer key, to the new address. (P1-#5: binding another
      // instance's key to the user-typed address would send it there.)
      await controller2.reloadSettings();
      expect(controller2.state.apiBaseUrl, 'https://new.example/v1');
      expect(
        controller2.state.apiKey,
        'shared-key',
        reason: 'replay must use the edit-time snapshot key',
      );
      expect(
        controller2.state.customApiKey,
        'shared-key',
        reason: 'the URL edit carries the edit-time key, not the other '
            'instance\'s newer key',
      );
      controller1.dispose();
      controller2.dispose();
    });
  });


  group('P2-#27 replay keeps never-persisted key entries', () {
    test('a later non-credential replay success does not drop the key edit',
        () async {
      final temp = await Directory.systemTemp.createTemp('c12_p227_');
      addTearDown(() => temp.delete(recursive: true));
      // Reads fail so secret writes are skipped unless explicit; writes
      // fail so the key edit's own replay cannot persist it.
      final secrets = _FakeSecretStore()
        ..failReads = true
        ..failWrites = true;
      SettingsStore makeStore() => SettingsStore(
            settingsFileProvider: () async =>
                File(p.join(temp.path, 'settings.json')),
            secretStore: secrets,
          );
      final controller1 = _makeController(makeStore());
      await controller1.ready;
      final controller2 = _makeController(makeStore());
      await controller2.ready;

      // Queue a key edit (conflict) then a non-credential edit (conflict).
      // Default provider is deepseek, so the key lands in the deepSeek slot.
      await controller1.setBilingual(true);
      expect(await controller2.setApiKey('K1'), isFalse);
      await controller1.setBilingual(false);
      await controller2.setBilingual(true);
      // controller2's queue: [key K1, bilingual true].

      // Replay: the key edit's save fails (writes fail); the bilingual
      // edit's save succeeds (secret slots skipped as unreadable). The key
      // entry must stay queued — it was never persisted.
      await controller2.reloadSettings();
      expect(
        secrets.values[SettingsSecretSlot.deepSeek],
        isNot('K1'),
        reason: 'the key must not have been persisted by the replay',
      );

      // Allow writes; replay again. The retained key edit must now land.
      secrets.failWrites = false;
      await controller2.reloadSettings();
      expect(secrets.values[SettingsSecretSlot.deepSeek], 'K1');

      controller1.dispose();
      controller2.dispose();
    });
  });

  group('P2-#33 corrupt backup preserves the clear tombstone', () {
    test('loadWithTombstone returns the preserved tombstone', () async {
      final temp = await Directory.systemTemp.createTemp('c12_p233_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(p.join(temp.path, 'job-history.json'));
      final store = JobHistoryStore(historyFileProvider: () async => file);

      // Write a valid history, then clear it (tombstone T), then corrupt it.
      await store.save([_job('a')], clearedAtEpochMs: 0);
      final clearedAt = DateTime.now().millisecondsSinceEpoch;
      await store.save([], clearedAtEpochMs: clearedAt);
      // Torn write: valid prefix with the tombstone, truncated jobs.
      await file.writeAsString(
        '{"version": 2, "clearedAt": $clearedAt, "jobs": [{"jobId": "a",',
      );

      final loaded = await store.loadWithTombstone();
      expect(loaded.jobs, isEmpty);
      expect(
        loaded.clearedAt,
        clearedAt,
        reason: 'the corrupt backup must preserve the clear tombstone',
      );
      // C-P2-21: the corrupt file was moved aside AND the tombstone was
      // persisted, so a concurrent instance cannot resurrect cleared history.
      expect(await file.exists(), isTrue);
      final reloaded = await store.loadWithTombstone();
      expect(reloaded.clearedAt, clearedAt);
      expect(reloaded.jobs, isEmpty);
    });

    test('saveMerged applies the preserved tombstone', () async {
      final temp = await Directory.systemTemp.createTemp('c12_p233b_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(p.join(temp.path, 'job-history.json'));
      final store = JobHistoryStore(historyFileProvider: () async => file);

      await store.save([_job('a')], clearedAtEpochMs: 0);
      final clearedAt = DateTime.now().millisecondsSinceEpoch;
      await store.save([], clearedAtEpochMs: clearedAt);
      await file.writeAsString('{"version": 2, "clearedAt": $clearedAt, "jo');

      // Another instance with a stale (pre-clear) view tries to merge.
      final result = await store.saveMerged(
        merge: (fileJobs, fileClearedAt) => [_job('stale')],
        clearedAtEpochMs: 0,
      );
      expect(result.written, isTrue);
      // The tombstone was preserved and applied: the merge cannot move it
      // backwards.
      final reloaded = await store.loadWithTombstone();
      expect(reloaded.clearedAt, clearedAt);
      expect(reloaded.jobs.map((j) => j.id), contains('stale'));
    });
  });

  group('P2-#34 byte-based backup fingerprint', () {
    test('a concurrently repaired file is not moved aside', () async {
      final temp = await Directory.systemTemp.createTemp('c12_p234_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(p.join(temp.path, 'job-history.json'));
      final store = JobHistoryStore(historyFileProvider: () async => file);

      // Invalid UTF-8 bytes in the file.
      final badBytes = <int>[
        ...utf8.encode('{"version": 2, "jobs": ["'),
        0xFF, // invalid byte
        ...utf8.encode('"]}'),
      ];
      await file.writeAsBytes(badBytes);

      // Simulate: the load sees the bad bytes and decides to back up, but
      // before the backup runs, another instance repairs the file with
      // valid UTF-8 that decodes (lossily) to the same string.
      store.onBeforeCorruptBackupForTest = () async {
        final repaired = utf8.encode(
          utf8.decode(badBytes, allowMalformed: true),
        );
        await file.writeAsBytes(repaired);
      };
      final loaded = await store.loadWithTombstone();
      // The fingerprint is byte-based: the repaired file's bytes differ
      // from the bad bytes, so the backup is aborted and the repaired
      // file is kept.
      expect(await file.exists(), isTrue);
      expect(loaded.jobs, isEmpty);
      // No .bad- backup was created for the repaired file.
      final badBackups = await temp
          .list()
          .where(
            (e) =>
                e is File &&
                p.basename(e.path).startsWith('job-history.json.bad-'),
          )
          .toList();
      expect(badBackups, isEmpty);
    });
  });

  group('P2-#37 blocked replay queue is observable', () {
    test('blockedReplayCount reflects route-blocked edits', () async {
      final temp = await Directory.systemTemp.createTemp('c12_p237_');
      addTearDown(() => temp.delete(recursive: true));
      final secrets = _FakeSecretStore();
      SettingsStore makeStore() => SettingsStore(
            settingsFileProvider: () async =>
                File(p.join(temp.path, 'settings.json')),
            secretStore: secrets,
          );
      final controller1 = _makeController(makeStore());
      await controller1.ready;
      final controller2 = _makeController(makeStore());
      await controller2.ready;

      // controller2 queues a credential edit via conflict.
      await controller1.setBilingual(true);
      expect(await controller2.setApiKey('K1'), isFalse);
      expect(controller2.blockedReplayCount, 0);

      // Change the route: the queued credential edit is now blocked.
      await controller1.setApiBaseUrl('https://other.example/v1');
      await controller2.reloadSettings();
      // The replay was blocked by the route change; the edit stays queued.
      expect(controller2.blockedReplayCount, 1);

      // Discarding clears the queue.
      controller2.discardBlockedConflictReplays();
      expect(controller2.blockedReplayCount, 0);

      controller1.dispose();
      controller2.dispose();
    });

  });
}

TranslationJob _job(String id) => TranslationJob(
      id: id,
      inputPath: '/in.epub',
      outputPath: '/out.epub',
      status: TranslationJobStatus.completed,
      progress: 1.0,
    );
