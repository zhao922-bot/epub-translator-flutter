import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persists a confirmed style profile for history resume', () {
    const TranslationStyleProfile profile = TranslationStyleProfile(
      primaryGenre: 'business nonfiction',
      tone: 'concise',
      confidence: TranslationStyleConfidence.high,
    );
    const TranslationJob job = TranslationJob(
      id: 'resume-style',
      inputPath: 'book.epub',
      outputPath: 'book_translated.epub',
      status: TranslationJobStatus.failed,
      phase: TranslationJobPhase.translation,
      progress: 0.5,
      styleProfile: profile,
      styleProfileConfirmed: true,
      styleProfileEnabled: true,
    );

    final TranslationJob restored = TranslationJob.fromJson(job.toJson());

    expect(restored.styleProfileConfirmed, isTrue);
    expect(restored.styleProfileEnabled, isTrue);
    expect(restored.styleProfile.sameContentAs(profile), isTrue);
  });

  test('hasExportableEpub requires completed status and .epub path', () {
    const TranslationJob inspected = TranslationJob(
      id: 'inspected',
      inputPath: 'book.epub',
      outputPath: 'C:\\out',
      status: TranslationJobStatus.inspected,
      progress: 1,
    );
    const TranslationJob completedDirectory = TranslationJob(
      id: 'completed-dir',
      inputPath: 'book.epub',
      outputPath: 'C:\\out',
      status: TranslationJobStatus.completed,
      progress: 1,
    );
    const TranslationJob completedEpub = TranslationJob(
      id: 'completed-epub',
      inputPath: 'book.epub',
      outputPath: 'C:\\out\\book_translated.epub',
      status: TranslationJobStatus.completed,
      phase: TranslationJobPhase.translation,
      progress: 1,
    );

    expect(inspected.hasExportableEpub, isFalse);
    expect(completedDirectory.hasExportableEpub, isFalse);
    expect(completedEpub.hasExportableEpub, isTrue);
  });

  test('copyWith can clear nullable progress labels', () {
    const TranslationJob job = TranslationJob(
      id: 'job-1',
      inputPath: 'input.epub',
      outputPath: 'output.epub',
      status: TranslationJobStatus.running,
      progress: 0.5,
      currentChapter: 'Chapter 1',
      currentBlock: 'Block 1',
    );

    final TranslationJob updated = job.copyWith(
      status: TranslationJobStatus.completed,
      currentChapter: null,
      currentBlock: null,
    );

    expect(updated.status, TranslationJobStatus.completed);
    expect(updated.currentChapter, isNull);
    expect(updated.currentBlock, isNull);
  });

  test('persists failure diagnostics in job json', () {
    const TranslationJob job = TranslationJob(
      id: 'job-1',
      inputPath: 'input.epub',
      outputPath: 'output.epub',
      status: TranslationJobStatus.failed,
      progress: 0.5,
      errorMessage: 'HTTP 429: rate limited',
    );

    final TranslationJob restored = TranslationJob.fromJson(job.toJson());

    expect(restored.errorMessage, 'HTTP 429: rate limited');
    expect(restored.copyWith(errorMessage: null).errorMessage, isNull);
  });

  test('round-trips cache restoration progress', () {
    const TranslationJob job = TranslationJob(
      id: 'resume-1',
      inputPath: 'book.epub',
      outputPath: 'out.epub',
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.cacheRestoration,
      progress: 0.37,
      completedBlocks: 605,
      totalBlocks: 1643,
      resumeCheckpointBlocks: 605,
      cacheScanScannedBlocks: 820,
      cacheScanTotalBlocks: 1643,
      cachedBlocks: 354,
      resumedBlocks: 354,
    );

    final TranslationJob restored = TranslationJob.fromJson(job.toJson());

    expect(restored.phase, TranslationJobPhase.cacheRestoration);
    expect(restored.resumeCheckpointBlocks, 605);
    expect(restored.cacheScanScannedBlocks, 820);
    expect(restored.cacheScanTotalBlocks, 1643);
  });

  test('legacy jobs default cache restoration counters to zero', () {
    final TranslationJob restored = TranslationJob.fromJson(<String, dynamic>{
      'id': 'legacy',
      'status': 'failed',
      'phase': 'translation',
      'progress': 0.37,
      'completedBlocks': 605,
      'totalBlocks': 1643,
    });

    expect(restored.resumeCheckpointBlocks, 0);
    expect(restored.cacheScanScannedBlocks, 0);
    expect(restored.cacheScanTotalBlocks, 0);
  });

  test('cancelled cache restoration jobs remain resumable', () {
    const TranslationJob job = TranslationJob(
      id: 'cancelled-restoration',
      inputPath: 'book.epub',
      outputPath: 'out.epub',
      status: TranslationJobStatus.cancelled,
      phase: TranslationJobPhase.cacheRestoration,
      progress: 0.37,
      completedBlocks: 605,
      totalBlocks: 1643,
      resumeCheckpointBlocks: 605,
    );

    expect(job.canResumeTranslation, isTrue);
  });
}
