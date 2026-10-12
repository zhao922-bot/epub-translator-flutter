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
  try {
    await file.parent.create(recursive: true);
    handle = await File('$key.lock').open(mode: FileMode.append);
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
      done.complete();
      if (identical(_settingsWriters[key], done.future)) {
        _settingsWriters.remove(key);
      }
    }
  }
}
