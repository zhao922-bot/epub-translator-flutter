import 'package:epub_translator_flutter/features/jobs/domain/models/job_summary.dart';
import 'package:epub_translator_flutter/features/jobs/presentation/widgets/job_row.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

JobSummary _failedJob({bool retryBlocked = false}) => JobSummary(
  id: 'failed-job',
  title: 'failed.epub',
  status: TranslationJobStatus.failed,
  progressLabel: '2 / 10 blocks',
  outputPath: 'out',
  errorMessage: 'boom',
  isActive: false,
  canOpenOutput: false,
  canRetry: true,
  retryBlocked: retryBlocked,
);

Future<void> _pumpRow(
  WidgetTester tester,
  AppStrings strings,
  JobSummary job,
  VoidCallback onRetry,
) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: JobRow(
          job: job,
          strings: strings,
          onOpen: () {},
          onRetry: onRetry,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('blocked retry explains via snackbar instead of retrying', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.chinese);
    bool retried = false;
    await _pumpRow(
      tester,
      strings,
      _failedJob(retryBlocked: true),
      () => retried = true,
    );

    await tester.tap(find.byIcon(Icons.replay_rounded));
    await tester.pump();

    expect(retried, isFalse);
    expect(find.text(strings.retryBlockedByActiveRun), findsOneWidget);
  });

  testWidgets('unblocked retry still calls onRetry', (tester) async {
    const strings = AppStrings(UiLanguage.english);
    bool retried = false;
    await _pumpRow(
      tester,
      strings,
      _failedJob(retryBlocked: false),
      () => retried = true,
    );

    await tester.tap(find.byIcon(Icons.replay_rounded));
    await tester.pump();

    expect(retried, isTrue);
    expect(find.text(strings.retryBlockedByActiveRun), findsNothing);
  });
}
