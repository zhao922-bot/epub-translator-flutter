import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

/// Leftover `.tmp.*` files are only garbage-collected once they are older
/// than this: the cache store sweeps a directory lazily on its first write
/// there, and the sweep's async listing yields to the event loop, so other
/// in-flight atomic writes in the same directory may still own younger temp
/// files. Deleting by age can never disturb a live write.
const Duration _staleTempAge = Duration(minutes: 30);

/// Process-wide monotonic suffix for atomic temp names. Two concurrent
/// writes to the same target can land in the same microsecond; without a
/// unique suffix they would share one temp path, interleave bytes, and the
/// torn mix would be renamed over the target — silent data corruption.
/// [pid] separates writers in *different processes* (two app instances
/// saving the same history file); the counter separates rapid writes within
/// one process.
int _tempCounter = 0;

/// Returns the sibling temp path used for an atomic write to [file]. Public
/// so the uniqueness guarantee is directly testable; the `.tmp.` infix keeps
/// the cleanup logic recognizing these files.
String tempPathForAtomicWrite(File file) {
  return '${file.path}.tmp.'
      '${DateTime.now().microsecondsSinceEpoch}_${pid}_${_tempCounter++}';
}

/// Writes [contents] to [file] atomically.
///
/// The content is first written to a sibling temporary file (with `flush:
/// true`), which is then renamed over [file]. A crash or kill at any point
/// can therefore never leave a truncated [file] behind: readers either see
/// the old content or the new content, never a half-written one.
///
/// Concurrent writes to the *same* target are serialized through a
/// per-path gate. Hammering one path with concurrent renames keeps the file
/// hot under antivirus/indexer locks on Windows (rename → "Access is
/// denied", errno 5, no matter how long you back off); chaining same-target
/// writes removes that self-inflicted contention. Writes to different paths
/// still run in parallel.
///
/// Any leftover temporary file from an interrupted write is deleted on a
/// best-effort basis before throwing.
Future<void> writeFileAtomically(File file, String contents) {
  final String key = _atomicWriteKey(file);
  final Future<void> previous = _atomicWriteGates[key] ?? Future<void>.value();
  final Completer<void> gate = Completer<void>();
  _atomicWriteGates[key] = gate.future;
  return previous.then((_) async {
    try {
      await _writeFileAtomicallyNow(file, contents);
    } finally {
      gate.complete();
      // Only remove our own gate: a newer write may have chained behind us
      // already, and its gate must stay registered.
      if (identical(_atomicWriteGates[key], gate.future)) {
        _atomicWriteGates.remove(key);
      }
    }
  });
}

/// Chains concurrent writes to the same target path. Gate futures always
/// complete normally (completion happens in `finally`), so a failed write
/// never blocks the writes queued behind it.
final Map<String, Future<void>> _atomicWriteGates = <String, Future<void>>{};

String _atomicWriteKey(File file) {
  final String absolute = File(file.path).absolute.path;
  // Windows paths are case-insensitive: `C:\A\f` and `c:\a\F` are the same
  // file and must share one gate.
  return Platform.isWindows ? absolute.toLowerCase() : absolute;
}

Future<void> _writeFileAtomicallyNow(File file, String contents) async {
  final File tmp = File(tempPathForAtomicWrite(file));
  try {
    await tmp.writeAsString(contents, flush: true);
    await _renameOverTargetWithRetry(tmp, file.path);
  } catch (_) {
    try {
      if (await tmp.exists()) {
        await tmp.delete();
      }
    } catch (_) {
      // Best effort: a stale .tmp file is harmless (readers ignore it).
    }
    rethrow;
  }
}

/// Renames [tmp] over [targetPath], retrying transient failures.
///
/// On Windows, antivirus / file-indexer / OneDrive can hold a lock on the
/// target for a second or more, making the rename throw "Access is denied"
/// (errno 5) even though a retry later succeeds. This flaked Windows CI on
/// concurrent writes and can also bite production back-to-back saves, so
/// absorb transient failures with exponential backoff before giving up.
Future<void> _renameOverTargetWithRetry(File tmp, String targetPath) async {
  const int maxAttempts = 7;
  for (int attempt = 1; ; attempt++) {
    try {
      await tmp.rename(targetPath);
      return;
    } on FileSystemException {
      if (attempt >= maxAttempts) {
        rethrow;
      }
      // 50ms, 100ms, 200ms, ... ~3s total budget.
      await Future<void>.delayed(
        Duration(milliseconds: 50 * (1 << (attempt - 1))),
      );
    }
  }
}

/// Deletes stale `*.tmp.*` files left behind by interrupted atomic writes in
/// [directory]. Pure garbage collection; safe to call lazily. Only files
/// older than [_staleTempAge] are removed, so a sweep racing concurrent
/// writes in the same directory can never delete a live temp file.
Future<void> cleanStaleAtomicTempFiles(Directory directory) async {
  try {
    await for (final FileSystemEntity entity in directory.list()) {
      // Match on the basename only: a parent directory containing ".tmp."
      // (e.g. `/data/.tmp.backup/cache.json`) must not make every file in
      // it eligible for deletion.
      if (entity is File && path.basename(entity.path).contains('.tmp.')) {
        try {
          if (_isStaleTempFile(entity)) {
            await entity.delete();
          }
        } catch (_) {
          // Best effort.
        }
      }
    }
  } catch (_) {
    // Directory may not exist; nothing to clean.
  }
}

/// Reports whether [file] is a leftover temp file old enough to delete. An
/// un-statable file is treated as not stale: it may belong to an in-flight
/// write in another isolate or process.
bool _isStaleTempFile(File file) {
  try {
    final FileStat stat = FileStat.statSync(file.path);
    if (stat.type != FileSystemEntityType.file) {
      return false;
    }
    return DateTime.now().difference(stat.modified) > _staleTempAge;
  } catch (_) {
    return false;
  }
}
