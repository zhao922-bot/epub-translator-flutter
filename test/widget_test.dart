import 'dart:async';

import 'package:epub_translator_flutter/app/app.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _WidgetSettingsStore extends SettingsStore {
  _WidgetSettingsStore(this.loadCompleter);

  final Completer<TranslationConfig> loadCompleter;

  @override
  Future<TranslationConfig> load() => loadCompleter.future;

  @override
  Future<void> save(TranslationConfig config) async {}
}

class _WidgetJobHistoryStore extends JobHistoryStore {
  @override
  Future<List<TranslationJob>> load() async => const <TranslationJob>[];

  @override
  Future<void> save(List<TranslationJob> jobs) async {}
}

void main() {
  Widget testApp({Completer<TranslationConfig>? loadCompleter}) {
    final Completer<TranslationConfig> completer =
        loadCompleter ??
        (Completer<TranslationConfig>()
          ..complete(TranslationConfig.defaults()));
    return ProviderScope(
      overrides: <Override>[
        settingsStoreProvider.overrideWithValue(
          _WidgetSettingsStore(completer),
        ),
        jobHistoryStoreProvider.overrideWithValue(_WidgetJobHistoryStore()),
      ],
      child: const EpubTranslatorApp(),
    );
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.settings_rounded).first);
    await tester.pumpAndSettle();
  }

  Future<void> openTranslation(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.translate_rounded).first);
    await tester.pumpAndSettle();
  }

  testWidgets('app boots into translation workspace shell', (tester) async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>()..complete(TranslationConfig.defaults());
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pumpAndSettle();

    // Drop zone is the primary entry; step strip shows short status.
    expect(find.textContaining('Drop or choose EPUB'), findsOneWidget);
    expect(find.text('Choose EPUB'), findsOneWidget);
    expect(find.text('Book'), findsNothing);
    expect(find.textContaining('Step '), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('translation-import-zone')),
      findsOneWidget,
    );
  });

  testWidgets('shared page structure and primary import action are present', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('page-scaffold')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('page-scaffold-header')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('page-scaffold-body')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('section-card-emphasis')),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey<String>('translation-import-zone')),
      findsOneWidget,
    );
    expect(find.textContaining('Drop or choose EPUB'), findsOneWidget);
    expect(find.text('Browse'), findsOneWidget);
  });

  testWidgets('settings page does not expose unsupported thinking toggle', (
    tester,
  ) async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>()..complete(TranslationConfig.defaults());
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pumpAndSettle();

    await openSettings(tester);

    expect(find.text('Disable thinking field'), findsNothing);
  });

  testWidgets('settings page switches the app theme mode', (tester) async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>()..complete(TranslationConfig.defaults());
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    await openSettings(tester);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
  });

  testWidgets('core controls remain usable on compact screens', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>()..complete(TranslationConfig.defaults());
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pumpAndSettle();

    await openTranslation(tester);
    expect(find.textContaining('Drop or choose EPUB'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('page-scaffold')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('translation-import-zone')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await openSettings(tester);
    expect(find.byKey(const ValueKey<String>('page-scaffold')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('section-card-emphasis')),
      findsWidgets,
    );
    await tester.ensureVisible(find.byTooltip('Show API key'));
    await tester.tap(find.byTooltip('Show API key'));
    await tester.pumpAndSettle();

    final EditableText apiKeyField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('settings-api-key')),
        matching: find.byType(EditableText),
      ),
    );
    expect(apiKeyField.obscureText, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('jobs and preview pages keep shared scaffold structure', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.list_alt_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('page-scaffold')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('section-card-standard')),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.chrome_reader_mode_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('page-scaffold')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('section-card-emphasis')),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings fields update after async settings load', (
    tester,
  ) async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pump();

    await openSettings(tester);

    loadCompleter.complete(
      TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://loaded.example/v1',
        apiKey: 'sk-loaded',
        model: 'loaded-model',
        outputSuffix: '_loaded',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('https://loaded.example/v1'), findsOneWidget);
    expect(find.text('loaded-model'), findsOneWidget);
    // Output suffix lives under Advanced parameters (may be off-screen).
    final Finder advanced = find.text('Advanced parameters');
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    final Finder suffixField = find.byKey(
      const ValueKey<String>('settings-output-suffix'),
    );
    await tester.ensureVisible(suffixField);
    expect(find.text('_loaded'), findsOneWidget);
  });

  testWidgets('translation controls update after async settings load', (
    tester,
  ) async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pump();
    await openTranslation(tester);

    loadCompleter.complete(
      TranslationConfig.defaults().copyWith(targetLanguage: 'Japanese'),
    );
    await tester.pumpAndSettle();

    final Finder targetLanguageFinder = find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString().startsWith('DropdownButtonFormField'),
    );
    final dynamic targetLanguageField = tester.widget(targetLanguageFinder);
    expect(targetLanguageField.initialValue, 'Japanese');
  });

  testWidgets('translation page accepts dropped EPUB paths from Windows', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    const MethodCodec codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'epub_translator/window_drop',
          codec.encodeMethodCall(
            const MethodCall('fileDropped', 'C:\\Books\\dragged.epub'),
          ),
          (_) {},
        );
    await tester.pumpAndSettle();

    // Primary UI shows basename; full path is under Advanced paths.
    expect(find.text('dragged.epub'), findsWidgets);
    expect(find.textContaining('Dropped EPUB: dragged.epub'), findsOneWidget);

    final Finder advancedPaths = find.text('Manual paths');
    await tester.ensureVisible(advancedPaths);
    await tester.tap(advancedPaths);
    await tester.pumpAndSettle();
    expect(find.text('C:\\Books\\dragged.epub'), findsOneWidget);
  });

  testWidgets('API key field is obscured by default', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await openSettings(tester);

    final EditableText apiKeyField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('settings-api-key')),
        matching: find.byType(EditableText),
      ),
    );
    expect(apiKeyField.obscureText, isTrue);
  });

  testWidgets('API key visibility can be toggled without losing the value', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await openSettings(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('settings-api-key')),
        matching: find.byType(EditableText),
      ),
      'sk-visible-toggle',
    );
    await tester.pump();

    await tester.ensureVisible(find.byTooltip('Show API key'));
    await tester.tap(find.byTooltip('Show API key'));
    await tester.pumpAndSettle();

    EditableText apiKeyField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('settings-api-key')),
        matching: find.byType(EditableText),
      ),
    );
    expect(apiKeyField.obscureText, isFalse);
    expect(find.text('sk-visible-toggle'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Hide API key'));
    await tester.tap(find.byTooltip('Hide API key'));
    await tester.pumpAndSettle();

    apiKeyField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('settings-api-key')),
        matching: find.byType(EditableText),
      ),
    );
    expect(apiKeyField.obscureText, isTrue);
  });

  testWidgets('settings page exposes translation tuning presets', (
    tester,
  ) async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    await tester.pumpWidget(testApp(loadCompleter: loadCompleter));
    await tester.pump();

    await openSettings(tester);
    loadCompleter.complete(TranslationConfig.defaults());
    await tester.pumpAndSettle();

    expect(find.text('Advanced parameters'), findsOneWidget);
    expect(find.text('Stable'), findsOneWidget);
    expect(find.text('Balanced'), findsOneWidget);
    expect(find.text('Fast'), findsOneWidget);
  });
}
