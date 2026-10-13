import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

// The OS file lock below serializes *processes* (advisory flock on
// POSIX, mandatory LockFileEx on Windows). On POSIX it does NOT serialize
// Dart isolates in the same process: flock locks are associated with the
// open file description and a process never blocks on its own lock, so two
// isolates opening the same lock file would both succeed. (On Windows the
// mandatory lock is per-handle, so same-process isolates do conflict
// there.)
//
// The in-process future chain ([_settingsWriters]) serializes concurrent
// callers within a *single isolate* only: Dart isolates do not share a
// heap, so each isolate has its own top-level [_settingsWriters] map and
// chaining on it cannot exclude another isolate. (A chain keyed by
// absolute path still covers two File objects pointing at the same path
// within the isolate.)
//
// Net effect: same-isolate callers are serialized by the future chain,
// separate processes by the OS lock. Same-process cross-isolate writers
// are NOT mutually excluded on POSIX — a known limitation, not a
// guarantee (quality-#57: an earlier comment wrongly claimed the future
// chain provided cross-isolate mutual exclusion).
//
// P2-#31: `IsolateNameServer`-based locking was considered and rejected:
// it only works between isolates that explicitly register (spawned
// isolates don't share it by default), it cannot serialize against a
// second *process*, and a forgotten port mapping leaks the lock.
final Map<String, Future<void>> _settingsWriters = {};

Future<T> withSettingsFileLock<T>(
  File file,
  Future<T> Function() action,
) async {
  final key = path.normalize(file.absolute.path);
  final previous = _settingsWriters[key] ?? Future<void>.value();
  final done = Completer<void>();
  _settingsWriters[key] = done.future;
  await previous;
  RandomAccessFile? handle;
  final File lockFile = File('$key.lock');
  try {
    await file.parent.create(recursive: true);
    handle = await lockFile.open(mode: FileMode.append);
    // P2-#33: the acquisition deadline is measured with a monotonic
    // Stopwatch, not the wall clock: a system clock rollback during the
    // wait must not stretch the 10-second timeout (a ~1-hour rollback
    // would otherwise extend it to ~1 hour).
    final Stopwatch waitClock = Stopwatch()..start();
    const Duration acquireTimeout = Duration(seconds: 10);
    while (true) {
      try {
        await handle.lock(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (waitClock.elapsed >= acquireTimeout) rethrow;
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
