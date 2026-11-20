import 'dart:io';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/preview/application/preview_block_reader.dart';
import 'package:epub_translator_flutter/features/preview/application/preview_provider.dart';
import 'package:epub_translator_flutter/features/preview/presentation/pages/preview_page.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_session_path_store.dart';
import 'support/epub_fixture_factory.dart';

class _TestSettingsStore extends SettingsStore {
  @override
  Future<TranslationConfig> load() async =>
      TranslationConfig.defaults().copyWith(uiLanguage: UiLanguage.english);
}

class _TestHistoryStore extends JobHistoryStore {
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: const <TranslationJob>[], clearedAt: 0);
}

InspectedChapter _chapter(String title, String source) =>
    const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: '$title.xhtml',
      bytes:
          '<html><head><title>$title</title></head><body>$source</body></html>'
              .codeUnits,
    );

Future<ProviderContainer> _openPreview(
  WidgetTester tester,
  List<InspectedChapter> chapters,
) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(_TestSettingsStore()),
      sessionPathStoreProvider.overrideWithValue(MemorySessionPathStore()),
      jobHistoryStoreProvider.overrideWithValue(_TestHistoryStore()),
    ],
  );
  addTearDown(container.dispose);
  final controller = container.read(translationDashboardProvider.notifier);
  controller.state = controller.state.copyWith(inspectedChapters: chapters);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: PreviewPage())),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test('released block sources are loaded only when requested', () async {
    final dir = await Directory.systemTemp.createTemp('folio_preview_');
    addTearDown(() => dir.delete(recursive: true));
    final book = await makeBook(
      dir,
      'source',
      '<html xmlns="$ns"><body><p>Original</p></body></html>',
    );
    final result = await EpubInspector().inspect(
      inputPath: book.path,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
    );
    final chapter = result.chapters.firstWhere(
      (chapter) => chapter.path == 'OPS/c.xhtml',
    );
    final released = chapter.copyWith(
      originalHtml: '',
      translatedBody: 'Translation',
      blocks: [
        chapter.blocks.single.copyWith(
          sourceHtml: '',
          sourceText: '',
          translatedHtml: '<p>Translation</p>',
        ),
      ],
    );
    final reader = PreviewBlockReader(released, () => false);
    expect(await reader.read(0), (
      source: 'Original',
      translation: 'Translation',
    ));
    await book.delete();
    final missing = PreviewBlockReader(released, () => false);
    expect(await missing.read(0), (source: '', translation: 'Translation'));
  });
  testWidgets('chapter filters keep the selected index and inclusion', (
    tester,
  ) async {
    final container = await _openPreview(tester, [
      _chapter('First story', '<p>First passage.</p>'),
      _chapter(
        'Second story',
        '<p>Second passage.</p>',
      ).copyWith(degradedBlockCount: 1, reviewWarningBlockCount: 1),
    ]);
    expect(find.text('First passage.'), findsOneWidget);
    await tester.tap(find.text('Warnings only'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsOneWidget);
    expect(container.read(previewSelectedIndexProvider), 0);
    expect(find.text('First passage.'), findsOneWidget);
    await tester.tap(find.text('Second story'));
    await tester.pumpAndSettle();
    expect(container.read(previewSelectedIndexProvider), 1);
    expect(find.text('Second passage.'), findsOneWidget);
    expect(find.text('1 degraded block'), findsWidgets);
    expect(find.text('1 block needs review'), findsWidgets);

    final search = find.widgetWithText(TextField, 'Search chapters');
    await tester.enterText(search, 'no such chapter');
    await tester.pumpAndSettle();
    expect(find.text('No matching chapters.'), findsOneWidget);
    expect(container.read(previewSelectedIndexProvider), 1);
    expect(find.text('Second passage.'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });

  testWidgets('excerpt and bounded block pages highlight literal matches', (
    tester,
  ) async {
    final prefix = 'a' * 4000;
    final chapter = _chapter(
      'Long story',
      '<p>$prefix A+B ${'x' * 2200}</p>',
    ).copyWith(translatedBody: 'Translated A+B');
    final translated = chapter.copyWith(
      blocks: [
        chapter.blocks.single.copyWith(translatedHtml: '<p>Translated A+B</p>'),
      ],
    );
    await _openPreview(tester, [translated]);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search excerpt'),
      'a+b',
    );
    await tester.pumpAndSettle();
    int highlightedMatches() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .expand((widget) => widget.textSpan?.children ?? const <InlineSpan>[])
        .whereType<TextSpan>()
        .where(
          (span) => span.text == 'A+B' && span.style?.backgroundColor != null,
        )
        .length;
    expect(highlightedMatches(), 2);

    await tester.tap(find.text('Browse blocks'));
    await tester.pumpAndSettle();
    expect(find.text('Block 1 of 1'), findsOneWidget);
    expect(find.text(prefix), findsOneWidget);
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2'), findsOneWidget);
    final dialog = find.byType(Dialog);
    final passages = find.descendant(
      of: dialog,
      matching: find.byType(SelectableText),
    );
    final visibleBody = tester.widget<SelectableText>(passages.first).textSpan!;
    expect(visibleBody.toPlainText(), startsWith(' A+B'));
    expect(
      visibleBody.children!.whereType<TextSpan>().any(
        (span) => span.text == 'A+B' && span.style?.backgroundColor != null,
      ),
      isTrue,
    );
  });
}
