import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/shared/io/atomic_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Secrets implements SettingsSecretStore {
  final values = <SettingsSecretSlot, String>{};
  bool failCustomRead = false;
  bool failRollback = false;
  int writes = 0;
  Future<String?> read(SettingsSecretSlot slot) async {
    if (slot == SettingsSecretSlot.custom && failCustomRead) {
      throw StateError('keyring unavailable');
    }
    return values[slot];
  }

  Future<void> write(SettingsSecretSlot slot, String? value) async {
    writes++;
    if (failRollback && value == 'old-key') {
      throw StateError('rollback unavailable');
    }
    if (value == null) {
      values.remove(slot);
    } else {
      values[slot] = value;
    }
  }

  @override
  Future<String?> readApiKey() => read(SettingsSecretSlot.legacy);
  @override
  Future<String?> readDeepSeekApiKey() => read(SettingsSecretSlot.deepSeek);
  @override
  Future<String?> readCustomApiKey() => read(SettingsSecretSlot.custom);
  @override
  Future<String?> readProxyAuthentication() => read(SettingsSecretSlot.proxy);
  @override
  Future<void> writeApiKey(String value) =>
      write(SettingsSecretSlot.legacy, value);
  @override
  Future<void> writeDeepSeekApiKey(String value) =>
      write(SettingsSecretSlot.deepSeek, value);
  @override
  Future<void> writeCustomApiKey(String value) =>
      write(SettingsSecretSlot.custom, value);
  @override
  Future<void> writeProxyAuthentication(String value) =>
      write(SettingsSecretSlot.proxy, value);
  @override
  Future<void> deleteApiKey() => write(SettingsSecretSlot.legacy, null);
  @override
  Future<void> deleteDeepSeekApiKey() =>
      write(SettingsSecretSlot.deepSeek, null);
  @override
  Future<void> deleteCustomApiKey() => write(SettingsSecretSlot.custom, null);
  @override
  Future<void> deleteProxyAuthentication() =>
      write(SettingsSecretSlot.proxy, null);
}

