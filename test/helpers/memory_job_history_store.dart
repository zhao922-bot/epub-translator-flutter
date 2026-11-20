import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';

class MemoryJobHistoryStore extends JobHistoryStore {
  List<TranslationJob> _jobs = const [];
  int _clearedAt = 0;

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: _jobs, clearedAt: _clearedAt);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    _jobs = List<TranslationJob>.unmodifiable(jobs);
    if (clearedAtEpochMs > _clearedAt) _clearedAt = clearedAtEpochMs;
  }

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    final previousClear = _clearedAt;
    await save(merge(_jobs, previousClear), clearedAtEpochMs: clearedAtEpochMs);
    return (written: true, fileClearedAt: previousClear);
  }
}
