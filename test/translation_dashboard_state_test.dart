import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('copyWith can clear the active job', () {
    final TranslationDashboardState state = TranslationDashboardState.initial()
        .copyWith(
          job: const TranslationJob(
            id: 'job-1',
            inputPath: 'input.epub',
            outputPath: 'output.epub',
            status: TranslationJobStatus.completed,
            progress: 1,
          ),
        );

    final TranslationDashboardState updated = state.copyWith(job: null);

    expect(updated.job, isNull);
  });
}
