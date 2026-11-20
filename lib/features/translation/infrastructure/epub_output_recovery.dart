import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../shared/io/output_file_lock.dart';
import '../../../shared/logging/app_logger.dart';

/// A `.tmp.*` file counts as a stale orphan only when older than this. The
/// temp file of a live commit is always seconds old; orphans from a dead
/// previous process or session are far older. An age gate (instead of
/// "older than this process started") is robust against filesystem
/// timestamp granularity (FAT32/exFAT: 2s) and clock skew, and also
/// protects the temp files of a second concurrently running app instance.
const Duration _kStaleTempAge = Duration(minutes: 30);

/// Budget for `.recovery.*` spares kept after lock-conflict commits. Every
/// lock conflict preserves one full translated copy; without a cap a stuck
/// lock would fill the disk with a spare per retry. Enforced oldest-first in
/// [preserveRecoveryTempForTest]; a successful commit reclaims all spares
/// for that output (the final file now holds the translation).
const int _kMaxRecoveryFiles = 5;
const int _kMaxRecoveryBytes = 512 * 1024 * 1024;

enum RecoveryBudgetKind { recoverySpare, fallbackTmp, indexLedger }

typedef RecoveryBudgetEntry = ({
  String name,
  int sizeBytes,
  RecoveryBudgetKind kind,
});

/// Decoded archive plus the entry names that occur more than once in the raw
/// central directory. The decoder merges duplicates in place (keeping the
/// first payload but overwriting crc32 with the last duplicate's), so
/// duplicates are invisible when iterating the decoded [Archive] — they must
/// be detected from the decoder's raw file headers instead.

/// Pure eviction policy; the ledger counts toward both limits but sorts last.
/// A complete payload always survives, even when it alone exceeds the budget.
/// The ledger itself survives while any registered `.tmp.*` fallback payload
/// does: it is the orphan sweeper's only record of deliberate recovery
/// copies (P1-#2).
@visibleForTesting
List<String> recoveryBudgetDeletions(
  List<RecoveryBudgetEntry> entries, {
  Set<String> exemptNames = const {},
}) {
  bool isComplete(RecoveryBudgetEntry entry) =>
      entry.kind == RecoveryBudgetKind.fallbackTmp ||
      (entry.kind == RecoveryBudgetKind.recoverySpare &&
          RegExp(r'\.recovery\.\d+$').hasMatch(entry.name));
  final ordered = [...entries]
    ..sort((a, b) {
      final aIsIndex = a.kind == RecoveryBudgetKind.indexLedger;
      final bIsIndex = b.kind == RecoveryBudgetKind.indexLedger;
      if (aIsIndex != bIsIndex) return aIsIndex ? 1 : -1;
      // Compare timestamps across prefixes, rather than sorting all tmp files
      // after all recovery files regardless of age.
      final suffix = RegExp(r'\.(\d+)$');
      final aStamp = int.tryParse(suffix.firstMatch(a.name)?.group(1) ?? '');
      final bStamp = int.tryParse(suffix.firstMatch(b.name)?.group(1) ?? '');
      if (aStamp != null && bStamp != null && aStamp != bStamp) {
        return aStamp.compareTo(bStamp);
      }
      return a.name.compareTo(b.name);
    });
  var remaining = ordered.length;
  var complete = ordered.where(isComplete).length;
  var totalBytes = ordered.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
  final deletions = <String>[];
  for (final entry in ordered) {
    if (remaining <= _kMaxRecoveryFiles && totalBytes <= _kMaxRecoveryBytes) {
      break;
    }
    // P1-#2: the ledger is the orphan sweeper's only record of which `.tmp.*`
    // payloads are deliberate recovery copies. Evicting it while a registered
    // fallback payload survives would let a later process restart sweep the
    // user's only complete translation as a stale orphan (the in-memory
    // _retainedRecoveryPaths do not survive restarts) — this is how v1.6.19's
    // quota cleanup fought the orphan protection. The ledger sorts last, so
    // every fallback payload has been decided by the time it is evaluated:
    // it may only go once no registered fallback payload remains. Recovery
    // spares need no ledger: the orphan sweep never touches `.recovery.*`.
    final bool ledgerStillNeeded =
        entry.kind == RecoveryBudgetKind.indexLedger &&
        ordered.any(
          (other) =>
              other.kind == RecoveryBudgetKind.fallbackTmp &&
              !deletions.contains(other.name),
        );
    if (exemptNames.contains(entry.name) ||
        (isComplete(entry) && complete == 1) ||
        ledgerStillNeeded) {
      continue;
    }
    deletions.add(entry.name);
    remaining--;
    totalBytes -= entry.sizeBytes;
    if (isComplete(entry)) complete--;
  }
  return deletions;
}

