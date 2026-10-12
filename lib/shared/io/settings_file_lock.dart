import 'dart:async';
import 'dart:io';

// POSIX file locks are process-scoped, so also serialize stores in this isolate.
final Map<String, Future<void>> _settingsWriters = {};

Future<T> withSettingsFileLock<T>(
  File file,
  Future<T> Function() action,
) async {
  final key = File(file.path).absolute.path;
  final previous = _settingsWriters[key] ?? Future<void>.value();
  final done = Completer<void>();
  _settingsWriters[key] = done.future;
  await previous;
  RandomAccessFile? handle;
  final File lockFile = File('$key.lock');
  try {
    await file.parent.create(recursive: true);
    handle = await lockFile.open(mode: FileMode.append);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        await handle.lock(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return await action();
  } finally {
    // Never delete the sidecar lock file here: POSIX locks are tied to the
    // inode, not the path. Deleting the file lets another process create a
    // new file at the same path and lock a different inode, so two
    // processes could hold "the lock" simultaneously and corrupt settings.
    // An empty sidecar left behind is harmless (job_history_store keeps its
    // sidecar permanently for the same reason).
    try {
      await handle?.close();
    } finally {
      // P1-#1: done.complete() must run even if close() throws; otherwise
      // _settingsWriters keeps an incomplete future and every later caller
      // hangs forever on `await previous`.
      done.complete();
      if (identical(_settingsWriters[key], done.future)) {
        _settingsWriters.remove(key);
      }
    }
  }
}
