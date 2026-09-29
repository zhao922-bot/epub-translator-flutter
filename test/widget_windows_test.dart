@TestOn('windows')
library;

// Windows-only UI tests: they assert Windows-specific copy ('Drop or choose
// EPUB') and Windows file paths, so they only run on Windows.

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
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

class _WidgetJobHistoryStore extends JobHistoryStore {
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: const <TranslationJob>[], clearedAt: 0);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {}

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    return (written: true, fileClearedAt: 0);
  }
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
      find.byKey(const ValueKey<String>('settings-api-key')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('toggleApiKeyVisibility')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('toggleApiKeyVisibility')),
    );
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
    // Log line + floating SnackBar both surface the drop confirmation.
    expect(find.textContaining('Dropped EPUB: dragged.epub'), findsWidgets);

    final Finder advancedPaths = find.text('Manual paths');
    await tester.ensureVisible(advancedPaths);
    await tester.tap(advancedPaths);
    await tester.pumpAndSettle();
    expect(find.text('C:\\Books\\dragged.epub'), findsOneWidget);
  });

  testWidgets('multi-file drop imports the first file and says the rest '
      'were ignored', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    const MethodCodec codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'epub_translator/window_drop',
          codec.encodeMethodCall(
            const MethodCall('fileDropped', <String, Object>{
              'path': 'C:\\Books\\first.epub',
              'fileCount': 3,
            }),
          ),
          (_) {},
        );
    await tester.pumpAndSettle();

    // The first file is still imported.
    expect(find.text('first.epub'), findsWidgets);
    // ...but the user is told the other two were ignored.
    expect(
      find.textContaining('the first file was imported (3 dropped'),
      findsOneWidget,
    );
  });
}