class _RenameFailure implements File {
  _RenameFailure(this.file, this.error);
  final File file;
  final FileSystemException error;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<File> rename(String newPath) async => throw error;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _sweepInNewIsolate(String output, String active) => Isolate.run(
  () => EpubIsolateWorker.reclaimStaleTempFilesForTest(
    File(output),
    File(active),
  ),
);

// Deliberately hold a real native handle until the finally block runs. Sending
// progress makes cancellation deterministic rather than relying on startup time.
void Function(void Function(int, int)) _handleOperation(
  String temp,
  String closed,
) => (progress) {
  final handle = File(temp).openSync(mode: FileMode.write);
  try {
    progress(0, 1);
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 150) {
      handle.writeByteSync(42);
    }
  } finally {
    handle.closeSync();
    File(closed).writeAsStringSync('closed');
  }
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File settings;
  late _Secrets secrets;
  final oldConfig = TranslationConfig.defaults().copyWith(
    apiProviderSelection: ApiProviderSelection.custom,
    apiBaseUrl: 'https://old.example',
    customApiBaseUrl: 'https://old.example',
    apiKey: 'old-key',
    customApiKey: 'old-key',
    model: 'saved-model',
  );
  SettingsStore store({Future<void> Function(File, String)? writer}) =>
      SettingsStore(
        settingsFileProvider: () async => settings,
        secretStore: secrets,
        settingsJsonWriter: writer,
      );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('p1_round6_');
    settings = File(p.join(dir.path, 'settings.json'));
    secrets = _Secrets()..values[SettingsSecretSlot.custom] = 'old-key';
    await settings.writeAsString(
      jsonEncode({...oldConfig.toJson(), 'credentialSchemaVersion': 2}),
    );
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'P1-1 lock open failure blocks defaults save and recovers before edits',
    () async {
      final original = await settings.readAsString();
      final lockDirectory = Directory('${settings.path}.lock');
      await lockDirectory.create();
      final errors = <Object?>[];
      final storage = store();
      final controller = SettingsController(storage, onSaveError: errors.add);
      addTearDown(controller.dispose);
      await controller.ready;
      expect(storage.configLoadError, isA<FileSystemException>());
      await controller.setThemeMode(AppThemeMode.light);
      await controller.setUiLanguage(UiLanguage.english);
      expect(await settings.readAsString(), original);
      expect(secrets.writes, 0);
      expect(errors.whereType<Object>(), isNotEmpty);
      await expectLater(
        storage.save(TranslationConfig.defaults()),
        throwsStateError,
      );
      await lockDirectory.delete();
      await controller.setThemeMode(AppThemeMode.light);
      expect(controller.state.model, 'saved-model');
      expect(controller.state.apiBaseUrl, 'https://old.example');
      expect(storage.configLoadError, isNull);
    },
  );

  for (final rollbackFails in [false, true]) {
    test(
      'P1-2 failed JSON write ${rollbackFails ? 'and rollback' : 'rolls back keys'} is safe on restart',
      () async {
        int jsonWrites = 0;
        final storage = store(
          writer: (file, encoded) async {
            if (++jsonWrites == 2) {
              secrets.failRollback = rollbackFails;
              throw const FileSystemException(
                'disk full',
                '',
                OSError('disk full', 28),
              );
            }
            await writeFileAtomically(file, encoded);
          },
        );
        final loaded = await storage.load();
        await expectLater(
          storage.save(
            loaded.copyWith(
              apiBaseUrl: 'https://new.example',
              customApiBaseUrl: 'https://new.example',
              apiKey: 'new-key',
              customApiKey: 'new-key',
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        final restarted = await store().load();
        expect(restarted.apiBaseUrl, 'https://old.example');
        expect(restarted.apiKey, rollbackFails ? '' : 'old-key');
        expect(await settings.readAsString(), isNot(contains('new-key')));
        await expectLater(storage.save(loaded), throwsStateError);
      },
    );
  }

  test(
    'P1-2 crash-window disk snapshot rejects new key without rollback',
    () async {
      final storage = store();
      final loaded = await storage.load();
      // Establish exactly the durable old-endpoint binding used before writes.
      await storage.save(loaded);
      secrets.values[SettingsSecretSlot.custom] = 'new-key';
      final restarted = await store().load();
      expect(restarted.apiBaseUrl, 'https://old.example');
      expect(restarted.apiKey, isEmpty);
    },
  );

  test(
    'P1-4 commit lock timeout preserves complete translation with timeout classification',
    () async {
      final output = File(p.join(dir.path, 'timeout.epub'));
      final temp = File('${output.path}.tmp.123')
        ..writeAsStringSync('complete translation');
      await expectLater(
        EpubIsolateWorker.commitTempFile(
          temp,
          output,
          lockTimeout: Duration.zero,
        ),
        throwsA(
          isA<OutputFileRecoveryTimeoutException>().having(
            (error) => File(error.tempFilePath).readAsStringSync(),
            'recovery payload',
            'complete translation',
          ),
        ),
      );
    },
  );

  test('P1-3 URL-only edit with unreadable custom slot is refused', () async {
    secrets.failCustomRead = true;
    final storage = store();
    final loaded = await storage.load();
    expect(loaded.apiKey, isEmpty);
    await expectLater(
      storage.save(
        loaded.copyWith(
          apiBaseUrl: 'https://new.example',
          customApiBaseUrl: 'https://new.example',
        ),
      ),
      throwsStateError,
    );
    expect(secrets.writes, 0);
    secrets.failCustomRead = false;
    final restarted = await store().load();
    expect(restarted.apiBaseUrl, 'https://old.example');
    expect(restarted.apiKey, 'old-key');
  });

  test(
    'P1-2 unreadable old key still has a crash-safe binding before replacement',
    () async {
      secrets.failCustomRead = true;
      int jsonWrites = 0;
      final storage = store(
        writer: (file, encoded) async {
          if (++jsonWrites == 2) throw const FileSystemException('disk full');
          await writeFileAtomically(file, encoded);
        },
      );
      final loaded = await storage.load();
      await expectLater(
        storage.save(
          loaded.copyWith(
            apiBaseUrl: 'https://new.example',
            customApiBaseUrl: 'https://new.example',
            apiKey: 'new-key',
            customApiKey: 'new-key',
          ),
          explicitSecretMutations: {
            SettingsSecretSlot.custom,
            SettingsSecretSlot.legacy,
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      secrets.failCustomRead = false;
      final restarted = await store().load();
      expect(restarted.apiBaseUrl, 'https://old.example');
      expect(restarted.apiKey, isEmpty);
    },
  );

  test(
    'P1-3 explicit replacement allows endpoint change despite read failure',
    () async {
      secrets.failCustomRead = true;
      final storage = store();
      final loaded = await storage.load();
      await storage.save(
        loaded.copyWith(
          apiBaseUrl: 'https://new.example',
          customApiBaseUrl: 'https://new.example',
          apiKey: 'confirmed-key',
          customApiKey: 'confirmed-key',
        ),
        explicitSecretMutations: {
          SettingsSecretSlot.custom,
          SettingsSecretSlot.legacy,
        },
      );
      secrets.failCustomRead = false;
      final restarted = await store().load();
      expect(restarted.apiBaseUrl, 'https://new.example');
      expect(restarted.apiKey, 'confirmed-key');
    },
  );

  test(
    'P1-4 output name reserves entire recovery suffix in bytes and UTF16',
    () async {
      for (final windows in [false, true]) {
        final name = EpubChapterTranslator.outputFileNameForTest(
          '长😀' * 120,
          '_translated',
          windows: windows,
        );
        final recovery = '$name.recovery.1234567890123456';
        expect(
          windows ? recovery.length : utf8.encode(recovery).length,
          lessThanOrEqualTo(255),
        );
        if (!windows) {
          final temp = File(p.join(dir.path, '$name.tmp.1234567890123456'));
          await temp.writeAsString('complete translation');
          final kept = await EpubIsolateWorker.preserveRecoveryTempForTest(
            temp,
            File(p.join(dir.path, name)),
          );
          expect(await kept.readAsString(), 'complete translation');
        }
      }
    },
  );

  test(
    'P1-4 failed recovery rename preserves payload and exempts it from sweep',
    () async {
      final output = File(p.join(dir.path, 'output.epub'));
      final temp = File('${output.path}.tmp.123');
      await temp.writeAsString('complete translation');
      final failing = _RenameFailure(
        temp,
        const FileSystemException('name too long'),
      );
      final kept = await EpubIsolateWorker.preserveRecoveryTempForTest(
        failing,
        output,
      );
      expect(kept.path, temp.path);
      await temp.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      await EpubIsolateWorker.reclaimStaleTempFilesForTest(
        output,
        File('${output.path}.tmp.active'),
      );
      expect(await temp.readAsString(), 'complete translation');
      await _sweepInNewIsolate(output.path, '${output.path}.tmp.active');
      expect(await temp.readAsString(), 'complete translation');
    },
  );

  test(
    'P1-4 generic promotion failure returns recovery path with complete bytes',
    () async {
      final output = File(p.join(dir.path, 'output.epub'));
      final temp = File('${output.path}.tmp.123')
        ..writeAsStringSync('complete');
      final failing = _RenameFailure(
        temp,
        const FileSystemException('permission denied'),
      );
      await expectLater(
        EpubIsolateWorker.commitTempFile(failing, output),
        throwsA(
          isA<OutputFileRecoveryException>().having(
            (e) => File(e.tempFilePath).readAsStringSync(),
            'preserved payload',
            'complete',
          ),
        ),
      );
      expect(await temp.readAsString(), 'complete');
    },
  );

  test(
    'P1-4 locked final plus failed recovery rename still reports intact payload',
    () async {
      final output = File(p.join(dir.path, 'locked.epub'))
        ..writeAsStringSync('old output');
      final temp = File('${output.path}.tmp.123')
        ..writeAsStringSync('complete translation');
      await expectLater(
        EpubIsolateWorker.commitTempFile(
          _RenameFailure(temp, const FileSystemException('name too long')),
          _RenameFailure(
            output,
            const FileSystemException('locked', '', OSError('locked', 32)),
          ),
        ),
        throwsA(
          isA<OutputFileLockedException>().having(
            (error) => error.tempFilePath,
            'original recovery path',
            temp.path,
          ),
        ),
      );
      expect(await output.readAsString(), 'old output');
      expect(await temp.readAsString(), 'complete translation');
    },
  );

  test(
    'CI-1 Windows active paths normalize separators, case and dot segments',
    () {
      expect(
        EpubIsolateWorker.sameFilesystemPath(
          r'C:\Books\output.epub.tmp.123',
          'c:/books/./output.epub.tmp.123',
          windows: true,
        ),
        isTrue,
      );
      expect(
        EpubIsolateWorker.sameFilesystemPath(
          '/books/A',
          '/books/a',
          windows: false,
        ),
        isFalse,
      );
    },
  );

  test('CI-1 sweep keeps aged active temp with alternate spelling', () async {
    final output = File(p.join(dir.path, 'output.epub'));
    final active = File('${output.path}.tmp.active')
      ..writeAsStringSync('active');
    final orphan = File('${output.path}.tmp.orphan')
      ..writeAsStringSync('orphan');
    final old = DateTime.now().subtract(const Duration(hours: 1));
    await active.setLastModified(old);
    await orphan.setLastModified(old);
    final alternate = Platform.isWindows
        ? active.path.replaceAll(r'\', '/').toUpperCase()
        : '${dir.path}/./${p.basename(active.path)}';
    await EpubIsolateWorker.reclaimStaleTempFilesForTest(
      output,
      File(alternate),
    );
    expect(await active.readAsString(), 'active');
    expect(await orphan.exists(), isFalse);
  });

  test(
    'CI-2 cancellation waits for native handle finally before returning',
    () async {
      final temp = p.join(dir.path, 'held.tmp');
      final closed = p.join(dir.path, 'closed');
      var cancelled = false;
      await expectLater(
        EpubIsolateWorker.prepareWithProgress<void>(
          operation: _handleOperation(temp, closed),
          onProgress: (_, _) => cancelled = true,
          isCancelled: () => cancelled,
          finishBeforeCancellation: true,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(File(closed).existsSync(), isTrue);
      await File(temp).delete();
    },
  );

  for (final veto in [false, true]) {
    test(
      'CI-2 ${veto ? 'veto' : 'cancel'} active export leaves no temp and preserves output',
      () async {
        final archive = Archive()
          ..addFile(
            ArchiveFile.string(
              'META-INF/container.xml',
              '<container><rootfile full-path="book.opf"/></container>',
            ),
          )
          ..addFile(
            ArchiveFile.string(
              'book.opf',
              '<package><metadata/><manifest/><spine/></package>',
            ),
          )
          ..addFile(
            ArchiveFile.string(
              'chapter.xhtml',
              '<html><body>original</body></html>',
            ),
          );
        final input = File(p.join(dir.path, 'input.epub'))
          ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
        final output = File(p.join(dir.path, 'output.epub'))
          ..writeAsStringSync('original output');
        final large = List.generate(
          150000,
          (i) => '<p>Translation paragraph $i.</p>',
        ).join();
        var cancelled = false;
        bool check() {
          cancelled |= dir.listSync().any(
            (f) => p.basename(f.path).startsWith('output.epub.tmp.'),
          );
          return cancelled;
        }

        final result = EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          translatedHtmlByPath: {
            'chapter.xhtml': '<html><body>$large</body></html>',
          },
          isCancelled: veto ? null : check,
          shouldCommit: veto ? () => !check() : null,
        );
        if (veto) {
          expect(await result, isFalse);
        } else {
          await expectLater(
            result,
            throwsA(isA<TranslationCancelledException>()),
          );
        }
        expect(cancelled, isTrue);
        expect(
          dir.listSync().where(
            (f) => p.basename(f.path).startsWith('output.epub.tmp.'),
          ),
          isEmpty,
        );
        expect(await output.readAsString(), 'original output');
      },
    );
  }
}
