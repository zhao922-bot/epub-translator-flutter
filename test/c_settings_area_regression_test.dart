import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/logging/app_logger.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

class _Secrets implements SettingsSecretStore {
  final values = <SettingsSecretSlot, String>{};
  final writeErrors = <SettingsSecretSlot, Object>{};
  final readErrors = <SettingsSecretSlot, Object>{};
  int writes = 0;
  Future<String?> read(SettingsSecretSlot slot) async {
    if (readErrors[slot] case final error?) throw error;
    return values[slot];
  }

  Future<void> write(SettingsSecretSlot slot, String? value) async {
    writes++;
    if (writeErrors[slot] case final error?) throw error;
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

class _DelayedStore extends SettingsStore {
  final loading = Completer<TranslationConfig>();
  final saved = <TranslationConfig>[];
  @override
  Future<TranslationConfig> load() => loading.future;
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    saved.add(config);
  }
}

class _History extends JobHistoryStore {
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: <TranslationJob>[], clearedAt: 0);
}

class _Repository implements TranslationRepository {
  final tested = <TranslationConfig>[];
  @override
  Future<String> testConnection({required TranslationConfig config}) async {
    tested.add(config);
    return 'Connected';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<File> _file() async {
  final dir = await Directory.systemTemp.createTemp('c_settings_');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}/settings.json');
}

ProviderContainer _container(SettingsStore store, {_Repository? repository}) {
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      jobHistoryStoreProvider.overrideWithValue(_History()),
      if (repository != null)
        settingsRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _page(WidgetTester tester, ProviderContainer container) =>
    tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('successful save and reopening settings never shows a failure', (
    tester,
  ) async {
    final file = (await tester.runAsync(_file))!;
    final container = _container(
      SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: _Secrets(),
      ),
    );
    await tester.runAsync(
      () => container.read(settingsProvider.notifier).ready,
    );
    final controller = container.read(settingsProvider.notifier);
    await tester.runAsync(() => controller.setApiKey('saved-key'));
    expect(container.read(settingsSaveErrorProvider), isNull);
    // Also accept an empty event left by older state owners.
    container.read(settingsSaveErrorProvider.notifier).state = (
      id: 1,
      message: null,
      settingsFileLocked: false,
    );
    await _page(tester, container);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _page(tester, container);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(container.read(settingsProvider).apiKey, 'saved-key');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an existing genuine save failure uses the selected UI language',
    (tester) async {
      final file = (await tester.runAsync(_file))!;
      final container = _container(
        SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: _Secrets(),
        ),
      );
      await tester.runAsync(
        () => container.read(settingsProvider.notifier).ready,
      );
      final controller = container.read(settingsProvider.notifier);
      await tester.runAsync(() => controller.setUiLanguage(UiLanguage.chinese));
      container.read(settingsSaveErrorProvider.notifier).state = (
        id: 1,
        message: 'private error details',
        settingsFileLocked: false,
      );
      await _page(tester, container);
      await tester.pumpAndSettle();
      expect(
        find.text(const AppStrings(UiLanguage.chinese).settingsSaveFailed),
        findsOneWidget,
      );
      expect(find.text('private error details'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'C-03 failed proxy migration survives theme save and restart, then migrates securely',
    () async {
      final file = await _file();
      const proxy = 'http://old-user:old-password@proxy.example:8080';
      await file.writeAsString(jsonEncode({'httpProxy': proxy}));
      final secrets = _Secrets()
        ..writeErrors[SettingsSecretSlot.proxy] = StateError('locked');
      SettingsStore store() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final first = store();
      final loaded = await first.load();
      await first.save(loaded.copyWith(themeMode: AppThemeMode.light));
      expect(jsonDecode(await file.readAsString())['httpProxy'], proxy);
      expect((await store().load()).httpProxy, proxy);
      secrets.writeErrors.clear();
      final recovered = await store().load();
      expect(recovered.httpProxy, proxy);
      expect(await file.readAsString(), isNot(contains('old-password')));
      expect((await store().load()).httpProxy, proxy);
    },
  );

  for (final value in [
    double.nan,
    double.infinity,
    double.negativeInfinity,
    'NaN',
    'Infinity',
    '-Infinity',
    '1e999',
  ]) {
    test('C-05 non-finite $value restores each numeric default and logs', () {
      final events = <OutputEvent>[];
      void listener(OutputEvent event) => events.add(event);
      Logger.addOutputListener(listener);
      addTearDown(() => Logger.removeOutputListener(listener));
      final defaults = TranslationConfig.defaults();
      final numeric = [
        'textScale',
        'chunkSize',
        'maxConcurrent',
        'timeoutSeconds',
        'maxRetries',
        'retryDelaySeconds',
      ];
      final config = TranslationConfig.fromJson({
        for (final field in numeric) field: value,
      });
      for (final field in numeric) {
        expect(config.toJson()[field], defaults.toJson()[field], reason: field);
      }
      expect(
        events.where((event) => event.lines.join().contains('Non-finite')),
        hasLength(numeric.length),
      );
      expect(() => jsonEncode(config.toJson()), returnsNormally);
    });
  }

  test(
    'C-05 settings file overflowing JSON number preserves other settings',
    () async {
      final file = await _file();
      await file.writeAsString(
        '{"textScale":1e999,"chunkSize":-1e999,"themeMode":"light"}',
      );
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: _Secrets(),
      );
      final config = await store.load();
      expect(config.textScale, 1);
      expect(config.chunkSize, 3000);
      expect(config.themeMode, AppThemeMode.light);
      expect(store.didCorruptReset, isFalse);
    },
  );

  testWidgets(
    'C-06 read failures are visible, distinct from missing and configured credentials',
    (tester) async {
      final file = (await tester.runAsync(_file))!;
      final secrets = _Secrets()
        ..readErrors[SettingsSecretSlot.deepSeek] = StateError('unavailable')
        ..readErrors[SettingsSecretSlot.proxy] = StateError('unavailable');
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final container = _container(store);
      await tester.runAsync(
        () => container.read(settingsProvider.notifier).ready,
      );
      await _page(tester, container);
      await tester.pumpAndSettle();
      const strings = AppStrings(UiLanguage.english);
      expect(find.text(strings.credentialReadFailed), findsNWidgets(2));
      expect(
        const AppStrings(UiLanguage.chinese).credentialReadFailed,
        contains('读取失败'),
      );
      secrets.readErrors.clear();
      expect(
        await tester.runAsync(
          () => container.read(settingsProvider.notifier).setApiKey('restored'),
        ),
        isTrue,
      );
      await tester.runAsync(
        () => container.read(settingsProvider.notifier).setHttpProxy(''),
      );
      await tester.pumpAndSettle();
      expect(find.text(strings.credentialReadFailed), findsNothing);
      expect(store.secretReadFailed(SettingsSecretSlot.deepSeek), isFalse);
      expect(container.read(settingsProvider).apiKey, 'restored');
      expect(container.read(settingsProvider).httpProxy, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'C-07 unrelated successful save keeps unresolved key save notice until explicit retry',
    () async {
      final file = await _file();
      final secrets = _Secrets();
      final container = _container(
        SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        ),
      );
      final controller = container.read(settingsProvider.notifier);
      await controller.ready;
      secrets.writeErrors[SettingsSecretSlot.deepSeek] = StateError('failed');
      expect(await controller.setApiKey('new-key'), isFalse);
      final notice = container.read(settingsSaveErrorProvider);
      expect(notice?.message, contains('DeepSeek'));
      // The implicit retry during a theme save may succeed, but is not the
      // user's explicit resolution of the key failure.
      secrets.writeErrors.clear();
      await controller.setThemeMode(AppThemeMode.light);
      expect(container.read(settingsSaveErrorProvider), notice);
      expect(await controller.setApiKey('new-key'), isTrue);
      expect(container.read(settingsSaveErrorProvider)?.message, isNull);
    },
  );

  test(
    'C-08 unsupported wrapped migration stops retrying, transient failures retry',
    () async {
      for (final unsupported in [true, false]) {
        final file = await _file();
        await file.writeAsString(jsonEncode({'apiKey': 'legacy'}));
        final secrets = _Secrets()
          ..writeErrors[SettingsSecretSlot.deepSeek] = unsupported
              ? UnsupportedError('no backend')
              : StateError('temporarily locked');
        final store = SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        await store.load();
        final writes = secrets.writes;
        await store.load();
        expect(secrets.writes, unsupported ? writes : greaterThan(writes));
      }
    },
  );

  test(
    'C-09 all four failures retain slot and original errors without leaking secrets',
    () async {
      final file = await _file();
      final secrets = _Secrets();
      for (final slot in SettingsSecretSlot.values) {
        secrets.writeErrors[slot] = slot == SettingsSecretSlot.proxy
            ? UnsupportedError('private-password')
            : StateError('private-key');
      }
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await store.load();
      try {
        await store.save(
          TranslationConfig.defaults().copyWith(
            apiKey: 'private-key',
            deepseekApiKey: 'private-key',
            customApiKey: 'private-key',
            httpProxy: 'http://user:private-password@host:8080',
          ),
          explicitSecretMutations: SettingsSecretSlot.values.toSet(),
        );
        fail('Expected aggregate failure');
      } on SettingsSecretSaveException catch (error) {
        expect(error.failures.keys.toSet(), SettingsSecretSlot.values.toSet());
        for (final slot in SettingsSecretSlot.values) {
          expect(
            identical(error.failures[slot], secrets.writeErrors[slot]),
            isTrue,
          );
        }
        expect(error.isUnsupported, isTrue);
        for (final label in [
          'API key',
          'DeepSeek key',
          'custom key',
          'proxy authentication',
        ]) {
          expect('$error', contains(label));
        }
        expect('$error', isNot(contains('private-')));
      }
    },
  );

  test(
    'C-10 rotation notice clears only after all rotated credentials recover',
    () async {
      final file = await _file();
      final secrets = _Secrets()
        ..readErrors[SettingsSecretSlot.legacy] =
            const SecretKeyRotatedException()
        ..readErrors[SettingsSecretSlot.deepSeek] =
            const SecretKeyRotatedException();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final container = _container(store);
      final controller = container.read(settingsProvider.notifier);
      await controller.ready;
      expect(container.read(secretKeyRotatedNoticeProvider), isNotNull);
      await controller.setThemeMode(AppThemeMode.light);
      expect(container.read(secretKeyRotatedNoticeProvider), isNotNull);
      secrets.readErrors.clear();
      secrets.writeErrors[SettingsSecretSlot.deepSeek] = StateError('failed');
      expect(await controller.setApiKey('recovered'), isFalse);
      expect(container.read(secretKeyRotatedNoticeProvider), isNotNull);
      secrets.writeErrors.clear();
      expect(await controller.setApiKey('recovered'), isTrue);
      expect(store.secretKeyRotated, isFalse);
      expect(container.read(secretKeyRotatedNoticeProvider), isNull);
    },
  );

  testWidgets(
    'C-11 slider updates immediately, debounce and drag-end write once',
    (tester) async {
      final store = _DelayedStore()
        ..loading.complete(TranslationConfig.defaults());
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;
      unawaited(controller.setTextScale(1.1));
      await tester.pump();
      expect(controller.state.textScale, 1.1);
      await tester.pump(const Duration(milliseconds: 300));
      unawaited(controller.setTextScale(1.2));
      await tester.pump();
      expect(controller.state.textScale, 1.2);
      expect(store.saved, isEmpty);
      await tester.pump(const Duration(milliseconds: 399));
      expect(store.saved, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(store.saved, hasLength(1));
      expect(store.saved.single.textScale, 1.2);
      unawaited(controller.setChunkSize(6000));
      await tester.pump();
      await controller.flushSliderChanges();
      expect(store.saved, hasLength(2));
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.saved, hasLength(2));
    },
  );

  testWidgets(
    'C-11 page slider drag-end flushes latest value without duplicate writes',
    (tester) async {
      final store = _DelayedStore()
        ..loading.complete(TranslationConfig.defaults());
      final container = _container(store);
      await container.read(settingsProvider.notifier).ready;
      await _page(tester, container);
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(find.byType(Slider).last);
      slider.onChanged!(1.1);
      slider.onChanged!(1.2);
      expect(container.read(settingsProvider).textScale, 1.2);
      expect(store.saved, isEmpty);
      slider.onChangeEnd!(1.2);
      await tester.pump();
      expect(store.saved.single.textScale, 1.2);
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.saved, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('C-12 proxy credentials start obscured and toggle visibility', (
    tester,
  ) async {
    final store = _DelayedStore()
      ..loading.complete(
        TranslationConfig.defaults().copyWith(
          httpProxy: 'http://user:password@host:8080',
        ),
      );
    final container = _container(store);
    await container.read(settingsProvider.notifier).ready;
    await _page(tester, container);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('settings-http-proxy'));
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editable).obscureText, isTrue);
    final toggle = find.descendant(
      of: field,
      matching: find.byType(IconButton),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editable).obscureText, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editable).obscureText, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'C-28 final logger text includes stack without exposing FormatException input',
    () {
      final events = <OutputEvent>[];
      void listener(OutputEvent event) => events.add(event);
      Logger.addOutputListener(listener);
      addTearDown(() => Logger.removeOutputListener(listener));
      AppLogger.error(
        'Failed',
        error: const FormatException('password', 'private-key'),
        stackTrace: StackTrace.fromString('settings_store.dart:123'),
      );
      expect(
        events.single.lines.join('\n'),
        contains('settings_store.dart:123'),
      );
      expect(events.single.lines.join('\n'), isNot(contains('private-key')));
      expect('${events.single.origin.error}', isNot(contains('password')));
    },
  );

  testWidgets(
    'C-29 connection button disabled until initial settings load completes',
    (tester) async {
      final store = _DelayedStore();
      final repository = _Repository();
      final container = _container(store, repository: repository);
      await _page(tester, container);
      await tester.pumpAndSettle();
      final button = find.widgetWithText(
        FilledButton,
        const AppStrings(UiLanguage.english).testConnection,
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pump();
      expect(repository.tested, isEmpty);
      store.loading.complete(
        TranslationConfig.defaults().copyWith(
          model: 'persisted-model',
          apiKey: 'persisted-key',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(repository.tested.single.model, 'persisted-model');
      expect(repository.tested.single.apiKey, 'persisted-key');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
