import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/io/settings_file_lock.dart';
import 'package:epub_translator_flutter/shared/logging/app_logger.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

/// Gate-based fixture, matching the round10/round13 replay tests. Loading
/// deliberately clears the error before returning its snapshot (real store).
class _ReplayStore extends SettingsStore {
  TranslationConfig persisted = TranslationConfig.defaults();
  Object? loadError;
  Object? saveError;
  Completer<void>? loadGate;
  Completer<void>? loadStarted;
  Completer<void>? saveGate;
  Completer<void>? saveStarted;
  int loads = 0;
  final attempts = <TranslationConfig>[];
  Set<SettingsSecretSlot> persistedSlots = SettingsSecretSlot.values.toSet();

  @override
  Object? get configLoadError => loadError;

  @override
  Set<SettingsSecretSlot> get lastPersistedSecretSlots => persistedSlots;

  @override
  Future<TranslationConfig> load() async {
    loads++;
    loadError = null;
    final snapshot = persisted;
    final gate = loadGate;
    loadGate = null;
    loadStarted?.complete();
    loadStarted = null;
    if (gate != null) await gate.future;
    return snapshot;
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attempts.add(config);
    final error = saveError;
    final gate = saveGate;
    saveGate = null;
    saveStarted?.complete();
    saveStarted = null;
    if (gate != null) await gate.future;
    if (error != null) throw error;
    persisted = config;
  }
}

class _SecretStore implements SettingsSecretStore {
  final values = <SettingsSecretSlot, String>{};
  final failures = <SettingsSecretSlot>{};
  Completer<void>? writeGate;

