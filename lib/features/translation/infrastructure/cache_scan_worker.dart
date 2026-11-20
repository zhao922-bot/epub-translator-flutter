import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../../../shared/io/atomic_file_writer.dart';

/// Persisted metadata for a single cached block entry in `cache_index.json`.
class CacheIndexEntry {
  const CacheIndexEntry({
    required this.modifiedUs,
    required this.size,
    required this.digestHex,
  });

  final int modifiedUs;
  final int size;
  final String digestHex;

  Map<String, Object> toJson() => <String, Object>{
    'm': modifiedUs,
    's': size,
    'd': digestHex,
  };

  static final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  static CacheIndexEntry? fromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? modified = raw['m'];
    final Object? size = raw['s'];
    final Object? digest = raw['d'];
    if (modified is! int || size is! int || digest is! String) return null;
    if (size < 0 || digest.length != 64 || !_sha256Hex.hasMatch(digest)) {
      return null;
    }
    return CacheIndexEntry(modifiedUs: modified, size: size, digestHex: digest);
  }
}

/// Summary metrics for the most recent background cache scan.
class CacheScanStats {
  const CacheScanStats({
    required this.ranInBackgroundIsolate,
    required this.totalEntries,
    required this.indexReusedCount,
    required this.hashedCount,
    required this.sweptTempCount,
  });

  final bool ranInBackgroundIsolate;
  final int totalEntries;
  final int indexReusedCount;
  final int hashedCount;
  final int sweptTempCount;
}

/// File entry discovered by the background cache scanner.
class ScannedCacheEntry {
  const ScannedCacheEntry({
    required this.path,
    required this.relativePath,
    required this.size,
    required this.modifiedUs,
    required this.digestHex,
    required this.reusedFromIndex,
  });

  final String path;
  final String relativePath;
  final int size;
  final int modifiedUs;
  final String? digestHex;
  final bool reusedFromIndex;
}

/// Live (non-stale) atomic temp entry discovered by the background scanner.
class ScannedTempEntry {
  const ScannedTempEntry({
    required this.path,
    required this.size,
    required this.modifiedUs,
  });

  final String path;
  final int size;
  final int modifiedUs;
}

/// Complete snapshot returned from [scanCacheDirectoryInIsolate].
class CacheIsolateScanResult {
  const CacheIsolateScanResult({
    required this.exists,
    required this.entries,
    required this.liveTemps,
    required this.nextIndex,
    required this.indexDirty,
    required this.hadIndexFile,
    required this.stats,
  });

  final bool exists;
  final List<ScannedCacheEntry> entries;
  final Map<String, ScannedTempEntry> liveTemps;
  final Map<String, CacheIndexEntry> nextIndex;
  final bool indexDirty;
  final bool hadIndexFile;
  final CacheScanStats stats;
}

/// Filename of the persistent metadata index stored under the cache root.
const String cacheIndexFileName = 'cache_index.json';
const int _cacheIndexVersion = 1;
const Duration _staleAtomicTempMaxAge = Duration(minutes: 30);

/// Walks [rootPath], sweeps stale `.tmp.*` files across the tree (including
/// `jobs/`), reuses persisted metadata from `cache_index.json` when unchanged,
/// and computes SHA-256 digests in a background isolate.
Future<CacheIsolateScanResult> scanCacheDirectoryInIsolate({
  required String rootPath,
  required Map<String, CacheIndexEntry> memoryBaselines,
  DateTime? now,
}) {
  final int staleCutoffUs = (now ?? DateTime.now())
      .subtract(_staleAtomicTempMaxAge)
      .microsecondsSinceEpoch;
  return Isolate.run(
    () => _scanDirectoryOnWorker(
      rootPath: rootPath,
      staleCutoffUs: staleCutoffUs,
      memoryBaselines: memoryBaselines,
    ),
  );
}

/// Persists (or removes when empty) `cache_index.json` in a background isolate.
Future<void> persistCacheIndexInIsolate({
  required String rootPath,
  required Map<String, CacheIndexEntry> entries,
  required bool hadIndexFile,
}) {
  return Isolate.run(
    () => _persistCacheIndexOnWorker(
      rootPath: rootPath,
      entries: entries,
      hadIndexFile: hadIndexFile,
    ),
  );
}

