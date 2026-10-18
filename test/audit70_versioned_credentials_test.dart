import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _Secrets implements SettingsSecretStore, VersionedSettingsSecretStore {
  final versions = <String, String>{};
  @override
  Future<String?> readCredential(String name) async => versions[name];
  @override
  Future<void> deleteCredential(String name) async {
    versions.remove(name);
  }

  @override
  Future<void> writeCredential(String name, String value) async {
    final pending = name.contains("_deepSeek_") ? gate : null;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    versions[name] = value;
    if (pending != null) lateLanded.complete();
  }

  final values = <SettingsSecretSlot, String>{};
  SettingsSecretSlot? delayedSlot;
  Completer<void>? gate;
  bool failRepair = false;
  int failedRepairAttempts = 0;
  final lateLanded = Completer<void>();

  Future<void> _write(SettingsSecretSlot slot, String value) async {
    final pending = slot == delayedSlot ? gate : null;
    if (pending != null) {
      gate = null;
      await pending.future;
    } else if (failRepair && value == 'committed-key') {
      failedRepairAttempts++;
      throw StateError('repair unavailable');
    }
    if (value.isEmpty) {
      values.remove(slot);
    } else {
      values[slot] = value;
    }
    if (pending != null) lateLanded.complete();
  }

  @override
  Future<String?> readApiKey() async => values[SettingsSecretSlot.legacy];
  @override
  Future<String?> readDeepSeekApiKey() async =>
      values[SettingsSecretSlot.deepSeek];
  @override
  Future<String?> readCustomApiKey() async => values[SettingsSecretSlot.custom];
  @override
  Future<String?> readProxyAuthentication() async =>
      values[SettingsSecretSlot.proxy];
  @override
  Future<void> writeApiKey(String value) =>
      _write(SettingsSecretSlot.legacy, value);
  @override
  Future<void> writeDeepSeekApiKey(String value) =>
      _write(SettingsSecretSlot.deepSeek, value);
  @override
  Future<void> writeCustomApiKey(String value) =>
      _write(SettingsSecretSlot.custom, value);
  @override
  Future<void> writeProxyAuthentication(String value) =>
      _write(SettingsSecretSlot.proxy, value);
  @override
  Future<void> deleteApiKey() => _write(SettingsSecretSlot.legacy, '');
  @override
  Future<void> deleteDeepSeekApiKey() =>
      _write(SettingsSecretSlot.deepSeek, '');
  @override
  Future<void> deleteCustomApiKey() => _write(SettingsSecretSlot.custom, '');
  @override
  Future<void> deleteProxyAuthentication() =>
      _write(SettingsSecretSlot.proxy, '');
}

class _SyncCleanupFailureSecrets extends _Secrets {
  @override
  Future<void> deleteCredential(String name) {
    throw StateError('synchronous backend cleanup failure');
  }
}

class _AsyncCleanupSecrets extends _Secrets {
  _AsyncCleanupSecrets({required this.delayed});
  final bool delayed;
  final deletions = <({String name, Completer<void> gate})>[];

  @override
  Future<void> deleteCredential(String name) {
    if (!delayed) return Future<void>.error(StateError('async cleanup failed'));
    final gate = Completer<void>();
    deletions.add((name: name, gate: gate));
    return gate.future.then((_) {
      versions.remove(name);
    });
  }
}

// Fire the real timeout callback after it is registered, without waiting 30s.
Future<void> _failTimedOutSave(Future<void> Function() save) async {
  final ready = Completer<void Function()>();
  final saving = runZoned(
    save,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = parent.createTimer(zone, duration, callback);
        if (duration == const Duration(seconds: 30) && !ready.isCompleted) {
          ready.complete(() {
            timer.cancel();
            zone.run(callback);
          });
        }
        return timer;
      },
    ),
  );
  final failed = expectLater(
    saving,
    throwsA(isA<SettingsSecretSaveException>()),
  );
  (await ready.future)();
  await failed;
}