/// A commit failed, but the complete translated payload remains recoverable.
///
/// The fully-translated temp file is deliberately NOT deleted: the user can
/// close the locking program and retry the translation (available block cache
/// reduces repeated work), or rename [tempFilePath] manually.
/// [message] is already localized by the caller via [EpubIsolateWorker.commitTempFile]'s
/// `lockedMessage` callback.
class OutputFileRecoveryException extends FileSystemException {
  OutputFileRecoveryException(String message, this.tempFilePath)
    : super(message, tempFilePath);

  final String tempFilePath;

  @override
  String toString() => message;
}

class OutputFileLockedException extends OutputFileRecoveryException {
  OutputFileLockedException(super.message, super.tempFilePath);
}

/// Preserve the established timeout classification while carrying recovery.
class OutputFileRecoveryTimeoutException extends OutputFileRecoveryException
    implements TimeoutException {
  OutputFileRecoveryTimeoutException(
    super.message,
    super.tempFilePath,
    this.duration,
  );

  @override
  final Duration? duration;
}

/// Thrown when the SOURCE file is locked by another process at read time
/// (Windows: a reader holding it open without share access), mirroring
/// [OutputFileLockedException].
///
/// Unlike the output case there is no temp file to preserve: the read never
/// started, and the block cache on disk is unaffected, so closing the locking
/// program and retrying is cheap. Catchers build the user-facing message via
/// `AppStrings.inputFileLocked`.

/// Thrown when a source EPUB trips the zip-bomb guards in
/// [_decodeArchiveWithLimits]: the compressed file itself is implausibly
/// large, the header-declared uncompressed total exceeds the cap, the
/// overall compression ratio is absurd, or the entry count exceeds the cap
/// (millions of near-empty entries). Rejected BEFORE any entry content is
/// materialized, so a malicious archive cannot OOM the isolate.
/// Thrown AGAIN during inflation by [_GuardedInflateStream] when an entry's
/// ACTUAL decompressed bytes exceed the cap: the preflight only sees the
/// header-declared sizes, which a malicious entry can under-report.
/// Catchers build the user-facing message via
/// `AppStrings.epubDecompressionLimit`.

/// Handles atomic output EPUB promotion, Windows sharing-violation lock
/// classification, and `.recovery.*` / backup budget enforcement.
abstract final class EpubOutputRecovery {
  static Future<bool> commitTempFile(
    File tempFile,
    File finalFile, {
    bool Function()? shouldCommit,
    String Function(String outputPath, String tempPath)? lockedMessage,
    Duration lockTimeout = const Duration(seconds: 45),
  }) async {
    try {
      return await OutputFileLock.run(
        finalFile,
        () => commitTempFileLocked(
          tempFile,
          finalFile,
          shouldCommit: shouldCommit,
          lockedMessage: lockedMessage,
        ),
        isCancelled: () => shouldCommit != null && !shouldCommit(),
        timeout: lockTimeout,
      );
    } on OutputLockCancelledException {
      await deleteQuietly(tempFile);
      return false;
    } catch (error) {
      if (error is OutputFileRecoveryException) rethrow;
      final recovery = await preserveRecoveryTemp(tempFile, finalFile);
      if (error is TimeoutException) {
        throw OutputFileRecoveryTimeoutException(
          'Timed out committing output. The translated file was kept at: ${recovery.path}',
          recovery.path,
          error.duration,
        );
      }
      throw OutputFileRecoveryException(
        'Could not commit the output (${error.runtimeType}). '
        'The translated file was kept at: ${recovery.path}',
        recovery.path,
      );
    }
  }

