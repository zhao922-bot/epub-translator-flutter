import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_overview.dart';
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
}