// This changes the relative ordering of the existing cross-instance test:
// B's successful commit now precedes A's abandoned write landing.
void main() {
  for (final abandoned in ['abandoned-key', '']) {
    test(
      'newer commit survives late ${abandoned.isEmpty ? "clear" : "replacement"}',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'r70_late_other_commit_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/settings.json');
        final secrets = _Secrets();
        SettingsStore open() => SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        final a = open();
        final initial = (await a.load()).copyWith(
          apiKey: 'committed-key',
          deepseekApiKey: 'committed-key',
        );
        await a.save(initial);
        final gate = secrets.gate = Completer<void>();
        secrets.delayedSlot = SettingsSecretSlot.deepSeek;
        await _failTimedOutSave(
          () => a.save(
            initial.copyWith(deepseekApiKey: abandoned),
            explicitSecretMutations: {SettingsSecretSlot.deepSeek},
          ),
        );
        final b = open();
        final before = await b.load();
        await b.save(
          before.copyWith(apiKey: 'newer-key', deepseekApiKey: 'newer-key'),
        );
        expect(secrets.versions.values, contains('newer-key'));
        expect((await open().load()).apiKey, 'newer-key');
        final committedJson = await file.readAsString();
        gate.complete();
        await secrets.lateLanded.future;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final reopened = open();
        final loaded = await reopened.load();
        expect(reopened.secretReadFailed(SettingsSecretSlot.deepSeek), isFalse);
        expect(await file.readAsString(), committedJson);
        expect(
          loaded.apiKey,
          'newer-key',
          reason:
              'A successful newer commit must not be lost because an earlier timed-out backend operation later finishes',
        );
      },
    );
  }
  test(
    'versioned credential JSON failure retains the previous committed object',
    () async {
      final dir = await Directory.systemTemp.createTemp('versioned_rollback_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _Secrets();
      bool fail = false;
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
        settingsJsonWriter: (target, text) async {
          final json = jsonDecode(text) as Map;
          final versions = json['credentialVersions'] as Map? ?? {};
          final id = versions['deepSeek'];
          if (fail &&
              id != null &&
              secrets.versions['epub_translator_credential_deepSeek_$id'] ==
                  'rejected-key') {
            throw FileSystemException('injected JSON failure');
          }
          await target.writeAsString(text, flush: true);
        },
      );
      final initial = (await store.load()).copyWith(
        apiKey: 'original-key',
        deepseekApiKey: 'original-key',
      );
      await store.save(initial);
      final oldRef =
          (jsonDecode(await file.readAsString()) as Map)['credentialVersions'];
      fail = true;
      await expectLater(
        store.save(
          initial.copyWith(
            apiKey: 'rejected-key',
            deepseekApiKey: 'rejected-key',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (jsonDecode(await file.readAsString()) as Map)['credentialVersions'],
        oldRef,
      );
      final reopened = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      expect((await reopened.load()).apiKey, 'original-key');
      expect(await file.readAsString(), isNot(contains('original-key')));
      expect(await file.readAsString(), isNot(contains('rejected-key')));
    },
  );

  test(
    'schema 2 provider slots remain readable and migrate on the next key edit',
    () async {
      final dir = await Directory.systemTemp.createTemp('versioned_legacy_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _Secrets()
        ..values[SettingsSecretSlot.deepSeek] = 'legacy-provider-key';
      await file.writeAsString(
        jsonEncode({
          ...TranslationConfig.defaults().toJson(),
          'credentialSchemaVersion': 2,
        }),
      );
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final initial = await store.load();
      expect(initial.apiKey, 'legacy-provider-key');
      await store.save(
        initial.copyWith(
          apiKey: 'versioned-key',
          deepseekApiKey: 'versioned-key',
        ),
      );
      expect(
        (jsonDecode(await file.readAsString()) as Map)['credentialVersions'],
        isNotEmpty,
      );
      final reopened = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      expect((await reopened.load()).apiKey, 'versioned-key');
    },
  );

  test(
    'a bad version reference never falls back to a stale provider slot',
    () async {
      final dir = await Directory.systemTemp.createTemp('versioned_bad_ref_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _Secrets()
        ..values[SettingsSecretSlot.deepSeek] = 'stale-key';
      await file.writeAsString(
        jsonEncode({
          ...TranslationConfig.defaults().toJson(),
          'credentialSchemaVersion': 2,
          'credentialVersions': {'deepSeek': 'not-a-valid-version'},
        }),
      );
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      expect((await store.load()).apiKey, isEmpty);
      expect(store.secretReadFailed(SettingsSecretSlot.deepSeek), isTrue);
    },
  );
  test(
    'obsolete credential cleanup cannot turn a committed save into failure',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'credential_cleanup_sync_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _SyncCleanupFailureSecrets();
      SettingsStore open() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final store = open();
      final original = (await store.load()).copyWith(
        apiKey: 'original-key',
        deepseekApiKey: 'original-key',
      );
      await store.save(original);
      await expectLater(
        store.save(
          original.copyWith(
            apiKey: 'committed-key',
            deepseekApiKey: 'committed-key',
          ),
        ),
        completes,
      );
      expect((await open().load()).apiKey, 'committed-key');
    },
  );
  for (final mode in [
    'async failure',
    'timeout then success',
    'timeout then failure',
  ]) {
    test(
      'RC02 obsolete cleanup $mode retains latest commit and releases lock',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'credential_cleanup_async_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/settings.json');
        final secrets = _AsyncCleanupSecrets(delayed: mode != 'async failure');
        SettingsStore open() => SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        final timers = <({Timer timer, void Function() fire})>[];
        await runZoned(
          () async {
            final store = open();
            var config = (await store.load()).copyWith(
              apiKey: 'first',
              deepseekApiKey: 'first',
            );
            await store.save(config);
            config = config.copyWith(
              apiKey: 'second',
              deepseekApiKey: 'second',
            );
            await store.save(config);
            // Cleanup is outstanding, but neither the JSON transaction nor its
            // cross-instance lock may remain blocked by it.
            final other = open();
            final loaded = await other.load();
            expect(loaded.apiKey, 'second');
            await other.save(
              loaded.copyWith(apiKey: 'third', deepseekApiKey: 'third'),
            );
            for (final entry in timers) {
              if (entry.timer.isActive) {
                entry.timer.cancel();
                entry.fire();
              }
            }
            await Future<void>.delayed(Duration.zero);
            final committed = await file.readAsString();
            for (final deletion in secrets.deletions) {
              if (mode == 'timeout then failure') {
                deletion.gate.completeError(StateError('late cleanup failed'));
              } else {
                deletion.gate.complete();
              }
            }
            await Future<void>.delayed(Duration.zero);
            expect((await open().load()).apiKey, 'third');
            expect(await file.readAsString(), committed);
            expect(secrets.versions.values, contains('third'));
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              final timer = parent.createTimer(zone, duration, callback);
              if (duration == const Duration(seconds: 30)) {
                timers.add((timer: timer, fire: () => zone.run(callback)));
              }
              return timer;
            },
          ),
        );
      },
    );
  }
  test(
    'RC02 rollback preserves original error when discarded version cleanup throws synchronously',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'credential_rollback_cleanup_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _SyncCleanupFailureSecrets();
      final expected = FileSystemException('injected JSON failure');
      var reject = false;
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
        settingsJsonWriter: (target, text) async {
          final versions =
              (jsonDecode(text) as Map)['credentialVersions'] as Map?;
          final version = versions?['deepSeek'];
          if (reject &&
              secrets.versions['epub_translator_credential_deepSeek_$version'] ==
                  'rejected') {
            throw expected;
          }
          await target.writeAsString(text, flush: true);
        },
      );
      final initial = (await store.load()).copyWith(
        apiKey: 'original',
        deepseekApiKey: 'original',
      );
      await store.save(initial);
      reject = true;
      await expectLater(
        store.save(
          initial.copyWith(apiKey: 'rejected', deepseekApiKey: 'rejected'),
        ),
        throwsA(same(expected)),
      );
      expect(
        (await SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        ).load()).apiKey,
        'original',
      );
    },
  );
  test(
    'RC02 cleanup of a late abandoned write handles synchronous failure',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'credential_late_cleanup_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _SyncCleanupFailureSecrets();
      SettingsStore open() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final store = open();
      final initial = (await store.load()).copyWith(
        apiKey: 'original',
        deepseekApiKey: 'original',
      );
      await store.save(initial);
      final gate = secrets.gate = Completer<void>();
      await _failTimedOutSave(
        () => store.save(
          initial.copyWith(deepseekApiKey: 'late'),
          explicitSecretMutations: {SettingsSecretSlot.deepSeek},
        ),
      );
      gate.complete();
      await secrets.lateLanded.future;
      await Future<void>.delayed(Duration.zero);
      expect((await open().load()).apiKey, 'original');
    },
  );
  for (final abandoned in ['late-key', '']) {
    test(
      'versioned timeout without another save retains the committed key: $abandoned',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'credential_no_followup_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/settings.json');
        final secrets = _Secrets();
        SettingsStore open() => SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        final store = open();
        final initial = (await store.load()).copyWith(
          apiKey: 'committed-key',
          deepseekApiKey: 'committed-key',
        );
        await store.save(initial);
        final gate = secrets.gate = Completer<void>();
        await _failTimedOutSave(
          () => store.save(
            initial.copyWith(deepseekApiKey: abandoned),
            explicitSecretMutations: {SettingsSecretSlot.deepSeek},
          ),
        );
        final committed = await file.readAsString();
        expect((await open().load()).apiKey, 'committed-key');
        gate.complete();
        await secrets.lateLanded.future;
        expect((await store.load()).apiKey, 'committed-key');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect((await open().load()).apiKey, 'committed-key');
        expect(await file.readAsString(), committed);
      },
    );
  }
}