  // Recovery, promotion and rollback are one transaction under the same lock.
  static Future<bool> commitTempFileLocked(
    File tempFile,
    File finalFile, {
    bool Function()? shouldCommit,
    String Function(String outputPath, String tempPath)? lockedMessage,
  }) async {
    bool allowCommit() => shouldCommit == null || shouldCommit();

    await finalFile.parent.create(recursive: true);
    if (!await tempFile.exists()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }
    // A previous process may have died between moving the original aside
    // and promoting the temp file, leaving `.bak.*` files behind.
    await reclaimStaleBackups(finalFile);
    // A previous process may also have died between the isolate returning
    // the temp path and the commit running, leaving `.tmp.*` orphans
    // behind (unlike `.bak.*` files, nothing reclaimed these until now).
    await reclaimStaleTempFiles(finalFile, tempFile);

    try {
      if (!await finalFile.exists()) {
        if (!allowCommit()) {
          await deleteQuietly(tempFile);
          return false;
        }
        await tempFile.rename(finalFile.path);
        // The final file now holds the translation: lock-conflict spares
        // kept for this output are obsolete.
        await reclaimRecoveryFiles(finalFile, committedTempFile: tempFile);
        return true;
      }

      // Dart's File.rename on Windows uses MOVEFILE_REPLACE_EXISTING, so
      // renaming over an existing file works fine; it only throws
      // FileSystemException when the target is locked by another process.
      // Still move final aside first: if promotion fails or commit is refused
      // after the backup move, the backup can be restored instead of losing
      // the original.
      final File backupFile = File(
        '${finalFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}',
      );
      if (!allowCommit()) {
        await deleteQuietly(tempFile);
        return false;
      }
      await finalFile.rename(backupFile.path);
      try {
        if (!allowCommit()) {
          if (await backupFile.exists() && !await finalFile.exists()) {
            await backupFile.rename(finalFile.path);
          }
          await deleteQuietly(tempFile);
          return false;
        }
        await tempFile.rename(finalFile.path);
        // Best effort: the promotion already succeeded; a stuck backup
        // delete must not fail the commit or stall it on retry backoff.
        await deleteBestEffort(backupFile);
        // The final file now holds the translation: lock-conflict spares
        // kept for this output are obsolete.
        await reclaimRecoveryFiles(finalFile, committedTempFile: tempFile);
        return true;
      } catch (error) {
        if (await backupFile.exists() && !await finalFile.exists()) {
          await backupFile.rename(finalFile.path);
        }
        rethrow;
      }
    } on FileSystemException catch (error) {
      if (isFileLockError(error)) {
        // The output file is locked (Windows sharing violation): keep the
        // translated temp file and report a localized message. The user
        // closes the locking program and retries with available cached blocks,
        // or renames the complete temp file manually. Uncached steps may
        // still make API requests.
        final recoveryFile = await preserveRecoveryTemp(tempFile, finalFile);
        throw OutputFileLockedException(
          lockedMessage?.call(finalFile.path, recoveryFile.path) ??
              'The output file is locked by another program: ${finalFile.path}. '
                  'The translated file was kept at: ${recoveryFile.path}',
          recoveryFile.path,
        );
      }
      rethrow;
    } catch (error) {
      rethrow;
    }
  }

  /// True when [error] looks like a Windows file-lock (sharing/lock
  /// violation) rather than a different filesystem failure.
  ///
  /// Shared by the EPUB pipeline and the settings store: a sharing violation
  /// (osError 32/33) can only be produced by a real Windows file lock, so the
  /// classification is tested directly with synthetic exceptions.
  static bool isFileLockError(FileSystemException error) {
    // ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION.
    final int? code = error.osError?.errorCode;
    if (code == 32 || code == 33) {
      return true;
    }
    // Prefer the OS-provided message: Dart's FileSystemException.message
    // embeds the file path, and a file literally named
    // "...being used by another process.epub" must not be misclassified
    // as a lock violation.
    const String lockPhrase = 'being used by another process';
    if ((error.osError?.message ?? '').toLowerCase().contains(lockPhrase)) {
      return true;
    }
    // Fallback for exceptions without OSError details: strip the path
    // before matching so a matching file name can't trigger a false
    // positive. (Single-character paths are test artifacts, not real file
    // paths; stripping those would mangle the message itself.)
    String message = error.message.toLowerCase();
    final String? path = error.path;
    if (path != null && path.length > 1) {
      message = message.replaceAll(path.toLowerCase(), '');
    }
    return message.contains(lockPhrase);
  }