  Future<void> _write(SettingsSecretSlot slot, String value) async {
    if (failures.contains(slot)) throw StateError('secret write failed');
    final gate = writeGate;
    writeGate = null;
    if (gate != null) await gate.future;
    if (value.isEmpty) {
      values.remove(slot);
    } else {
      values[slot] = value;
    }
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
  Future<void> deleteApiKey() => writeApiKey('');
  @override
  Future<void> deleteDeepSeekApiKey() => writeDeepSeekApiKey('');
  @override
  Future<void> deleteCustomApiKey() => writeCustomApiKey('');
  @override
  Future<void> deleteProxyAuthentication() => writeProxyAuthentication('');
}

class _ProbeProcess extends Fake implements Process {
  @override
  int get pid => 123;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode('1'));
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode async => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

void main() {
  late _ReplayStore store;
  late SettingsController controller;
  late List<Object?> notices;

  setUp(() async {
    NativePlatformBridge.debugWindowsProcessStarter = (_, _) async =>
        _ProbeProcess();
    addTearDown(() => NativePlatformBridge.debugWindowsProcessStarter = null);
    store = _ReplayStore();
    notices = [];
    controller = SettingsController(store, onSaveError: notices.add);
    addTearDown(controller.dispose);
    await controller.ready;
  });

  test('C-P2-1 auto recovery parks edits after loadError clears', () async {
    store.loadError = StateError('load failed');
    store.persisted = store.persisted.copyWith(targetLanguage: 'French');
    final gate = store.loadGate = Completer<void>();
    final started = store.loadStarted = Completer<void>();
    final recovering = controller.setOutputSuffix('_recovered');
    await started.future;
    expect(store.configLoadError, isNull);
    final editing = controller.setTargetLanguage('German');
    await Future<void>.delayed(Duration.zero);
    expect(store.attempts, isEmpty);
    expect(controller.state.targetLanguage, isNot('German'));
    gate.complete();
    expect(await recovering, isTrue);
    expect(await editing, isTrue);
    expect(store.persisted.targetLanguage, 'German');
    expect(controller.state.targetLanguage, 'German');
  });

  Future<void> queueBlockedComposite() async {
    store.saveError = SettingsWriteConflict();
    final slider = controller.setChunkSize(60);
    expect(await controller.setApiKey('held-key'), isFalse);
    await slider;
    final newer = controller.setChunkSize(70);
    expect(await controller.flushSliderChanges(), isFalse);
    await newer;
    store.saveError = null;
    store.persisted = store.persisted.copyWith(
      apiBaseUrl: 'https://changed.example/v1',
    );
    await controller.reloadSettings();
  }

  test(
    'C-P2-2 overlapping slider replay retains blocked composite key',
    () async {
      await queueBlockedComposite();
      expect(controller.blockedReplayCount, 1);
      expect(store.persisted.chunkSize, 70);
      expect(store.persisted.apiKey, isNot('held-key'));
      await controller.confirmBlockedConflictReplays();
      expect(store.persisted.apiKey, 'held-key');
      expect(controller.blockedReplayCount, 0);
    },
  );

  test('C-P2-3 normal key save retires an older failed key replay', () async {
    store.saveError = SettingsWriteConflict();
    expect(await controller.setApiKey('old-key'), isFalse);
    store.saveError = null;
    expect(await controller.setApiKey('new-key'), isTrue);
    store.attempts.clear();
    await controller.reloadSettings();
    expect(store.attempts, isEmpty);
    expect(store.persisted.apiKey, 'new-key');
  });

  test(
    'C-P2-4 new immediate edit invalidates an unprocessed replay member',
    () async {
      store.saveError = SettingsWriteConflict();
      expect(await controller.setTargetLanguage('French'), isFalse);
      expect(await controller.setOutputSuffix('_old'), isFalse);
      store.saveError = null;
      final gate = store.saveGate = Completer<void>();
      final started = store.saveStarted = Completer<void>();
      final reload = controller.reloadSettings();
      await started.future;
      final edit = controller.setOutputSuffix('_new');
      gate.complete();
      expect(await edit, isTrue);
      await reload;
      expect(controller.state.outputSuffix, '_new');
      expect(store.persisted.outputSuffix, '_new');
      store.attempts.clear();
      await controller.reloadSettings();
      expect(store.attempts, isEmpty);
    },
  );

  test(
    'C-P2-5 reload observes failure of an already started slider flush',
    () async {
      final slider = controller.setChunkSize(60);
      store.saveError = StateError('disk full');
      final gate = store.saveGate = Completer<void>();
      final started = store.saveStarted = Completer<void>();
      final flush = controller.flushSliderChanges();
      await started.future;
      final loads = store.loads;
      final reload = controller.reloadSettings();
      gate.complete();
      expect(await flush, isFalse);
      expect(await reload, isFalse);
      await slider;
      expect(store.loads, loads);
      expect(controller.state.chunkSize, 60);
    },
  );

  test(
    'C-P2-6 ordinary recovery cancels discarded slider transformation',
    () async {
      final slider = controller.setChunkSize(60);
      store.loadError = StateError('load failed');
      expect(await controller.setOutputSuffix('_recovered'), isTrue);
      await slider;
      expect(await controller.flushSliderChanges(), isTrue);
      expect(
        controller.state.chunkSize,
        TranslationConfig.defaults().chunkSize,
      );
      expect(store.persisted.chunkSize, controller.state.chunkSize);
      expect(store.attempts, hasLength(1));
    },
  );

  test(
    'C-P2-7 endpoint edit waits for initial key and model snapshot',
    () async {
      final initialStore = _ReplayStore()
        ..persisted = TranslationConfig.defaults().copyWith(
          apiProviderSelection: ApiProviderSelection.custom,
          apiKey: 'saved-custom-key',
          customApiKey: 'saved-custom-key',
          model: 'saved-model',
        );
      final gate = initialStore.loadGate = Completer<void>();
      final initialController = SettingsController(initialStore);
      addTearDown(initialController.dispose);
      final edit = initialController.setApiBaseUrl('https://custom.example/v1');
      gate.complete();
      expect(await edit, isTrue);
      expect(initialStore.persisted.customApiKey, 'saved-custom-key');
      expect(initialStore.persisted.apiKey, 'saved-custom-key');
      expect(initialStore.persisted.customModel, 'saved-model');
    },
  );

  test(
    'C-P2-8 replay busy status covers the entire asynchronous save',
    () async {
      store.saveError = SettingsWriteConflict();
      await controller.setApiKey('held-key');
      store.saveError = null;
      final gate = store.saveGate = Completer<void>();
      final started = store.saveStarted = Completer<void>();
      final replay = controller.confirmBlockedConflictReplays();
      await started.future;
      expect(controller.isReplayingConflictedEdits, isTrue);
      gate.complete();
      await replay;
      expect(controller.isReplayingConflictedEdits, isFalse);
    },
  );

  test(
    'C-P2-9 older asynchronous success cannot clear a newer conflict',
    () async {
      store.saveError = SettingsWriteConflict();
      final gate = store.saveGate = Completer<void>();
      final started = store.saveStarted = Completer<void>();
      final failing = controller.setOutputSuffix('_failed');
      await started.future;
      store.saveError = null;
      final succeeding = controller.setTargetLanguage('French');
      gate.complete();
      expect(await failing, isFalse);
      expect(await succeeding, isTrue);
      expect(notices.last, isA<SettingsWriteConflict>());
    },
  );

  // C-07 invariant: even when an unrelated save's implicit retry actually
  // persists a previously failed key, the failure notice stays until the
  // user's explicit retry. (This test previously pinned the v1.6.26
  // regression where unrelated saves cleared the notice.)
  test(
    'C-P2-10 implicit secret persistence keeps the failure notice',
    () async {
      store.saveError = SettingsSecretSaveException({
        SettingsSecretSlot.legacy: StateError('secret unavailable'),
        SettingsSecretSlot.deepSeek: StateError('secret unavailable'),
      });
      expect(await controller.setApiKey('retry-key'), isFalse);
      store.saveError = null;
      expect(await controller.setOutputSuffix('_implicit'), isTrue);
      // The implicit retry did persist the key...
      expect(store.persisted.apiKey, 'retry-key');
      // ...but the notice is not cleared by the unrelated save.
      expect(notices.last, isNotNull);
    },
  );

  Future<ProviderContainer> showSettings(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ready;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump();
    return container;
  }

  Finder action(String english, String chinese) => find.widgetWithText(
    TextButton,
    find.text(english).evaluate().isNotEmpty ? english : chinese,
  );

  testWidgets('C-P2-8 Apply stays visible but disabled throughout replay', (
    tester,
  ) async {
    final container = await showSettings(tester);
    final uiController = container.read(settingsProvider.notifier);
    store.saveError = SettingsWriteConflict();
    await uiController.setApiKey('held-key');
    store.saveError = null;
    container.read(settingsReplayBlockedProvider.notifier).state = (id: 1);
    await tester.pump();
    final gate = store.saveGate = Completer<void>();
    await tester.tap(action('Apply', '确认应用'));
    await tester.pump();
    expect(uiController.isReplayingConflictedEdits, isTrue);
    expect(
      tester.widget<TextButton>(action('Apply', '确认应用')).onPressed,
      isNull,
    );
    gate.complete();
    await tester.pump();
    expect(uiController.isReplayingConflictedEdits, isFalse);
  });

  testWidgets('C-P2-9 reload completion preserves a newer conflict event', (
    tester,
  ) async {
    final container = await showSettings(tester);
    container.read(settingsWriteConflictProvider.notifier).state = (id: 1);
    await tester.pump();
    final gate = store.loadGate = Completer<void>();
    await tester.tap(action('Reload', '重新加载'));
    await tester.pump();
    container.read(settingsWriteConflictProvider.notifier).state = (id: 2);
    gate.complete();
    await tester.pump();
    expect(container.read(settingsWriteConflictProvider)?.id, 2);
  });

  testWidgets('C-P2-9 Apply completion preserves a newer blocked event', (
    tester,
  ) async {
    final container = await showSettings(tester);
    final uiController = container.read(settingsProvider.notifier);
    store.saveError = SettingsWriteConflict();
    await uiController.setApiKey('held-key');
    store.saveError = null;
    container.read(settingsReplayBlockedProvider.notifier).state = (id: 1);
    await tester.pump();
    final gate = store.saveGate = Completer<void>();
    await tester.tap(action('Apply', '确认应用'));
    await tester.pump();
    container.read(settingsReplayBlockedProvider.notifier).state = (id: 2);
    gate.complete();
    await tester.pump();
    expect(container.read(settingsReplayBlockedProvider)?.id, 2);
  });

  testWidgets('C-P2-15 Discard disabled while replay in progress', (
    tester,
  ) async {
    final container = await showSettings(tester);
    final uiController = container.read(settingsProvider.notifier);
    store.saveError = SettingsWriteConflict();
    await uiController.setApiKey('held-key');
    store.saveError = null;
    container.read(settingsReplayBlockedProvider.notifier).state = (id: 1);
    await tester.pump();
    expect(
      tester.widget<TextButton>(action('Discard', '放弃')).onPressed,
      isNotNull,
    );
    final gate = store.saveGate = Completer<void>();
    await tester.tap(action('Apply', '确认应用'));
    await tester.pump();
    expect(container.read(settingsReplayInProgressProvider), isTrue);
    expect(action('Discard', '放弃'), findsOneWidget);
    expect(
      tester.widget<TextButton>(action('Discard', '放弃')).onPressed,
      isNull,
    );
    gate.complete();
    await tester.pump();
    expect(store.persisted.apiKey, 'held-key');
  });

  testWidgets('C-P2-16 pre-existing error shown on page init', (tester) async {
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final uiController = container.read(settingsProvider.notifier);
    await uiController.ready;
    store.saveError = StateError('pre-existing save failure');
    expect(await uiController.setModel('unsaved-model'), isFalse);
    final error = container.read(settingsSaveErrorProvider);
    expect(error, isNotNull);
    expect(error?.message, isNotNull);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(
          container.read(appStringsProvider).settingsSaveFailed,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('C-P2-16 pre-existing conflict shows fallback on page init', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ready;
    container.read(settingsWriteConflictProvider.notifier).state = (id: 1);
    expect(container.read(settingsSaveErrorProvider), isNull);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(
          'Settings changed in another instance; reload before editing.',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('C-P2-17 paused flushes text debounce', (tester) async {
    final container = await showSettings(tester);
    final originalModel = store.persisted.model;
    await tester.enterText(
      find.byKey(const ValueKey<String>('settings-model')),
      'background-model',
    );
    // No elapsed pump: the 800ms text debounce has not fired.
    expect(container.read(settingsProvider).model, originalModel);
    expect(store.persisted.model, originalModel);
    final observer =
        tester.state(find.byType(SettingsPage)) as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(settingsProvider).model, 'background-model');
    expect(store.persisted.model, 'background-model');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('C-P2-18 full eviction excludes temp bytes', () async {
    final root = await Directory.systemTemp.createTemp('round14-c18-');
    addTearDown(() => root.delete(recursive: true));
    final cache = TranslationCacheStore(cacheRoot: root, maxCacheBytes: 1000)
      ..suspendAutoMaintenanceForTest = true;
    await cache.putBlockTranslation('aa-valid', 'paid translation');
    final valid = File('${root.path}/blocks/aa/aa-valid.html');
    final validBytes = await valid.length();
    final temp = File('${valid.path}.tmp.in-flight');
    await temp.writeAsBytes(List<int>.filled(2000, 1));

    await cache.pruneCacheDirectoryForTest(root, maxBytes: 1000);

    expect(await cache.getBlockTranslation('aa-valid'), 'paid translation');
    expect(cache.estimatedCacheBytesForTest, validBytes + 2000);
    expect(await cache.enforceQuotaLightlyForTest(), 0);
    expect(await valid.exists(), isTrue);
    expect(await temp.length(), 2000);
  });

  test('C-P2-19 scan preserves keys added during scan', () async {
    final root = await Directory.systemTemp.createTemp('round14-c19-');
    addTearDown(() => root.delete(recursive: true));
    final listed = Completer<void>();
    final resume = Completer<void>();
    final cache = TranslationCacheStore(
      cacheRoot: root,
      maxCacheBytes: 100,
      onMaintenanceScan: () async {
        listed.complete();
        await resume.future;
      },
    )..suspendAutoMaintenanceForTest = true;
    final scanning = cache.pruneCacheDirectoryForTest(root);
    try {
      await listed.future;
      await cache.putBlockTranslation('bb-new', 'added during scan');
    } finally {
      resume.complete();
      await scanning;
    }
    final added = File(path.join(root.path, 'blocks', 'bb', 'bb-new.html'));
    final stat = await added.stat();
    expect(cache.estimatedCacheBytesForTest, stat.size);
    expect(cache.mtimeBaselineForTest(added.path), stat.modified);
    expect(await cache.getBlockTranslation('bb-new'), 'added during scan');
    // A light pass can only find the new key through the rebuilt index.
    expect(await cache.enforceQuotaLightlyForTest(), stat.size);
    expect(await added.exists(), isFalse);
    expect(cache.estimatedCacheBytesForTest, 0);
  });

  test('C-P2-20 clearJobState skips externally rewritten file', () async {
    final root = await Directory.systemTemp.createTemp('round14-c20-');
    addTearDown(() => root.delete(recursive: true));
    final cache = TranslationCacheStore(cacheRoot: root);
    final other = TranslationCacheStore(cacheRoot: root);
    final file = File('${root.path}/jobs/shared-job.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'jobKey': 'shared-job'}));
    final state = (await cache.loadJobState('shared-job'))!;
    await cache.saveJobState(state);
    final saved = await file.stat();

    await other.saveJobState(state);
    await file.setLastModified(saved.modified.add(const Duration(seconds: 5)));
    final rewritten = await file.readAsString();
    expect((await file.stat()).modified, isNot(saved.modified));
    await cache.clearJobState('shared-job');
    expect(await file.readAsString(), rewritten);

    // A fresh instance has no saved baseline and cannot claim this file.
    await TranslationCacheStore(cacheRoot: root).clearJobState('shared-job');
    expect(await file.exists(), isTrue);
    // This instance can still clear a checkpoint it saves again itself.
    await cache.saveJobState(state);
    await cache.clearJobState('shared-job');
    expect(await file.exists(), isFalse);
  });

  test('C-P2-21 corrupt backup persists tombstone', () async {
    const clearedAt = 1700000000000;
    final corruptFiles = <List<int>>[
      utf8.encode('{"clearedAt":$clearedAt,"jobs":'),
      utf8.encode('{"clearedAt":$clearedAt,"jobs":{}}'),
      [
        ...utf8.encode('{"clearedAt":$clearedAt,"jobs":[],"bad":"'),
        0xff,
        ...utf8.encode('"}'),
      ],
    ];
    for (final bytes in corruptFiles) {
      final root = await Directory.systemTemp.createTemp('round14-c21-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/job-history.json');
      await file.writeAsBytes(bytes);
      final history = JobHistoryStore(historyFileProvider: () async => file);

      final recovered = await history.loadWithTombstone();
      expect(recovered.jobs, isEmpty);
      expect(recovered.clearedAt, clearedAt);
      final backups = await root
          .list()
          .where((entity) => entity.path.contains('job-history.json.bad-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await File(backups.single.path).readAsBytes(), bytes);

      final other = JobHistoryStore(historyFileProvider: () async => file);
      final reloaded = await other.loadWithTombstone();
      expect(reloaded.jobs, isEmpty);
      expect(reloaded.clearedAt, clearedAt);
      final result = await other.saveMerged(
        clearedAtEpochMs: 0,
        // A stale instance must be rejected before it can merge old entries.
        merge: (_, _) => throw StateError('cleared history would resurrect'),
      );
      expect(result.written, isFalse);
      expect(result.fileClearedAt, clearedAt);
      final persisted = jsonDecode(await file.readAsString()) as Map;
      expect(persisted['clearedAt'], clearedAt);
      expect(persisted['jobs'], isEmpty);
    }
  });

  test('C-P2-22 save backs up structurally invalid history', () async {
    const clearedAt = 1700000000000;
    for (final raw in <String>[
      '{"clearedAt":$clearedAt,"jobs":{}}',
      '{"clearedAt":$clearedAt}',
      '"not a history envelope"',
      'null',
    ]) {
      final root = await Directory.systemTemp.createTemp('round14-c22-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/job-history.json');
      await file.writeAsString(raw);
      final history = JobHistoryStore(historyFileProvider: () async => file);

      await history.save([]);

      final backups = await root
          .list()
          .where((entity) => entity.path.contains('job-history.json.bad-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await File(backups.single.path).readAsString(), raw);
      final persisted = jsonDecode(await file.readAsString()) as Map;
      expect(persisted['version'], 2);
      expect(persisted['jobs'], isEmpty);
      expect(persisted['clearedAt'], raw.startsWith('{') ? clearedAt : 0);
    }
  });

  test('C-P2-23 overlong macos secret refused', () async {
    var helperCalls = 0;
    Future<void> helper(String command) async {
      helperCalls++;
    }

    final overhead = utf8
        .encode(
          NativePlatformBridge.macosSecretStoreCommand(
            'epub-translator',
            'api-key',
            '',
          ),
        )
        .length;
    for (final password in <String>[
      'x' * (4001 - overhead),
      '密' * 1400,
      r'\' * 2000,
    ]) {
      final command = NativePlatformBridge.macosSecretStoreCommand(
        'epub-translator',
        'api-key',
        password,
      );
      expect(utf8.encode(command).length, greaterThan(4000));
      await expectLater(
        NativePlatformBridge.writeMacosSecretForTest(
          'api-key',
          password,
          storeCommand: helper,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Secret too long for macOS keychain write; refusing to overwrite.',
          ),
        ),
      );
      expect(helperCalls, 0);
    }
    await NativePlatformBridge.writeMacosSecretForTest(
      'api-key',
      'x' * (4000 - overhead),
      storeCommand: helper,
    );
    expect(helperCalls, 1);
  });

  test('C-P2-25 logger redacts secrets', () {
    final lines = <String>[];
    void capture(OutputEvent event) => lines.addAll(event.lines);
    Logger.addOutputListener(capture);
    addTearDown(() => Logger.removeOutputListener(capture));

    const message = 'request api_key=private-value sk-abcdefghijklmnopqrstuvwx';
    AppLogger.warn(message);
    AppLogger.warn(message, tag: 'secrets');
    AppLogger.error(message, tag: 'secrets', error: message);

    expect(lines, isNotEmpty);
    final output = lines.join('\n');
    expect(output, contains('request'));
    expect(output, contains('[secrets]'));
    expect(output, isNot(contains('private-value')));
    expect(output, isNot(contains('sk-abcdefghijklmnopqrstuvwx')));
    final safe = AppLogger.safeError(message) as String;
    expect(safe, isNot(contains('private-value')));
    expect(safe, isNot(contains('sk-abcdefghijklmnopqrstuvwx')));
    final other = StateError('ordinary error');
    expect(AppLogger.safeError(other), same(other));
    expect(AppLogger.safeError(null), isNull);
    expect(
      AppLogger.safeError(const FormatException('private-value', message, 2)),
      'FormatException (offset: 2)',
    );
  });

  test('C-P2-11 late secret write mismatch warns', () async {
    final root = await Directory.systemTemp.createTemp('round14-c11-');
    addTearDown(() => root.delete(recursive: true));
    final secrets = _SecretStore();
    final settings = SettingsStore(
      settingsFileProvider: () async => File('${root.path}/settings.json'),
      secretStore: secrets,
    );
    final config = await settings.load();
    final gate = secrets.writeGate = Completer<void>();
    final timeoutReady = Completer<void Function()>();
    final warnings = <String>[];
    final warned = Completer<void>();
    void capture(OutputEvent event) {
      if (event.level != Level.warning) return;
      warnings.addAll(event.lines);
      if (event.lines.any(
            (line) => line.contains(
              'Credential version mismatch after late completion',
            ),
          ) &&
          !warned.isCompleted) {
        warned.complete();
      }
    }

    Logger.addOutputListener(capture);
    addTearDown(() => Logger.removeOutputListener(capture));
    final saving = runZoned(
      () => settings.save(config.copyWith(customApiKey: 'late-private-key')),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (duration == const Duration(seconds: 30) &&
              !timeoutReady.isCompleted) {
            timeoutReady.complete(() {
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
      throwsA(
        isA<SettingsSecretSaveException>().having(
          (error) => error.failures[SettingsSecretSlot.custom],
          'custom timeout',
          isA<TimeoutException>(),
        ),
      ),
    );
    try {
      (await timeoutReady.future)();
      await failed;
      expect(secrets.values[SettingsSecretSlot.custom], isNull);
      expect(warnings, isEmpty);
    } finally {
      gate.complete();
    }
    await warned.future;
    expect(secrets.values[SettingsSecretSlot.custom], 'late-private-key');
    expect(warnings.join('\n'), contains('custom key'));
    expect(warnings.join('\n'), contains('save settings again to reconcile'));
    expect(warnings.join('\n'), isNot(contains('late-private-key')));
    expect(settings.lastPersistedSecretSlots, isEmpty);
  });

  test(
    'C-P2-12 partial secret failure updates lastPersistedSecretSlots',
    () async {
      final root = await Directory.systemTemp.createTemp('round14-c12-');
      addTearDown(() => root.delete(recursive: true));
      final secrets = _SecretStore();
      final settings = SettingsStore(
        settingsFileProvider: () async => File('${root.path}/settings.json'),
        secretStore: secrets,
      );
      final config = await settings.load();
      await settings.save(
        config,
        explicitSecretMutations: SettingsSecretSlot.values.toSet(),
      );
      expect(
        settings.lastPersistedSecretSlots,
        unorderedEquals(SettingsSecretSlot.values),
      );
      secrets.failures.add(SettingsSecretSlot.custom);
      await expectLater(
        settings.save(
          config.copyWith(
            apiKey: 'saved-legacy',
            deepseekApiKey: 'saved-deepseek',
            customApiKey: 'failed-custom',
            outputSuffix: '_partial',
          ),
        ),
        throwsA(
          isA<SettingsSecretSaveException>().having(
            (error) => error.failures.keys,
            'failed slots',
            unorderedEquals([SettingsSecretSlot.custom]),
          ),
        ),
      );
      expect(
        settings.lastPersistedSecretSlots,
        unorderedEquals([
          SettingsSecretSlot.legacy,
          SettingsSecretSlot.deepSeek,
        ]),
      );
      expect(secrets.values[SettingsSecretSlot.legacy], 'saved-legacy');
      expect(secrets.values[SettingsSecretSlot.deepSeek], 'saved-deepseek');
      expect(secrets.values[SettingsSecretSlot.custom], isNull);
      final json =
          jsonDecode(await File('${root.path}/settings.json').readAsString())
              as Map;
      expect(json['outputSuffix'], '_partial');
    },
  );

  test('C-P2-13 file lock normalizes dot-dot paths', () async {
    final root = await Directory.systemTemp.createTemp('round14-c13-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/nested').create();
    final entered = Completer<void>();
    final release = Completer<void>();
    final order = <String>[];
    final first = withSettingsFileLock(
      File('${root.path}/settings.json'),
      () async {
        order.add('first entered');
        entered.complete();
        await release.future;
        order.add('first exited');
      },
    );
    await entered.future;
    final second = withSettingsFileLock(
      File('${root.path}/nested/../settings.json'),
      () async => order.add('second entered'),
    );
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(order, ['first entered']);
    } finally {
      release.complete();
      await Future.wait([first, second]);
    }
    expect(order, ['first entered', 'first exited', 'second entered']);
    expect(await File('${root.path}/settings.json.lock').exists(), isTrue);
  });

  test('C-P2-14 prune keeps recently created backups', () async {
    final root = await Directory.systemTemp.createTemp('round14-c14-');
    addTearDown(() => root.delete(recursive: true));
    final now = DateTime.now();
    final old = <File>[];
    for (var i = 0; i < 7; i++) {
      final file = File('${root.path}/settings.json.bad-${900 + i}');
      await file.writeAsString('old-$i');
      await file.setLastModified(now.subtract(Duration(minutes: 20 - i)));
      old.add(file);
    }
    // Small filename timestamps simulate a backwards wall-clock jump.
    final recent = <File>[];
    for (var i = 0; i < 7; i++) {
      final file = File('${root.path}/settings.json.bad-$i');
      await file.writeAsString('recent-$i');
      recent.add(file);
    }
    final file = File('${root.path}/settings.json');
    await file.writeAsString('{broken');
    final settings = SettingsStore(
      settingsFileProvider: () async => file,
      secretStore: _SecretStore(),
    );
    await settings.load();
    expect(settings.didCorruptReset, isTrue);
    expect(settings.lastCorruptBackupPath, isNotNull);
    expect(
      await File(settings.lastCorruptBackupPath!).readAsString(),
      '{broken',
    );
    for (var i = 0; i < recent.length; i++) {
      expect(await recent[i].readAsString(), 'recent-$i');
    }
    for (var i = 0; i < old.length; i++) {
      expect(await old[i].exists(), i >= 2);
    }
    final backups = await root
        .list()
        .where((entry) => entry.path.contains('settings.json.bad-'))
        .toList();
    expect(backups, hasLength(13));
  });

  test('C-P2-26 discard during replay cancels snapshot items', () async {
    var blockedNotices = 0;
    final replayController = SettingsController(
      store,
      onReplayBlocked: () => blockedNotices++,
    );
    addTearDown(replayController.dispose);
    await replayController.ready;
    store.saveError = SettingsWriteConflict();
    expect(await replayController.setOutputSuffix('_retained'), isFalse);
    expect(await replayController.setApiKey('discarded-key'), isFalse);
    store.saveError = null;
    store.persisted = store.persisted.copyWith(
      apiBaseUrl: 'https://changed.example/v1',
    );
    store.attempts.clear();
    final gate = store.saveGate = Completer<void>();
    final started = store.saveStarted = Completer<void>();
    final replay = replayController.reloadSettings();
    await started.future;
    try {
      expect(replayController.isReplayingConflictedEdits, isTrue);
      expect(replayController.blockedReplayCount, 1);
      replayController.discardBlockedConflictReplays();
      expect(replayController.blockedReplayCount, 0);
    } finally {
      gate.complete();
      await replay;
    }
    expect(
      blockedNotices,
      0,
      reason: 'A discarded item in the replay snapshot must be skipped.',
    );
    expect(store.attempts, hasLength(1));
    expect(store.persisted.outputSuffix, '_retained');
    expect(store.persisted.apiKey, isNot('discarded-key'));
    expect(replayController.isReplayingConflictedEdits, isFalse);
    store.attempts.clear();
    await replayController.confirmBlockedConflictReplays();
    await replayController.reloadSettings();
    expect(store.attempts, isEmpty);
    expect(replayController.state.apiKey, isNot('discarded-key'));
  });

  // C-性能-1: failed earlier edits are retired by a later successful save;
  // route-blocked composite edits must survive the same batch.
  test('C-性能-1 eviction batch removal matches semantics', () async {
    await queueBlockedComposite();
    store.saveError = SettingsWriteConflict();
    await controller.setOutputSuffix('_stale');
    await controller.setOutputSuffix('_latest');
    await controller.setTargetLanguage('French');
    store.saveError = StateError('first replay fails');
    final gate = store.saveGate = Completer<void>();
    final started = store.saveStarted = Completer<void>();
    final replay = controller.reloadSettings();
    await started.future;
    store.saveError = null;
    gate.complete();
    await replay;
    expect(store.persisted.outputSuffix, '_latest');
    expect(store.persisted.targetLanguage, 'French');
    expect(controller.blockedReplayCount, 1);
    store.attempts.clear();
    await controller.reloadSettings();
    expect(store.attempts, isEmpty, reason: 'stale entries were evicted');
    await controller.confirmBlockedConflictReplays();
    expect(store.persisted.apiKey, 'held-key');
    expect(controller.blockedReplayCount, 0);
  });

  // C-性能-2: replay executes the retained transformation, exposing nesting
  // that a plain flush (which saves optimistic state) would not exercise.
  test('C-性能-2 debounce latest transformation wins', () async {
    final edits = <Future<void>>[];
    for (var i = 0; i < 20000; i++) {
      edits.add(controller.setChunkSize(i.isEven ? 4000 : 6000));
    }
    edits.add(controller.setMaxConcurrent(5));
    edits.add(controller.setTimeoutSeconds(180));
    edits.add(controller.setMaxRetries(4));
    edits.add(controller.setRetryDelaySeconds(7));
    edits.add(controller.setTextScale(1.2));
    store.saveError = SettingsWriteConflict();
    expect(await controller.flushSliderChanges(), isFalse);
    await Future.wait(edits);
    store.saveError = null;
    store.persisted = store.persisted.copyWith(outputSuffix: '_external');
    await controller.reloadSettings();
    expect(store.persisted.chunkSize, 6000);
    expect(store.persisted.maxConcurrent, 5);
    expect(store.persisted.timeoutSeconds, 180);
    expect(store.persisted.maxRetries, 4);
    expect(store.persisted.retryDelaySeconds, 7);
    expect(store.persisted.textScale, 1.2);
    expect(store.persisted.outputSuffix, '_external');
  });

  // C-性能-3: unchanged widget identity proves the page did not rebuild its
  // unrelated API section while the slider Consumer updated its value.
  testWidgets('C-性能-3 slider rebuild scope', (tester) async {
    final container = await showSettings(tester);
    await tester.pumpAndSettle();
    final chip = find.byType(ChoiceChip).first;
    final before = tester.widget(chip);
    final slider = find.byType(Slider).last;
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final oldValue = tester.widget<Slider>(slider).value;
    await tester.drag(slider, const Offset(60, 0));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, isNot(oldValue));
    expect(tester.widget(chip), same(before));
    await container.read(settingsProvider.notifier).flushSliderChanges();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // C-性能-4: compare streaming results with full JSON decoding, including
  // skipped non-map entries, escaped delimiters, UTF-8 chunk boundaries and
  // an envelope whose tombstone follows jobs.
  test('C-性能-4 history limit 20 matches full decode', () async {
    final root = await Directory.systemTemp.createTemp('round14-c-perf4-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/job-history.json');
    final history = JobHistoryStore(historyFileProvider: () async => file);
    final entries = <Object?>[
      null,
      42,
      'skip',
      for (var i = 0; i < 35; i++)
        {
          'id': 'job-$i',
          'inputPath': '/book-$i.epub',
          'fileName': '书$i \\" } ], ${'字' * 3000}',
          'status': 'completed',
          'createdAt': '2026-01-01T00:00:00.000Z',
        },
    ];
    final raw = jsonEncode(entries);
    final decoded = jsonDecode(raw) as List;
    final expected = <Object?>[];
    for (final entry in decoded.whereType<Map>().take(20)) {
      await file.writeAsString(jsonEncode([entry]));
      final single = await history.load();
      expect(single, hasLength(1));
      expected.add(single.single.toJson());
    }
    for (final text in [raw, '{"jobs":$raw,"clearedAt":123,"version":2}']) {
      await file.writeAsString('\uFEFF$text');
      final loaded = await history.loadWithTombstone();
      expect(loaded.jobs.map((job) => job.toJson()).toList(), expected);
      expect(loaded.clearedAt, text.startsWith('{') ? 123 : 0);
    }
    // A corrupt tail must still take the existing backup path after 20 jobs.
    await file.writeAsString('$raw trailing');
    expect(await history.load(), isEmpty);
    expect(await root.list().where((f) => f.path.contains('.bad-')).length, 1);
  });

  // C-性能-5: gated process launch exercises the actual public query path.
  test('C-性能-5 concurrent long-path queries share future', () async {
    NativePlatformBridge.resetWindowsLongPathsCacheForTest();
    addTearDown(() {
      NativePlatformBridge.debugWindowsProcessStarter = null;
      NativePlatformBridge.resetWindowsLongPathsCacheForTest();
    });
    for (final fail in [false, true]) {
      NativePlatformBridge.resetWindowsLongPathsCacheForTest();
      final gate = Completer<void>();
      var starts = 0;
      NativePlatformBridge.debugWindowsProcessStarter = (_, args) async {
        starts++;
        await gate.future;
        if (fail) throw StateError('launch failed');
        return _ProbeProcess();
      };
      final queries = List.generate(
        20,
        (_) => NativePlatformBridge.windowsLongPathsEnabled(),
      );
      expect(starts, 1);
      expect(queries.every((q) => identical(q, queries.first)), isTrue);
      gate.complete();
      expect(
        await Future.wait(queries),
        List<bool?>.filled(20, fail ? null : true),
      );
      expect(
        await NativePlatformBridge.windowsLongPathsEnabled(),
        fail ? null : true,
      );
      expect(starts, 1, reason: 'completed outcomes remain cached');
    }
  });

  test('C-质量-1 mounted recheck after replay await', () async {
    final replayStore = _ReplayStore();
    final replayNotices = <Object?>[];
    final replayController = SettingsController(
      replayStore,
      onSaveError: replayNotices.add,
    );
    addTearDown(() {
      if (replayController.mounted) replayController.dispose();
    });
    await replayController.ready;
    replayStore.saveError = SettingsWriteConflict();
    expect(await replayController.setTargetLanguage('French'), isFalse);
    replayStore.saveError = null;
    replayStore.loadError = SettingsWriteConflict();
    final gate = replayStore.saveGate = Completer<void>();
    final started = replayStore.saveStarted = Completer<void>();
    final recovering = replayController.setOutputSuffix('_must_not_apply');
    final result = expectLater(recovering, completion(isFalse));
    await started.future;
    expect(replayController.isReplayingConflictedEdits, isTrue);
    final noticeCount = replayNotices.length;
    replayController.dispose();
    gate.complete();
    await result;
    expect(replayStore.attempts, hasLength(2));
    expect(replayStore.persisted.targetLanguage, 'French');
    expect(replayStore.persisted.outputSuffix, isNot('_must_not_apply'));
    expect(replayNotices, hasLength(noticeCount));
  });

  testWidgets('C-质量-2 sliders expose semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    final container = await showSettings(tester);
    await tester.ensureVisible(find.byType(ExpansionTile));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    final sliders = find.descendant(
      of: find.byType(ExpansionTile),
      matching: find.byType(Slider),
    );
    expect(sliders, findsNWidgets(5));
    for (final language in [UiLanguage.chinese, UiLanguage.english]) {
      await container.read(settingsProvider.notifier).setUiLanguage(language);
      await tester.pumpAndSettle();
      final chinese = language == UiLanguage.chinese;
      final expected = chinese
          ? ['分块大小 1000 字符', '并发数 2', '超时 120 秒', '最多重试 3 次', '重试间隔 4 秒']
          : [
              'Chunk size 1000 characters',
              'Concurrency 2',
              'Timeout 120 seconds',
              'Maximum retries 3',
              'Retry delay 4 seconds',
            ];
      final samples = [1000.0, 2.0, 120.0, 3.0, 4.0];
      for (var i = 0; i < 5; i++) {
        final finder = sliders.at(i);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final slider = tester.widget<Slider>(finder);
        final formatter = slider.semanticFormatterCallback;
        expect(formatter, isNotNull);
        expect(formatter!(samples[i]), expected[i]);
        final merged = find.ancestor(
          of: finder,
          matching: find.byType(MergeSemantics),
        );
        expect(merged, findsOneWidget);
        expect(
          find.descendant(of: merged, matching: find.byType(Semantics)),
          findsWidgets,
        );
        final node = tester.getSemantics(merged).getSemanticsData();
        expect(node.value, formatter(slider.value));
        expect(node.increasedValue, isNotEmpty);
      }
    }
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
