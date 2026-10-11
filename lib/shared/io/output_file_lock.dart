import 'dart:async';
import 'dart:io';

class OutputLockCancelledException implements Exception {
  const OutputLockCancelledException();

  @override
  String toString() => 'Output commit lock wait cancelled';
}

/// Serializes output transactions in this isolate and across app processes.
/// The sidecar must remain on disk: unlinking it would allow a second process
/// to lock a different inode while an existing waiter still owns the old one.
class OutputFileLock {
  static final Map<String, Future<void>> _pending = {};

  static Future<T> run<T>(
    File output,
    Future<T> Function() operation, {
    bool Function()? isCancelled,
    Duration timeout = const Duration(seconds: 45),
    Duration retryInterval = const Duration(milliseconds: 150),
  }) async {
    final clock = Stopwatch()..start();
    void checkWait() {
      if (isCancelled?.call() ?? false) {
        throw const OutputLockCancelledException();
      }
      if (clock.elapsed >= timeout) {
        throw TimeoutException(
          'Timed out waiting for output commit lock: ${output.path}',
          timeout,
        );
      }
    }

    Future<void> pause() => Future<void>.delayed(
      timeout - clock.elapsed < retryInterval
          ? timeout - clock.elapsed
          : retryInterval,
    );
    checkWait();
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
      if (previous != null) {
        var previousReleased = false;
        previous.then((_) => previousReleased = true);
        while (!previousReleased) {
          checkWait();
          await pause();
        }
      }
      checkWait();
      handle = await lockFile.open(mode: FileMode.append);
      while (true) {
        checkWait();
        try {
          await handle.lock(FileLock.exclusive);
          break;
        } on FileSystemException catch (error) {
          // POSIX EAGAIN/EACCES and Windows lock/sharing violations.
          if (!{11, 13, 32, 33, 35}.contains(error.osError?.errorCode)) rethrow;
          await pause();
        }
      }
      checkWait();
      return await operation();
    } finally {
      // close releases the OS lock even when the transaction throws.
      try {
        await handle?.close();
      } finally {
        // A cancelled queued waiter must not let successors overtake its owner.
        void release() {
          released.complete();
          if (identical(_pending[key], released.future)) _pending.remove(key);
        }

        if (previous != null) {
          unawaited(previous.then((_) => release()));
        } else {
          release();
        }
      }
    }
  }
}
