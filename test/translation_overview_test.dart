import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_overview.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_workflow_steps.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a clear completion card when output is ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranslationOverview(
              strings: const AppStrings(UiLanguage.english),
              job: const TranslationJob(
                id: 'job-1',
                inputPath: 'book.epub',
                outputPath: 'book_translated.epub',
                status: TranslationJobStatus.completed,
                phase: TranslationJobPhase.translation,
                progress: 1,
              ),
              onTranslatePressed: () {},
              onExportPressed: () {},
              onSaveToDownloadsPressed: () {},
              canTranslate: true,
              estimate: const TranslationRunEstimate(
                selectedChapters: 2,
                totalBlocks: 12,
                estimatedApiBatches: 3,
                completedBlocks: 12,
                blocksPerMinute: 18,
                estimatedRemaining: Duration.zero,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Completed'), findsOneWidget);
    expect(
      find.text('book_translated.epub', skipOffstage: false),
      findsWidgets,
    );
  });

  testWidgets('shows exportable warning state for partial output', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranslationOverview(
              strings: const AppStrings(UiLanguage.chinese),
              job: const TranslationJob(
                id: 'warning-job',
                inputPath: 'book.epub',
                outputPath: 'book_translated.epub',
                status: TranslationJobStatus.completedWithWarnings,
                phase: TranslationJobPhase.translation,
                progress: 1,
                completedBlocks: 12,
                totalBlocks: 12,
                degradedBlockCount: 2,
              ),
              onTranslatePressed: () {},
              onExportPressed: () {},
              onSaveToDownloadsPressed: () {},
              canTranslate: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('完成但有警告'), findsOneWidget);
    expect(find.text('2 个块未能完成翻译，可导出当前 EPUB 后重试。'), findsOneWidget);
    expect(
      find.text('book_translated.epub', skipOffstage: false),
      findsWidgets,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
  });

  testWidgets('does not show export UI after inspection-only jobs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranslationOverview(
              strings: const AppStrings(UiLanguage.english),
              job: const TranslationJob(
                id: 'job-1',
                inputPath: 'book.epub',
                outputPath: 'C:\\output',
                status: TranslationJobStatus.inspected,
                progress: 1,
                currentChapter: 'Ready for translation',
              ),
              onTranslatePressed: () {},
              onExportPressed: () {},
              onSaveToDownloadsPressed: () {},
              canTranslate: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('book_translated.epub'), findsNothing);
    expect(find.text('Open EPUB'), findsNothing);
  });

  testWidgets('shows checkpoint scan and verified cache during restoration', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranslationOverview(
              strings: const AppStrings(UiLanguage.chinese),
              job: const TranslationJob(
                id: 'resume',
                inputPath: 'book.epub',
                outputPath: 'out.epub',
                status: TranslationJobStatus.running,
                phase: TranslationJobPhase.cacheRestoration,
                progress: 605 / 1643,
                completedBlocks: 605,
                totalBlocks: 1643,
                resumeCheckpointBlocks: 605,
                cacheScanScannedBlocks: 820,
                cacheScanTotalBlocks: 1643,
                cachedBlocks: 354,
                resumedBlocks: 354,
              ),
              onTranslatePressed: () {},
              onExportPressed: () {},
              onSaveToDownloadsPressed: () {},
              canTranslate: false,
            ),
          ),
        ),
      ),
    );

    expect(find.text('正在恢复缓存'), findsOneWidget);
    expect(find.textContaining('待校验断点：605/1643'), findsOneWidget);
    expect(find.textContaining('缓存扫描：820/1643'), findsOneWidget);
    expect(find.textContaining('已确认复用：354 块'), findsOneWidget);
    expect(find.textContaining('继续翻译'), findsNothing);
  });

  testWidgets('workflow labels cache restoration independently', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranslationWorkflowSteps(
            strings: const AppStrings(UiLanguage.chinese),
            hasInput: true,
            hasInspectedChapters: true,
            canTranslate: false,
            job: const TranslationJob(
              id: 'resume',
              inputPath: 'book.epub',
              outputPath: 'out.epub',
              status: TranslationJobStatus.running,
              phase: TranslationJobPhase.cacheRestoration,
              progress: 0.37,
            ),
          ),
        ),
      ),
    );

    expect(find.text('恢复缓存中'), findsOneWidget);
    expect(find.text('翻译中'), findsNothing);
  });
}