  /// Recovers from a commit that died mid-rename: if the final file is
  /// missing but a `.bak.*` backup survived, the newest backup is restored;
  /// remaining stale backups are deleted. Best effort; never throws.
  static Future<void> reclaimStaleBackups(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.bak.';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? deleteBestEffort;
      final List<File> backups = <File>[];
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is File && path.basename(entity.path).startsWith(prefix)) {
          backups.add(entity);
        }
      }
      if (backups.isEmpty) {
        return;
      }
      // The timestamp suffix sorts chronologically; the newest is last.
      backups.sort((File a, File b) => a.path.compareTo(b.path));
      if (!await finalFile.exists()) {
        final File newest = backups.removeLast();
        try {
          await newest.rename(finalFile.path);
          AppLogger.warn(
            'Restored ${finalFile.path} from stale backup ${newest.path} '
            'left by an interrupted commit.',
            tag: 'repack',
          );
        } catch (_) {
          // Leave the backup file in place if the restore fails: it is the
          // only surviving copy of the user's output. Older stale backups
          // are still safe to delete below.
        }
      }
      for (final File stale in backups) {
        try {
          await deleteFile(stale);
        } catch (_) {
          // Best effort: one stuck file must not block the rest.
        }
      }
    } catch (_) {
      // Best effort: stale backups must never break a commit.
    }
  }

  @visibleForTesting
  static Future<void> reclaimStaleBackupsForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => reclaimStaleBackups(finalFile, deleteForTest: deleteForTest);

  /// Deletes `.tmp.*` orphans left by a previous process that died after
  /// the isolate wrote the temp EPUB but before [commitTempFile] promoted
  /// it. Only files older than [_kStaleTempAge] are touched, and the temp
  /// file this commit is about to promote is always excluded — so a live
  /// commit is protected. Recovery files use a separate `.recovery.*`
  /// prefix and are never swept here: they are count/size-capped in
  /// [preserveRecoveryTempForTest] and reclaimed by [_reclaimRecoveryFiles]
  /// once a later commit succeeds.
  /// Best effort; never throws.
  static Future<void> reclaimStaleTempFiles(
    File finalFile,
    File tempFile, {
    Future<void> Function(File file)? deleteForTest,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.tmp.';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? deleteBestEffort;
      final DateTime cutoff = DateTime.now().subtract(_kStaleTempAge);
      final retained = <String>{..._retainedRecoveryPaths};
      final index = File('${finalFile.path}.recovery-index');
      if (await index.exists()) {
        retained.addAll(
          (await index.readAsLines())
              .where((name) => name.isNotEmpty && path.basename(name) == name)
              .map((name) => path.join(finalFile.parent.path, name)),
        );
      }
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File || !path.basename(entity.path).startsWith(prefix)) {
          continue;
        }
        if (sameFilesystemPath(entity.path, tempFile.path)) {
          continue;
        }
        if (retained.any((name) => sameFilesystemPath(name, entity.path))) {
          continue;
        }
        if ((await entity.lastModified()).isBefore(cutoff)) {
          try {
            await deleteFile(entity);
          } catch (_) {
            // Best effort: one stuck file must not block the rest.
          }
        }
      }
    } catch (_) {
      // Best effort: stale temps must never break a commit.
    }
  }

  static bool sameFilesystemPath(String first, String second, {bool? windows}) {
    if (windows ?? Platform.isWindows) {
      return path.windows
              .normalize(path.windows.absolute(first))
              .toLowerCase() ==
          path.windows.normalize(path.windows.absolute(second)).toLowerCase();
    }
    return path.normalize(path.absolute(first)) ==
        path.normalize(path.absolute(second));
  }

  @visibleForTesting
  static Future<void> reclaimStaleTempFilesForTest(
    File finalFile,
    File tempFile, {
    Future<void> Function(File file)? deleteForTest,
  }) =>
      reclaimStaleTempFiles(finalFile, tempFile, deleteForTest: deleteForTest);

  /// Rename before reporting the path so automatic orphan sweeping cannot
  /// destroy the sole translated copy deliberately retained for recovery.
  static Future<File> preserveRecoveryTemp(
    File tempFile,
    File finalFile,
  ) async {
    try {
      final File recoveryFile = await tempFile.rename(
        '${finalFile.path}.recovery.${DateTime.now().microsecondsSinceEpoch}',
      );
      // A stuck lock would otherwise leave one full translated copy per
      // retry with no bound; enforce the count/size budget oldest-first.
      await enforceRecoveryBudget(finalFile, exemptFile: recoveryFile);
      return recoveryFile;
    } on FileSystemException {
      // Even recovery naming can fail (component length, permissions, locks).
      // Keep the original payload and mark it exempt from orphan sweeping.
      _retainedRecoveryPaths.add(path.absolute(tempFile.path));
      try {
        await File('${finalFile.path}.recovery-index').writeAsString(
          '${path.basename(tempFile.path)}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (error) {
        AppLogger.warn(
          'Could not record recovery path ${tempFile.path}: ${error.runtimeType}',
          tag: 'repack',
        );
      }
      await enforceRecoveryBudget(finalFile, exemptFile: tempFile);
      return tempFile;
    }
  }

  @visibleForTesting
  static Future<File> preserveRecoveryTempForTest(
    File tempFile,
    File finalFile,
  ) => preserveRecoveryTemp(tempFile, finalFile);

  static final Set<String> _retainedRecoveryPaths = {};

  /// Only local, output-specific ledger entries authorize touching tmp files.
  static Future<Set<String>> _indexedRecoveryTemps(File finalFile) async {
    final index = File('${finalFile.path}.recovery-index');
    if (!await index.exists()) return {};
    final prefix = '${path.basename(finalFile.path)}.tmp.';
    return (await index.readAsLines())
        .where((name) => path.basename(name) == name && name.startsWith(prefix))
        .toSet();
  }

  /// Enforces the `.recovery.*` budget for one output: keeps at most
  /// [_kMaxRecoveryFiles] newest entries within [_kMaxRecoveryBytes] total,
  /// deleting oldest-first but retaining the last complete payload. Indexed
  /// tmp payloads and the pinned-last recovery ledger count toward the budget.
  /// Best effort; never throws.
  static Future<void> enforceRecoveryBudget(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? exemptFile,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.recovery.';
      // `<basename>.recovery-index` does not start with
      // `<basename>.recovery.` — match it explicitly.
      final String indexName =
          '${path.basename(finalFile.path)}.recovery-index';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? deleteBestEffort;
      final indexedTemps = await _indexedRecoveryTemps(finalFile);
      final spares = <String, File>{};
      final entries = <RecoveryBudgetEntry>[];
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File) continue;
        final String name = path.basename(entity.path);
        if (!name.startsWith(prefix) &&
            name != indexName &&
            !indexedTemps.contains(name)) {
          continue;
        }
        int size = 0;
        try {
          size = await entity.length();
        } catch (_) {
          // Treat an unreadable spare as empty; it is still count-capped.
        }
        spares[name] = entity;
        entries.add((
          name: name,
          sizeBytes: size,
          kind: name == indexName
              ? RecoveryBudgetKind.indexLedger
              : indexedTemps.contains(name)
              ? RecoveryBudgetKind.fallbackTmp
              : RecoveryBudgetKind.recoverySpare,
        ));
      }
      final exemptNames = {
        for (final entry in spares.entries)
          if (exemptFile != null &&
              sameFilesystemPath(entry.value.path, exemptFile.path))
            entry.key,
      };
      // P2-#15: the ledger is the orphan sweeper's only record of deliberate
      // recovery copies. recoveryBudgetDeletions only knows the PLAN — a
      // stuck file survives a failed delete, so the ledger must be
      // re-evaluated after the payload deletions actually land: it goes
      // only when no registered fallback payload still exists on disk.
      // Delete payloads first, then decide the ledger against reality.
      final Set<String> ledgerNames = <String>{
        for (final entry in entries)
          if (entry.kind == RecoveryBudgetKind.indexLedger) entry.name,
      };
      final List<String> planned = recoveryBudgetDeletions(
        entries,
        exemptNames: exemptNames,
      );
      Future<void> deleteSpare(String name) async {
        final spare = spares[name]!;
        try {
          await deleteFile(spare);
          if (!await spare.exists()) {
            _retainedRecoveryPaths.remove(path.absolute(spare.path));
          }
        } catch (_) {
          // Best effort: one stuck spare must not block the rest.
        }
      }

      for (final name in planned) {
        if (ledgerNames.contains(name)) continue;
        await deleteSpare(name);
      }
      for (final name in planned) {
        if (!ledgerNames.contains(name)) continue;
        bool fallbackSurvives = false;
        for (final entry in entries) {
          if (entry.kind != RecoveryBudgetKind.fallbackTmp) continue;
          final File? payload = spares[entry.name];
          if (payload == null) continue;
          try {
            if (await payload.exists()) {
              fallbackSurvives = true;
              break;
            }
          } catch (_) {
            // An unreadable payload is treated as surviving: keep the
            // ledger rather than risk orphan-sweeping a live recovery copy.
            fallbackSurvives = true;
            break;
          }
        }
        if (fallbackSurvives) continue;
        await deleteSpare(name);
      }
    } catch (_) {
      // Best effort: budget enforcement must never break a commit.
    }
  }

  /// Deletes all `.recovery.*` spares for [finalFile]. Called after a
  /// successful commit: the final file now holds the translation, so the
  /// spares kept for lock-conflict recovery are obsolete. Best effort;
  /// never throws.
  static Future<void> reclaimRecoveryFiles(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? committedTempFile,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.recovery.';
      // `<basename>.recovery-index` does not start with
      // `<basename>.recovery.` — match it explicitly so the ledger is
      // reclaimed together with the spares it describes.
      final String indexName =
          '${path.basename(finalFile.path)}.recovery-index';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? deleteBestEffort;
      final indexedTemps = await _indexedRecoveryTemps(finalFile);
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File) continue;
        final String name = path.basename(entity.path);
        if (committedTempFile != null &&
            sameFilesystemPath(entity.path, committedTempFile.path)) {
          continue;
        }
        if (name.startsWith(prefix) ||
            name == indexName ||
            indexedTemps.contains(name)) {
          try {
            await deleteFile(entity);
            if (!await entity.exists()) {
              _retainedRecoveryPaths.remove(path.absolute(entity.path));
            }
          } catch (_) {
            // Best effort: one stuck file must not block the rest.
          }
        }
      }
    } catch (_) {
      // Best effort: stale spares must never break a commit.
    }
  }

  @visibleForTesting
  static Future<void> enforceRecoveryBudgetForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => enforceRecoveryBudget(finalFile, deleteForTest: deleteForTest);

  @visibleForTesting
  static Future<void> reclaimRecoveryFilesForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? committedTempFile,
  }) => reclaimRecoveryFiles(
    finalFile,
    deleteForTest: deleteForTest,
    committedTempFile: committedTempFile,
  );

  /// Sync helper used by tests that exercise pure filesystem commit logic.
  static void commitTempFileSyncForTest(File tempFile, File finalFile) {
    finalFile.parent.createSync(recursive: true);
    if (!tempFile.existsSync()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }
    if (!finalFile.existsSync()) {
      tempFile.renameSync(finalFile.path);
      return;
    }
    final File backupFile = File(
      '${finalFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      finalFile.renameSync(backupFile.path);
      try {
        tempFile.renameSync(finalFile.path);
        if (backupFile.existsSync()) {
          backupFile.deleteSync();
        }
      } catch (error) {
        if (backupFile.existsSync() && !finalFile.existsSync()) {
          backupFile.renameSync(finalFile.path);
        }
        rethrow;
      }
    } catch (error) {
      // Match production commit semantics: a completed payload is recoverable.
      rethrow;
    }
  }

  /// Reads and decodes the source EPUB in a tight scope so the raw download
  /// buffer has no live local reference once decoding returns.

  /// Single-attempt best-effort delete for sweep/commit paths: stale
  /// backups, stale temps, recovery spares and the post-promotion backup
  /// are obsolete files whose deletion must never stall a commit on retry
  /// backoff. Never throws.
  static Future<void> deleteBestEffort(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  /// Visible for testing.
  @visibleForTesting
  static Future<void> deleteBestEffortForTest(File file) =>
      deleteBestEffort(file);

  /// Retrying delete for the cancel path only: right after the isolate
  /// releases the temp file's handle, Windows may hold a transient lock,
  /// so a single attempt would spuriously fail. Never throws; warns on the
  /// final failed attempt.
  static Future<void> deleteQuietly(File file) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        if (await file.exists()) await file.delete();
        return;
      } catch (error) {
        if (attempt == 4) {
          AppLogger.warn(
            'Could not delete ${file.path}: ${error.runtimeType}',
            tag: 'repack',
          );
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 25 * (1 << attempt)));
      }
    }
  }
}
