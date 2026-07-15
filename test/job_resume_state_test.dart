import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads numeric counters from compatible json values safely', () {
    final JobResumeState state = JobResumeState.fromJson(<String, dynamic>{
      'jobKey': 'job-key',
      'inputFingerprint': 'fingerprint',
      'inputPath': 'input.epub',
      'outputPath': 'output.epub',
      'status': 'running',
      'completedFiles': 1.0,
      'totalFiles': '2',
      'completedBlocks': -1,
      'totalBlocks': '10.0',
      'cachedBlocks': null,
      'resumedBlocks': 3,
      'currentChapter': 'Chapter 1',
      'updatedAtIso8601': '2026-06-24T00:00:00.000',
    });

    expect(state.completedFiles, 1);
    expect(state.totalFiles, 2);
    expect(state.completedBlocks, 0);
    expect(state.totalBlocks, 10);
    expect(state.cachedBlocks, 0);
    expect(state.resumedBlocks, 3);
  });

  test('falls back for incompatible scalar json values', () {
    final JobResumeState state = JobResumeState.fromJson(<String, dynamic>{
      'jobKey': 123,
      'inputFingerprint': false,
      'inputPath': <String>['input.epub'],
      'outputPath': null,
      'status': 404,
      'completedFiles': <int>[1],
      'updatedAtIso8601': Object(),
    });

    expect(state.jobKey, isEmpty);
    expect(state.inputFingerprint, isEmpty);
    expect(state.inputPath, isEmpty);
    expect(state.outputPath, isEmpty);
    expect(state.status, 'running');
    expect(state.completedFiles, 0);
    expect(state.updatedAtIso8601, isEmpty);
  });
}
