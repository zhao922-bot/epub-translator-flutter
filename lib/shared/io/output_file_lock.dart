import 'dart:async';
import 'dart:io';

/// Serializes output transactions in this isolate and across app processes.
/// The sidecar must remain on disk: unlinking it would allow a second process
/// to lock a different inode while an existing waiter still owns the old one.
class OutputFileLock {
  static final Map<String, Future<void>> _pending = {};

  static Future<T> run<T>(File output, Future<T> Function() operation) async {
    await output.parent.create(recursive: true);
    final parent = await output.parent.resolveSymbolicLinks();
    final name = output.uri.pathSegments.last;
    final lockFile = File('$parent${Platform.pathSeparator}$name.commit.lock');
    final key = Platform.isWindows
        ? lockFile.path.toLowerCase()
        : lockFile.path;
    final previous = _pending[key];
    final released = Completer<void>();
    _pending[key] = released.future;
    RandomAccessFile? handle;
    try {
      if (previous != null) await previous;
      handle = await lockFile.open(mode: FileMode.append);
      await handle.lock(FileLock.blockingExclusive);
      return await operation();
    } finally {
      // close releases the OS lock even when the transaction throws.
      try {
        await handle?.close();
      } finally {
        released.complete();
        if (identical(_pending[key], released.future)) _pending.remove(key);
      }
    }
  }
}
