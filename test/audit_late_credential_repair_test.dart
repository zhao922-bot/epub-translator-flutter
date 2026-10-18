import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _Secrets implements SettingsSecretStore {
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

Future<void> _waitUntil(bool Function() condition) async {
  final timeout = Stopwatch()..start();
  while (!condition() && timeout.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  for (final slot in [SettingsSecretSlot.deepSeek, SettingsSecretSlot.custom]) {
    for (final clear in [false, true]) {
      test(
        'late $slot ${clear ? 'delete' : 'write'} restores committed credential without retry',
        () async {
          final dir = await Directory.systemTemp.createTemp('late_repair_');
          addTearDown(() => dir.delete(recursive: true));
          final file = File('${dir.path}/settings.json');
          final secrets = _Secrets();
          final store = SettingsStore(
            settingsFileProvider: () async => file,
            secretStore: secrets,
          );
          final initial = await store.load();
          final config = initial.copyWith(
            deepseekApiKey: 'committed-key',
            customApiKey: 'committed-key',
            apiKey: 'committed-key',
          );
          await store.save(config);
          final gate = secrets.gate = Completer<void>();
          secrets.delayedSlot = slot;
          final changed = clear ? '' : 'late-key';
          final pending = slot == SettingsSecretSlot.deepSeek
              ? config.copyWith(deepseekApiKey: changed)
              : config.copyWith(customApiKey: changed);
          await _failTimedOutSave(
            () => store.save(pending, explicitSecretMutations: {slot}),
          );
          gate.complete();
          await secrets.lateLanded.future;
          await _waitUntil(() => secrets.values[slot] == 'committed-key');
          final reopened = SettingsStore(
            settingsFileProvider: () async => file,
            secretStore: secrets,
          );
          final loaded = await reopened.load();
          expect(
            slot == SettingsSecretSlot.deepSeek
                ? loaded.deepseekApiKey
                : loaded.customApiKey,
            'committed-key',
          );
          expect(reopened.secretReadFailed(slot), isFalse);
        },
      );
    }
  }

  test(
    'reload during late-write recovery does not erase the committed key',
    () async {
      final dir = await Directory.systemTemp.createTemp('late_reload_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _Secrets();
      Completer<File>? discoveryGate;
      final repairStarted = Completer<void>();
      final store = SettingsStore(
        settingsFileProvider: () async {
          final pending = discoveryGate;
          if (pending != null) {
            discoveryGate = null;
            repairStarted.complete();
            return pending.future;
          }
          return file;
        },
        secretStore: secrets,
      );
      final config = (await store.load()).copyWith(
        apiKey: 'committed-key',
        deepseekApiKey: 'committed-key',
      );
      await store.save(config);
      final gate = secrets.gate = Completer<void>();
      secrets.delayedSlot = SettingsSecretSlot.deepSeek;
      await _failTimedOutSave(
        () => store.save(
          config.copyWith(deepseekApiKey: 'late-key'),
          explicitSecretMutations: {SettingsSecretSlot.deepSeek},
        ),
      );
      final repairGate = discoveryGate = Completer<File>();
      gate.complete();
      await repairStarted.future.timeout(const Duration(seconds: 3));
      final duringRepair = await store.load();
      expect(duringRepair.apiKey, isEmpty);
      expect(store.secretReadFailed(SettingsSecretSlot.deepSeek), isTrue);
      repairGate.complete(file);
      await _waitUntil(
        () => secrets.values[SettingsSecretSlot.deepSeek] == 'committed-key',
      );
      await store.save(
        duringRepair.copyWith(themeMode: AppThemeMode.light),
        explicitSecretMutations: {},
      );
      expect(secrets.values[SettingsSecretSlot.deepSeek], 'committed-key');
      expect((await store.load()).apiKey, 'committed-key');
      expect(store.secretReadFailed(SettingsSecretSlot.deepSeek), isFalse);
    },
  );

  test(
    'late repair checks the settings version after another instance commits',
    () async {
      final dir = await Directory.systemTemp.createTemp('late_other_instance_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _Secrets();
      Completer<File>? discoveryGate;
      final repairStarted = Completer<void>();
      final store = SettingsStore(
        settingsFileProvider: () async {
          final pending = discoveryGate;
          if (pending != null) {
            discoveryGate = null;
            repairStarted.complete();
            return pending.future;
          }
          return file;
        },
        secretStore: secrets,
      );
      final initial = await store.load();
      final config = initial.copyWith(
        deepseekApiKey: 'committed-key',
        apiKey: 'committed-key',
      );
      await store.save(config);
      final gate = secrets.gate = Completer<void>();
      secrets.delayedSlot = SettingsSecretSlot.deepSeek;
      await _failTimedOutSave(
        () => store.save(
          config.copyWith(deepseekApiKey: 'late-key'),
          explicitSecretMutations: {SettingsSecretSlot.deepSeek},
        ),
      );
      final other = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final current = await other.load();
      final repairGate = discoveryGate = Completer<File>();
      gate.complete();
      await repairStarted.future.timeout(const Duration(seconds: 3));
      await other.save(
        current.copyWith(apiKey: 'newer-key', deepseekApiKey: 'newer-key'),
      );
      repairGate.complete(file);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(secrets.values[SettingsSecretSlot.deepSeek], 'newer-key');
      expect(
        (await SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        ).load()).apiKey,
        'newer-key',
      );
    },
  );

  test(
    'failed repair keeps the durable binding and rejects the uncommitted key',
    () async {
      final dir = await Directory.systemTemp.createTemp('late_repair_failure_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = _Secrets();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final config = (await store.load()).copyWith(
        deepseekApiKey: 'committed-key',
        apiKey: 'committed-key',
      );
      await store.save(config);
      final gate = secrets.gate = Completer<void>();
      secrets.delayedSlot = SettingsSecretSlot.deepSeek;
      await _failTimedOutSave(
        () => store.save(
          config.copyWith(deepseekApiKey: 'late-key'),
          explicitSecretMutations: {SettingsSecretSlot.deepSeek},
        ),
      );
      final bindings =
          (jsonDecode(await file.readAsString()) as Map)['credentialBindings'];
      secrets.failRepair = true;
      gate.complete();
      await secrets.lateLanded.future;
      await _waitUntil(
        () => secrets.values[SettingsSecretSlot.deepSeek] == 'late-key',
      );
      await _waitUntil(() => secrets.failedRepairAttempts == 1);
      final reopened = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      expect((await reopened.load()).apiKey, isEmpty);
      expect(reopened.secretReadFailed(SettingsSecretSlot.deepSeek), isTrue);
      expect(
        (jsonDecode(await file.readAsString()) as Map)['credentialBindings'],
        bindings,
      );
    },
  );
}
