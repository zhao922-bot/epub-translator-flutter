import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:epub_translator_flutter/app/theme/app_theme.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_dashboard_page.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';

class _NoRequests implements TranslationRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

class _Controller extends TranslationDashboardController {
  _Controller(TranslationDashboardState seed)
    : super(repository: _NoRequests()) {
    state = seed;
  }
}

class _Settings extends SettingsStore {
  @override
  Future<TranslationConfig> load() async => TranslationConfig.defaults();
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

void main() {
  testWidgets('editing inspected EPUB path keeps the manual field open', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const strings = AppStrings(UiLanguage.english);
    final seed = TranslationDashboardState.initial().copyWith(
      inputPath: 'Book.epub',
      outputDirectory: 'Output',
      inspectedChapters: const <InspectedChapter>[
        InspectedChapter(
          path: 'chapter.xhtml',
          title: 'Chapter',
          body: 'Text',
          originalHtml: '<p>Text</p>',
          blocks: <ExtractedBlock>[],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
      ],
      job: const TranslationJob(
        id: 'inspected',
        inputPath: 'Book.epub',
        outputPath: 'Output',
        status: TranslationJobStatus.inspected,
        progress: 1,
      ),
    );
    late _Controller controller;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStringsProvider.overrideWithValue(strings),
          settingsStoreProvider.overrideWithValue(_Settings()),
          translationDashboardProvider.overrideWith(
            (ref) => controller = _Controller(seed),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(UiLanguage.english),
          home: const Scaffold(body: TranslationDashboardPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();

    final field = find.byKey(const ValueKey<String>('manual-input-path'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'NewBook.epub',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();

    expect(controller.state.inputPath, 'NewBook.epub');
    expect(controller.state.job, isNull);
    expect(field, findsOneWidget);
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    expect(
      tester.widget<EditableText>(editable).controller.selection.baseOffset,
      3,
    );
  });

  testWidgets(
    'partial output warning and open action are visible before inputs',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const strings = AppStrings(UiLanguage.chinese);
      final seed = TranslationDashboardState.initial().copyWith(
        inputPath: 'book.epub',
        outputDirectory: 'output',
        job: const TranslationJob(
          id: 'warning',
          inputPath: 'book.epub',
          outputPath: 'output/book_translated.epub',
          status: TranslationJobStatus.completedWithWarnings,
          phase: TranslationJobPhase.translation,
          progress: 1,
          totalBlocks: 18,
          completedBlocks: 18,
          degradedBlockCount: 3,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStringsProvider.overrideWithValue(strings),
            settingsStoreProvider.overrideWithValue(_Settings()),
            translationDashboardProvider.overrideWith(
              (ref) => _Controller(seed),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(UiLanguage.chinese),
            home: const Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: TranslationDashboardPage(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('完成但有警告').hitTestable(), findsOneWidget);
      expect(find.text(strings.openEpub).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