/// Converts a 64-character lowercase SHA-256 hex string into a [Digest].
Digest digestFromHex(String hex) {
  final Uint8List bytes = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return Digest(bytes);
}

Future<CacheIsolateScanResult> _scanDirectoryOnWorker({
  required String rootPath,
  required int staleCutoffUs,
  required Map<String, CacheIndexEntry> memoryBaselines,
}) async {
  final Directory root = Directory(rootPath);
  if (!await root.exists()) {
    return const CacheIsolateScanResult(
      exists: false,
      entries: <ScannedCacheEntry>[],
      liveTemps: <String, ScannedTempEntry>{},
      nextIndex: <String, CacheIndexEntry>{},
      indexDirty: false,
      hadIndexFile: false,
      stats: CacheScanStats(
        ranInBackgroundIsolate: true,
        totalEntries: 0,
        indexReusedCount: 0,
        hashedCount: 0,
        sweptTempCount: 0,
      ),
    );
  }

  final ({Map<String, CacheIndexEntry> entries, bool hadFile}) loaded =
      await _loadCacheIndexOnWorker(rootPath);
  final List<ScannedCacheEntry> scannedEntries = <ScannedCacheEntry>[];
  final Map<String, ScannedTempEntry> liveTemps = <String, ScannedTempEntry>{};
  final Map<String, CacheIndexEntry> nextIndex = <String, CacheIndexEntry>{};

  int indexReusedCount = 0;
  int hashedCount = 0;
  int sweptTempCount = 0;
  bool indexDirty = false;

  try {
    await for (final FileSystemEntity entity in root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      FileStat stat;
      try {
        stat = await entity.stat();
      } catch (_) {
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue;

      final String relativePath = path
          .relative(entity.path, from: rootPath)
          .replaceAll('\\', '/');
      final int modifiedUs = stat.modified.microsecondsSinceEpoch;
      final String baseName = path.basename(entity.path);

      if (relativePath == cacheIndexFileName) {
        continue;
      }
      if (relativePath.startsWith('$cacheIndexFileName.tmp.')) {
        if (modifiedUs < staleCutoffUs) {
          try {
            await entity.delete();
            sweptTempCount++;
          } catch (_) {
            // Best effort; ignore locked index temps.
          }
        }
        continue;
      }

      if (baseName.contains('.tmp.')) {
        if (modifiedUs < staleCutoffUs) {
          try {
            await entity.delete();
            sweptTempCount++;
            continue;
          } catch (_) {
            // Locked stale temps stay accounted in liveTemps until unlocked.
          }
        }
        liveTemps[entity.path] = ScannedTempEntry(
          path: entity.path,
          size: stat.size,
          modifiedUs: modifiedUs,
        );
        continue;
      }

      if (relativePath == 'jobs' || relativePath.startsWith('jobs/')) {
        continue;
      }

      final CacheIndexEntry? inMemory = memoryBaselines[entity.path];
      String? digestHex;
      bool reusedFromIndex = false;
      int entrySize = stat.size;
      int entryModifiedUs = modifiedUs;

      if (inMemory != null &&
          inMemory.modifiedUs == modifiedUs &&
          inMemory.size == stat.size) {
        digestHex = inMemory.digestHex;
      } else {
        final CacheIndexEntry? indexed = loaded.entries[relativePath];
        // Only trust the on-disk index when the caller had no conflicting
        // in-memory mtime baseline (cold start or synchronized metadata).
        final bool baselineMatchesOrAbsent =
            inMemory == null || inMemory.modifiedUs == modifiedUs;
        if (baselineMatchesOrAbsent &&
            indexed != null &&
            indexed.modifiedUs == modifiedUs &&
            indexed.size == stat.size) {
          digestHex = indexed.digestHex;
          reusedFromIndex = true;
          indexReusedCount++;
        } else {
          final ({String digestHex, int size, int modifiedUs})? computed =
              await _hashFileWithStability(entity, stat);
          if (computed != null) {
            digestHex = computed.digestHex;
            entrySize = computed.size;
            entryModifiedUs = computed.modifiedUs;
            hashedCount++;
          }
        }
      }

      final CacheIndexEntry? prior = loaded.entries[relativePath];
      if (digestHex != null) {
        final CacheIndexEntry record = CacheIndexEntry(
          modifiedUs: entryModifiedUs,
          size: entrySize,
          digestHex: digestHex,
        );
        nextIndex[relativePath] = record;
        if (prior == null ||
            prior.modifiedUs != record.modifiedUs ||
            prior.size != record.size ||
            prior.digestHex != record.digestHex) {
          indexDirty = true;
        }
      } else if (prior != null) {
        // Keep the last verified index entry across transient read failures.
        nextIndex[relativePath] = prior;
      }
      scannedEntries.add(
        ScannedCacheEntry(
          path: entity.path,
          relativePath: relativePath,
          size: entrySize,
          modifiedUs: entryModifiedUs,
          digestHex: digestHex,
          reusedFromIndex: reusedFromIndex,
        ),
      );
    }
  } catch (_) {
    // Missing/vanishing root during scan resolves to partial/empty snapshot.
  }

  if (loaded.entries.length != nextIndex.length) {
    indexDirty = true;
  }

  return CacheIsolateScanResult(
    exists: true,
    entries: scannedEntries,
    liveTemps: liveTemps,
    nextIndex: nextIndex,
    indexDirty: indexDirty,
    hadIndexFile: loaded.hadFile,
    stats: CacheScanStats(
      ranInBackgroundIsolate: true,
      totalEntries: scannedEntries.length,
      indexReusedCount: indexReusedCount,
      hashedCount: hashedCount,
      sweptTempCount: sweptTempCount,
    ),
  );
}

Future<({String digestHex, int size, int modifiedUs})?> _hashFileWithStability(
  File file,
  FileStat initialStat,
) async {
  try {
    FileStat before = initialStat;
    for (int attempt = 0; attempt < 2; attempt++) {
      final Digest digest = await sha256.bind(file.openRead()).first;
      final FileStat after = await file.stat();
      if (after.type != FileSystemEntityType.file) return null;
      if (after.modified == before.modified && after.size == before.size) {
        return (
          digestHex: digest.toString(),
          size: after.size,
          modifiedUs: after.modified.microsecondsSinceEpoch,
        );
      }
      before = after;
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<({Map<String, CacheIndexEntry> entries, bool hadFile})>
_loadCacheIndexOnWorker(String rootPath) async {
  final File file = File(path.join(rootPath, cacheIndexFileName));
  try {
    if (!await file.exists()) {
      return (entries: <String, CacheIndexEntry>{}, hadFile: false);
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<Object?, Object?>) {
      return (entries: <String, CacheIndexEntry>{}, hadFile: true);
    }
    if (decoded['v'] != _cacheIndexVersion) {
      return (entries: <String, CacheIndexEntry>{}, hadFile: true);
    }
    final Object? rawEntries = decoded['entries'];
    if (rawEntries is! Map<Object?, Object?>) {
      return (entries: <String, CacheIndexEntry>{}, hadFile: true);
    }
    final Map<String, CacheIndexEntry> parsed = <String, CacheIndexEntry>{};
    for (final MapEntry<Object?, Object?> entry in rawEntries.entries) {
      if (entry.key is! String) continue;
      final CacheIndexEntry? value = CacheIndexEntry.fromJson(entry.value);
      if (value != null) {
        parsed[entry.key! as String] = value;
      }
    }
    return (entries: parsed, hadFile: true);
  } catch (_) {
    return (entries: <String, CacheIndexEntry>{}, hadFile: false);
  }
}

Future<void> _persistCacheIndexOnWorker({
  required String rootPath,
  required Map<String, CacheIndexEntry> entries,
  required bool hadIndexFile,
}) async {
  final File file = File(path.join(rootPath, cacheIndexFileName));
  try {
    if (entries.isEmpty) {
      if (hadIndexFile && await file.exists()) {
        await file.delete();
      }
      return;
    }
    final Map<String, Object> encodedEntries = <String, Object>{
      for (final MapEntry<String, CacheIndexEntry> entry in entries.entries)
        entry.key: entry.value.toJson(),
    };
    final String payload = jsonEncode(<String, Object>{
      'v': _cacheIndexVersion,
      'entries': encodedEntries,
    });
    await writeFileAtomically(file, payload);
  } catch (_) {
    // Best-effort metadata index: corrupt/locked index is rebuilt next scan.
  }
}
