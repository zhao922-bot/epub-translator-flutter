import 'dart:async';
import 'dart:io';

import '../logging/app_logger.dart';

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
    try {
      await handle?.close();
    } finally {
      // Best-effort cleanup of the sidecar lock file: it is only needed
      // while the lock is held, and leaving it behind pollutes the
      // settings directory forever. Deletion must come after close —
      // on Windows deleting an open file fails. A failure (e.g. another
      // process holding the file) is logged, never thrown: releasing the
      // lock must not fail because of cleanup.
      try {
        if (await lockFile.exists()) await lockFile.delete();
      } catch (error) {
        AppLogger.warn(
          'Could not delete settings lock file ${lockFile.path} '
          '($error); leaving it in place.',
          tag: 'settings',
        );
      }
      done.complete();
      if (identical(_settingsWriters[key], done.future)) {
        _settingsWriters.remove(key);
      }
    }
  }
}
