import '../../domain/models/job_resume_state.dart';
import '../../domain/models/translation_job.dart';
import '../translation_cache_store.dart';

/// Run-local, serialized checkpoints. Concurrent workers must not overwrite a
/// newer checkpoint with an older snapshot or reset another worker's counters.
class TranslationProgressPersistence {
  TranslationProgressPersistence({
    required this.cacheStore,
    required this.stateFor,
    required this.onCacheError,
    required this.onCheckpointError,
  });

  final TranslationCacheStore cacheStore;
  final JobResumeState Function(TranslationJob) stateFor;
  final void Function(Object, bool firstFailure) onCacheError;
  final void Function(Object, bool firstFailure) onCheckpointError;
  bool _cacheFailed = false;
  bool _checkpointFailed = false;
  int _completedSinceSave = 0;
  int _savedCompleted = 0;
  DateTime _lastSave = DateTime.now();
  Future<void> _tail = Future<void>.value();

  void blockCompleted() => _completedSinceSave += 1;

  static Future<Object?> putError(
    TranslationCacheStore store,
    String key,
    String html,
  ) async {
    try {
      await store.putBlockTranslation(key, html);
      return null;
    } catch (error) {
      return error;
    }
  }

  Future<bool> putBlock(String key, String html) async {
    final Object? error = await putError(cacheStore, key, html);
    if (error == null) return true;
    final bool first = !_cacheFailed;
    _cacheFailed = true;
    onCacheError(error, first);
    return false;
  }

  Future<void> save(TranslationJob job, {bool force = false}) {
    // Capture the count with the snapshot, not after awaiting a disk write.
    final int completedAtEnqueue = _completedSinceSave;
    final Future<void> operation = _tail.then((_) async {
      final DateTime now = DateTime.now();
      if (!force &&
          completedAtEnqueue - _savedCompleted < 20 &&
          now.difference(_lastSave) < const Duration(seconds: 10)) {
        return;
      }
      try {
        await cacheStore.saveJobState(stateFor(job));
        _lastSave = now;
        _savedCompleted = completedAtEnqueue;
      } catch (error) {
        final bool first = !_checkpointFailed;
        _checkpointFailed = true;
        onCheckpointError(error, first);
      }
    });
    _tail = operation;
    return operation;
  }
}
