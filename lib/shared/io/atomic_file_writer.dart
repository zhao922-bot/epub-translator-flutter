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
int _tempCounter = 0;

/// Returns the sibling temp path used for an atomic write to [file]. Public
/// so the uniqueness guarantee is directly testable; the `.tmp.` infix keeps
/// the cleanup logic recognizing these files.
String tempPathForAtomicWrite(File file) {
  return '${file.path}.tmp.'
      '${DateTime.now().microsecondsSinceEpoch}_${_tempCounter++}';
}

/// Writes [contents] to [file] atomically.
///
/// The content is first written to a sibling temporary file (with `flush:
/// true`), which is then renamed over [file]. A crash or kill at any point
/// can therefore never leave a truncated [file] behind: readers either see
/// the old content or the new content, never a half-written one.
///
/// Any leftover temporary file from an interrupted write is deleted on a
/// best-effort basis before throwing.
Future<void> writeFileAtomically(File file, String contents) async {
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
/// On Windows, antivirus / file-indexer / OneDrive can hold a brief lock on
/// the target, making the rename throw "Access is denied" (errno 5) even
/// though a retry milliseconds later succeeds. This flaked Windows CI on
/// concurrent writes and can also bite production back-to-back saves, so
/// absorb a few transient failures before giving up.
Future<void> _renameOverTargetWithRetry(File tmp, String targetPath) async {
  const int maxAttempts = 6;
  for (int attempt = 1; ; attempt++) {
    try {
      await tmp.rename(targetPath);
      return;
    } on FileSystemException {
      if (attempt >= maxAttempts) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
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
