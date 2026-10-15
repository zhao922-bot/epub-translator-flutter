import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../../../shared/io/atomic_file_writer.dart';
import '../domain/models/job_resume_state.dart';
import 'epub/epub_xml_characters.dart';

final translationCacheStoreProvider = Provider<TranslationCacheStore>(
  (ref) => TranslationCacheStore(),
);

class TranslationCacheStore {
  TranslationCacheStore({
    Directory? cacheRoot,
    int maxCacheBytes = _maxCacheBytes,
    this.pruneInterval = const Duration(minutes: 5),
    DateTime Function()? now,
    @visibleForTesting this.onMaintenanceScan,
    @visibleForTesting this.resolveCacheRoot,
  }) : _rootOverride = cacheRoot,
       _capacity = maxCacheBytes,
       _now = now ?? DateTime.now;

  final Directory? _rootOverride;
  final int _capacity;
  final Duration pruneInterval;
  final DateTime Function() _now;
  @visibleForTesting
  final Future<void> Function()? onMaintenanceScan;
  @visibleForTesting
  final Future<Directory> Function()? resolveCacheRoot;
  Future<Directory>? _rootFuture;

  /// Parent directories already swept for stale `.tmp.*` files. Atomic
  /// writes can leave orphans if the process is killed between the temp
  /// write and the rename; each directory is swept once per instance,
  /// lazily, on first write there. Only temp files older than 30 minutes
  /// are removed, so a sweep racing concurrent writes in the same directory
  /// can never delete a live temp file (see `cleanStaleAtomicTempFiles`).
  final Set<String> _sweptTempDirs = <String>{};

  /// Upper bound for block translations under `blocks/`. Beyond this, the
  /// oldest block entries are evicted first. Job checkpoints under `jobs/`
  /// are deliberately excluded from this cap: each is a single tiny JSON
  /// file, they are resume-critical (evicting one loses paid progress after
  /// a crash), so they are neither counted toward the total nor ever
  /// evicted (see [pruneCacheDirectoryForTest]).
  static const int _maxCacheBytes = 512 * 1024 * 1024;

  // A full pass establishes/reconciles the disk baseline. Between passes,
  // successful writes update it by byte delta, not by accumulating payloads.
  final Map<String, int> _sizes = <String, int>{};
  final Map<String, DateTime> _mtimes = <String, DateTime>{};
  // Content baselines distinguish a clock/backup timestamp rollback from a
  // same-size external rewrite, even if several files roll back together.
  final Map<String, Digest> _contentDigests = <String, Digest>{};

  /// Perf-#42: digest-check memo for lone rollback entries. A file whose
  /// mtime rolled back but whose content is unchanged can never join a
  /// rollback cohort later; re-hashing it on every maintenance scan is
  /// wasted IO. Remember the (mtime, size, digest) it was last checked at;
  /// a later scan reuses the digest while the file is unchanged instead of
  /// re-reading and re-hashing it.
  final Map<String, _RollbackCheck> _rollbackChecked =
      <String, _RollbackCheck>{};

  /// Block-cache paths in oldest-first eviction order (insertion order).
  /// Writes move their path to the end; a full scan rebuilds it from
  /// on-disk mtimes. Used by the backoff-period quota pass
  /// ([_enforceQuotaLightly]) to evict approximately-LRU without a
  /// directory listing. Job checkpoints are never recorded here: they are
  /// excluded from the cap and must never be evicted.
  final Set<String> _evictionOrder = <String>{};

  final Map<String, Future<void>> _fileGates = <String, Future<void>>{};
  // Checkpoints this instance saved; an external replacement must survive clear.
  final Map<String, FileStat> _savedJobStats = <String, FileStat>{};
  Map<String, int>? _scanChanges;
  int _estimatedBytes = 0;

  /// Temp-file bytes counted by the last full scan (P2-#32). Fresh `.tmp`
  /// files occupy disk but are transient (in-flight writes) or swept when
  /// stale; evicting paid cache entries to make room for them is futile,
  /// and a light pass that does so must not clear the ineffective-scan
  /// backoff — otherwise the backoff flaps and every cycle evicts more
  /// valid cache around the same unreclaimable temps.
  int _lastScanTempBytes = 0;
  DateTime? _lastPrune;
  bool _maintenancePending = false;
  Future<void> _maintenanceTail = Future<void>.value();
  int _writeGeneration = 0;
  int _ineffectivePrunes = 0;

  /// Ineffective-scan backoff deadline. Monotonic (Stopwatch), never wall
  /// clock: a clock rollback must not stretch the wait past its intended
  /// duration.
  final Stopwatch _retryAfterStopwatch = Stopwatch();
  Duration? _retryAfterDelay;

  static const String _envelopePrefix = 'epub-translation-cache-v1:sha256:';

  /// Heuristic for a new-format entry whose corruption hit the envelope
  /// prefix region: the first line still carries a recognizable fragment —
  /// a leading run of the envelope prefix, or the `sha256:` marker.
  /// Translated HTML (what genuine legacy entries contain) never looks like
  /// this, so a match fails closed (caller retranslates) instead of
  /// trusting unchecked bytes. False positives only cost a retranslation.
  static bool _looksLikeDamagedEnvelope(String raw) {
    final int newline = raw.indexOf('\n');
    final String firstLine = newline < 0 ? raw : raw.substring(0, newline);
    // An envelope header line is short (prefix + 64 hex chars); a long
    // first line is HTML payload, not a damaged header.
    if (firstLine.length > _envelopePrefix.length + 80) return false;
    int run = 0;
    final int checkLength = firstLine.length < _envelopePrefix.length
        ? firstLine.length
        : _envelopePrefix.length;
    for (int i = 0; i < checkLength; i++) {
      if (firstLine.codeUnitAt(i) != _envelopePrefix.codeUnitAt(i)) break;
      run++;
    }
    if (run >= 8) return true;
    return firstLine.contains('sha256:');
  }

  @visibleForTesting
  int get estimatedCacheBytesForTest => _estimatedBytes;

  /// P2-#24/perf-#42: the mtime baseline for [path], or null when unknown.
  @visibleForTesting
  DateTime? mtimeBaselineForTest(String path) => _mtimes[path];

  @visibleForTesting
  Future<void> waitForMaintenanceForTest() async {
    Future<void> tail;
    do {
      tail = _maintenanceTail;
      await tail;
    } while (!identical(tail, _maintenanceTail));
  }

  void _resetBackoff() {
    _ineffectivePrunes = 0;
    _retryAfterDelay = null;
    _retryAfterStopwatch.reset();
  }

  /// Clears the backoff only when the last full scan saw no temp pressure
  /// (P2-#32). A light pass that evicts valid entries around persistent
  /// temps must not clear a backoff armed for unreclaimable space —
  /// otherwise the next over-capacity put runs another futile full scan
  /// and the backoff flaps, evicting valid cache each cycle. Only a full
  /// scan (which reconciles temps, updating [_lastScanTempBytes]) or the
  /// backoff's own expiry may clear temp-driven backoff.
  void _resetBackoffIfNoTempPressure() {
    if (_lastScanTempBytes == 0) _resetBackoff();
  }

  /// Clears the ineffective-scan backoff. Tests use fake time for [now] but
  /// the backoff runs on a real (monotonic) Stopwatch, so time-travel cannot
  /// expire it. Call this to simulate "the backoff elapsed and the quota is
  /// now met", as happens in real usage when the estimate is updated.
  @visibleForTesting
  void resetBackoffForTest() => _resetBackoff();

  /// Resets the job-checkpoint prune throttle. The throttle runs on a real
  /// (monotonic) Stopwatch, so fake-time tests cannot expire it by
  /// time-travel. Call this to simulate "the throttle elapsed".
  /// (perf-#53)
  @visibleForTesting
  void resetJobPruneThrottleForTest() {
    _jobPruneStopwatch
      ..stop()
      ..reset();
  }

  bool _backoffActive() {
    final Duration? delay = _retryAfterDelay;
    return delay != null && _retryAfterStopwatch.elapsed < delay;
  }

  // Writes and eviction share a per-file gate; unrelated keys stay parallel.
  // Also serializes checkpoint saves against checkpoint pruning (see
  // [saveJobState] / [pruneJobCheckpointsForTest]).
  Future<T> _withFileGate<T>(File file, Future<T> Function() action) {
    final String key = file.path;
    final Future<void> previous = _fileGates[key] ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _fileGates[key] = gate.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        gate.complete();
        if (identical(_fileGates[key], gate.future)) {
          _fileGates.remove(key);
        }
      }
    });
  }

  void _recordSize(String key, int size, [DateTime? modified]) {
    _estimatedBytes += size - (_sizes[key] ?? 0);
    _sizes[key] = size;
    if (modified != null) _mtimes[key] = modified;
    if (size == 0) {
      _mtimes.remove(key);
      _contentDigests.remove(key);
      _rollbackChecked.remove(key);
    }
    _scanChanges?[key] = size;
    // P2-#32: a light pass evicting valid entries around persistent temps
    // must not clear the backoff (see [_resetBackoffIfNoTempPressure]).
    if (_estimatedBytes <= _capacity) _resetBackoffIfNoTempPressure();
  }

  /// Marks [path] as most-recently written for lightweight eviction order.
  /// (A LinkedHashSet keeps insertion order; remove+add moves to the end.)
  void _noteWriteOrder(String path) {
    _evictionOrder
      ..remove(path)
      ..add(path);
  }

  Future<void> _sweepStaleTempFiles(Directory directory) async {
    if (!_sweptTempDirs.add(directory.path)) {
      return;
    }
    await cleanStaleAtomicTempFiles(directory);
  }

  Future<String?> getBlockTranslation(String cacheKey) async {
    final File file = await _blockCacheFile(cacheKey);
    try {
      final String raw = await file.readAsString();
      if (!raw.startsWith(_envelopePrefix)) {
        // A damaged envelope prefix must NOT be trusted as a legacy entry:
        // legacy entries carry no checksum, so a corrupted new-format entry
        // would silently return unchecked bytes (and the restoration
        // scanner would count it as a hit). Fail closed: null triggers a
        // retranslation.
        if (_looksLikeDamagedEnvelope(raw)) return null;
        // Legacy entries have no checksum. Trust them to preserve paid
        // progress; all new writes use the versioned integrity envelope.
        validateEpubXmlMarkup(raw);
        return raw;
      }
      final int newline = raw.indexOf('\n');
      if (newline < 0) return null;
      final String digest = raw.substring(_envelopePrefix.length, newline);
      final String payload = raw.substring(newline + 1);
      if (sha256.convert(utf8.encode(payload)).toString() != digest) {
        return null;
      }
      validateEpubXmlMarkup(payload);
      return payload;
    } on FileSystemException catch (error) {
      // ENOENT on POSIX; ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND on
      // Windows. Other failures remain unreadable-cache errors to callers.
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) return null;
      rethrow;
    }
  }

  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    final File file = await _blockCacheFile(cacheKey);
    await file.parent.create(recursive: true);
    await _sweepStaleTempFiles(file.parent);
    // Write to a temp file and rename: a kill mid-write must never leave a
    // truncated half-written cache entry behind, otherwise resume would
    // silently treat torn HTML as a valid cached translation.
    // `writeFileAtomically` gives each concurrent write a unique temp path,
    // so parallel writes to the same key cannot interleave into torn HTML.
    await _withFileGate(file, () async {
      if (!_sizes.containsKey(file.path)) {
        final FileStat stat = await file.stat();
        _recordSize(
          file.path,
          stat.type == FileSystemEntityType.file ? stat.size : 0,
          stat.modified,
        );
      }
      final String envelope =
          '$_envelopePrefix'
          '${sha256.convert(utf8.encode(translatedHtml))}\n$translatedHtml';
      await writeFileAtomically(file, envelope);
      final FileStat written = await file.stat();
      _writeGeneration++;
      _recordSize(file.path, utf8.encode(envelope).length, written.modified);
      _contentDigests[file.path] = sha256.convert(utf8.encode(envelope));
      _noteWriteOrder(file.path);
    });
    _pruneIfNeeded();
  }

  /// Minimum interval between backoff-period lightweight quota passes
  /// (P2-#29). Without it, every put while over capacity during the backoff
  /// would trigger a pass, and the follow-up chain below would keep them
  /// spinning.
  static const Duration _lightPruneThrottle = Duration(minutes: 1);
  DateTime? _lastLightPrune;

  /// Schedules an initial baseline scan, then maintenance on writes when the
  /// time interval expires or estimated capacity is exceeded. Pending requests
  /// are coalesced; failures cannot break a translation run.
  ///
  /// Tests can set [suspendAutoMaintenanceForTest] to build a fixture without
  /// background maintenance interfering (P2-#29 made the light pass run
  /// during the backoff, so "arm backoff without eviction" fixtures need an
  /// explicit suspension).
  @visibleForTesting
  bool suspendAutoMaintenanceForTest = false;

  void _pruneIfNeeded({bool capacityFollowUp = false}) {
    if (suspendAutoMaintenanceForTest) return;
    final DateTime now = _now();
    // P2-#32: see [_resetBackoffIfNoTempPressure] — a temp-driven backoff
    // survives transient under-capacity until a full scan reconciles.
    if (_estimatedBytes <= _capacity) _resetBackoffIfNoTempPressure();
    if (_maintenancePending) {
      return;
    }
    final bool overCapacity = _estimatedBytes > _capacity;
    final bool intervalActive =
        _lastPrune != null && now.difference(_lastPrune!) < pruneInterval;
    final bool backoffActive = _backoffActive();
    // Over capacity while the ineffective-scan backoff is armed: the full
    // scan was proven unable to reclaim space (its targets are locked or
    // otherwise unreclaimable), so walking the whole tree again would only
    // burn IO every interval.
    //
    // P2-#29: the backoff skips the full scan, but a put that finds the
    // cache over capacity still runs the lightweight quota pass — the old
    // `intervalActive && backoffActive` early return let the cache grow
    // without bound for the whole backoff. The follow-up chain
    // (capacityFollowUp) stays gated so an unreclaimable cache cannot spin
    // light passes in a loop; future puts re-trigger it, throttled below.
    // An over-capacity put with no backoff still scans promptly.
    final bool lightOnly = overCapacity && backoffActive;
    if (!overCapacity && backoffActive) {
      return;
    }
    if (intervalActive &&
        (!overCapacity || (backoffActive && capacityFollowUp))) {
      return;
    }
    if (lightOnly) {
      final DateTime? lastLight = _lastLightPrune;
      if (lastLight != null &&
          now.difference(lastLight) < _lightPruneThrottle) {
        return;
      }
      _lastLightPrune = now;
    }
    _maintenancePending = true;
    _lastPrune = now;
    // Start on a separate event turn, and never join this future from put.
    _maintenanceTail = _maintenanceTail.then(
      (_) => Future<void>(() async {
        final int generation = _writeGeneration;
        bool scanned = false;
        try {
          if (lightOnly) {
            lightPruneCountForTest++;
            await _enforceQuotaLightly();
          } else {
            await _scanAndPrune(await _cacheRoot(), _capacity);
            scanned = true;
          }
        } catch (_) {
          // Cache maintenance must never break translation.
        } finally {
          // P2-#29: only reset the backoff when the quota is actually met.
          // A light pass that deletes bytes but leaves the cache over
          // capacity (unreclaimable files remain) must not clear the
          // backoff, or the follow-up would schedule a full scan on every
          // put, defeating the backoff (C-15).
          // P2-#32: a full scan reconciles temps, so its under-capacity
          // verdict is trustworthy and clears unconditionally; a light
          // pass must not clear temp-driven backoff (its evictions merely
          // work around persistent temps).
          if (_estimatedBytes <= _capacity) {
            if (scanned) {
              _resetBackoff();
            } else {
              _resetBackoffIfNoTempPressure();
            }
          } else if (!scanned ||
              generation == _writeGeneration ||
              capacityFollowUp) {
            // No reclaimable space (or a failed pass): don't rescan on every
            // put. Concurrent writes get one immediate follow-up pass first,
            // but cannot keep no-effect scans spinning indefinitely.
            // Monotonic clock: a wall-clock rollback must not stretch the
            // wait.
            _ineffectivePrunes++;
            final int minutes = _ineffectivePrunes >= 5
                ? 60
                : 5 * (1 << (_ineffectivePrunes - 1));
            _retryAfterDelay = Duration(minutes: minutes);
            _retryAfterStopwatch
              ..reset()
              ..start();
          }
          _maintenancePending = false;
          // A follow-up pass goes through [_pruneIfNeeded]'s guard: an
          // ineffective pass that armed the backoff is stopped there, while
          // an effective (or inconclusive) pass chains promptly to keep
          // evicting.
          if (_estimatedBytes > _capacity) {
            _pruneIfNeeded(capacityFollowUp: true);
          }
        }
      }),
    );
  }

  /// Enforces the capacity quota without a directory listing, for use while
  /// the ineffective-scan backoff is armed (see [_pruneIfNeeded]). Evicts
  /// the oldest in-memory-known block entries down to 90% of the cap —
  /// the same target the full scan uses — under the per-file gate shared
  /// with writers, so a concurrent put can never lose a just-written
  /// entry: the stat recheck skips files that changed since they were
  /// recorded, leaving those for the next full scan to reconcile. Returns
  /// the reclaimed bytes. Job checkpoints are never in [_sizes], so they
  /// are never touched here.
  @visibleForTesting
  Future<int> enforceQuotaLightlyForTest() => _enforceQuotaLightly();

  /// Number of backoff-period lightweight quota passes executed (P2-#29).
  /// Lets tests assert that over-capacity puts during the backoff still
  /// enforce the quota via the light pass instead of stalling.
  @visibleForTesting
  int lightPruneCountForTest = 0;

  Future<int> _enforceQuotaLightly() async {
    final int targetBytes = (_capacity * 0.9).toInt();
    int deletedBytes = 0;
    // P2-#32: drive the light pass by valid bytes only. Temp files counted
    // by the last full scan are transient (in-flight writes) or swept when
    // stale; evicting paid cache entries to make room for them is futile,
    // so they must not inflate the eviction target.
    bool overTarget() => _estimatedBytes - _lastScanTempBytes > targetBytes;
    for (final String filePath in _evictionOrder.toList()) {
      if (!overTarget()) break;
      final int? recorded = _sizes[filePath];
      if (recorded == null || recorded <= 0) {
        _evictionOrder.remove(filePath);
        continue;
      }
      final File file = File(filePath);
      try {
        await _withFileGate(file, () async {
          if (!overTarget()) return;
          final FileStat current = await file.stat();
          // Changed since recorded (rewritten, or touched externally): the
          // recorded size is stale, so leave it for a full scan.
          if (current.type != FileSystemEntityType.file ||
              current.size != recorded) {
            return;
          }
          final DateTime? recordedModified = _mtimes[filePath];
          if (recordedModified == null ||
              current.modified != recordedModified) {
            return;
          }
          await file.delete();
          deletedBytes += recorded;
          _evictionOrder.remove(filePath);
          _recordSize(filePath, 0);
        });
      } catch (_) {
        // Best effort; a locked file is left for the next pass.
      }
    }
    return deletedBytes;
  }

  /// Scans [root] and evicts the oldest entries under `blocks/` until the
  /// total is back under [maxBytes] (default [_maxCacheBytes]).
  ///
  /// Job checkpoints under `jobs/` are never evicted and their bytes are
  /// not counted: they are tiny, and losing one to eviction would discard
  /// already-paid translation progress after a process crash. Leftover
  /// `.tmp.*` files count toward the cap (they occupy real disk space) but
  /// are never evicted here: they may belong to an in-flight write in
  /// another isolate or process. Stale ones are removed before accounting.
  Future<void> pruneCacheDirectoryForTest(
    Directory root, {
    int maxBytes = _maxCacheBytes,
  }) {
    final Future<void> pass = _maintenanceTail.then((_) async {
      await _scanAndPrune(root, maxBytes);
    });
    _maintenanceTail = pass.catchError((Object _) {});
    return pass;
  }

  Future<int> _scanAndPrune(Directory root, int maxBytes) async {
    final Map<String, int> changes = <String, int>{};
    _scanChanges = changes;
    try {
      if (!await root.exists()) return 0;
      // Sweep every shard, including ones no longer receiving writes. Do not
      // memoize this maintenance pass: a previously fresh orphan can age out.
      await cleanStaleAtomicTempFiles(root);
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Directory) {
          await cleanStaleAtomicTempFiles(entity);
        }
      }
      final List<_CacheEntry> entries = <_CacheEntry>[];
      final Map<String, int> scannedSizes = <String, int>{};
      final Map<String, FileStat> temps = <String, FileStat>{};
      int deletedBytes = 0;
      await for (final FileSystemEntity entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final String relative = path.relative(entity.path, from: root.path);
        if (relative == 'jobs' ||
            relative.startsWith('jobs${path.separator}')) {
          continue;
        }
        final bool isAtomicTemp = path.basename(entity.path).contains('.tmp.');
        try {
          final FileStat stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          // Fresh temps count toward the cap but cannot be evicted: they may
          // belong to another live writer. Stale ones were swept above.
          if (isAtomicTemp) {
            temps[entity.path] = stat;
          } else {
            scannedSizes[entity.path] = stat.size;
            entries.add(
              _CacheEntry(
                file: entity,
                size: stat.size,
                modified: stat.modified,
              ),
            );
          }
        } catch (_) {
          // A file that vanishes mid-scan is simply skipped.
        }
      }
      await onMaintenanceScan?.call();
      // Reconcile the temporary paths, not just their original byte sum. A
      // rename may have promoted a listed temp during this scan, including in
      // another store/process. Size+mtime identifies that promotion. This
      // synchronous reconciliation and the overlay below cannot interleave
      // with this isolate's completed-write accounting.
      int reconcileTemps() {
        int bytes = 0;
        for (final temp in temps.entries) {
          final FileStat current = FileStat.statSync(temp.key);
          if (current.type == FileSystemEntityType.file) {
            bytes += current.size;
          } else {
            final String target = temp.key.substring(
              0,
              temp.key.lastIndexOf('.tmp.'),
            );
            final FileStat promoted = FileStat.statSync(target);
            if (promoted.type == FileSystemEntityType.file &&
                promoted.size == temp.value.size &&
                promoted.modified == temp.value.modified &&
                !changes.containsKey(target)) {
              scannedSizes[target] = promoted.size;
              _mtimes[target] = promoted.modified;
            }
          }
        }
        return bytes;
      }

      int tempBytes = reconcileTemps();
      // Overlay writes completed during listing, including newly created keys.
      scannedSizes.addAll(changes);
      int totalBytes = tempBytes + scannedSizes.values.fold(0, (a, b) => a + b);
      if (totalBytes > maxBytes) {
        entries.sort(
          (_CacheEntry a, _CacheEntry b) => a.modified.compareTo(b.modified),
        );
        final int targetBytes = (maxBytes * 0.9).toInt();
        for (final _CacheEntry entry in entries) {
          if (totalBytes - tempBytes <= targetBytes) break;
          try {
            await _withFileGate(entry.file, () async {
              // Never delete a replacement written since this scan began.
              if (changes.containsKey(entry.file.path)) return;
              final FileStat current = await entry.file.stat();
              if (current.type != FileSystemEntityType.file ||
                  current.size != entry.size ||
                  current.modified != entry.modified) {
                return;
              }
              await entry.file.delete();
              totalBytes -= entry.size;
              deletedBytes += entry.size;
              _recordSize(entry.file.path, 0);
            });
          } catch (_) {
            // Best effort; a locked file is left for the next pass.
          }
        }
      }
      tempBytes = reconcileTemps();
      scannedSizes.addAll(changes);
      scannedSizes.removeWhere((_, size) => size == 0);
      // Only unchanged contents with a shared backward offset form a clock
      // event. A lone rollback (or a real rewrite) stays fail-closed. Read
      // contents only to establish a baseline or reconcile changed mtimes.
      final Map<Duration, List<_CacheEntry>> rollbacks = {};
      // P2-#24: keys whose digest could not be read during this scan. Their
      // mtime baseline must not advance below: that would pair the new
      // mtime with a stale digest, a permanently wrong baseline that later
      // scans would never re-hash (the "unchanged" early-continue above).
      final Set<String> digestReadFailed = <String>{};
      for (final _CacheEntry entry in entries) {
        final String key = entry.file.path;
        if (!scannedSizes.containsKey(key) || changes.containsKey(key)) {
          continue;
        }
        final DateTime? known = _mtimes[key];
        if (known == entry.modified && _contentDigests.containsKey(key)) {
          continue;
        }
        try {
          await _withFileGate(entry.file, () async {
            if (changes.containsKey(key)) return;
            final _RollbackCheck? checked = _rollbackChecked[key];
            final Digest digest;
            if (checked != null &&
                checked.modified == entry.modified &&
                checked.size == entry.size) {
              // P2-#31: (mtime, size) alone cannot prove the content is
              // unchanged — an external rewrite with the same size and a
              // preserved mtime would reuse a stale digest and corrupt
              // rollback detection. Verify by re-hashing and comparing
              // with the memoized digest; on mismatch the content really
              // changed, so refresh the memo with the fresh digest.
              final FileStat current = await entry.file.stat();
              if (current.type != FileSystemEntityType.file ||
                  current.size != entry.size ||
                  current.modified != entry.modified) {
                return;
              }
              final Digest fresh = await sha256
                  .bind(entry.file.openRead())
                  .first;
              final FileStat after = await entry.file.stat();
              if (after.type != FileSystemEntityType.file ||
                  after.size != entry.size ||
                  after.modified != entry.modified) {
                return;
              }
              if (fresh != checked.digest) {
                _rollbackChecked[key] = _RollbackCheck(
                  modified: entry.modified,
                  size: entry.size,
                  digest: fresh,
                );
              }
              digest = fresh;
            } else {
              digest = await sha256.bind(entry.file.openRead()).first;
              final FileStat current = await entry.file.stat();
              if (current.type != FileSystemEntityType.file ||
                  current.size != entry.size ||
                  current.modified != entry.modified) {
                return;
              }
              // Memoize this (mtime, size, digest): a later scan with an
              // unchanged file reuses it instead of hashing again.
              _rollbackChecked[key] = _RollbackCheck(
                modified: entry.modified,
                size: entry.size,
                digest: digest,
              );
            }
            if (known != null && entry.modified.isBefore(known)) {
              if (_sizes[key] == entry.size && _contentDigests[key] == digest) {
                rollbacks
                    .putIfAbsent(known.difference(entry.modified), () => [])
                    .add(entry);
              }
            } else {
              _contentDigests[key] = digest;
            }
          });
        } catch (_) {
          // Unreadable or concurrently replaced entries cannot prove rollback.
          digestReadFailed.add(key);
        }
      }
      final Set<String> clockRollbackPaths = {
        for (final cohort in rollbacks.values)
          if (cohort
                  .where((entry) => !changes.containsKey(entry.file.path))
                  .length >=
              2)
            for (final entry in cohort) entry.file.path,
      };
      // Digest reads yield: overlay writes completed during reconciliation too.
      tempBytes = reconcileTemps();
      scannedSizes.addAll(changes);
      scannedSizes.removeWhere((_, size) => size == 0);
      _sizes
        ..clear()
        ..addAll(scannedSizes);
      _mtimes.removeWhere(
        (String path, DateTime _) => !scannedSizes.containsKey(path),
      );
      _contentDigests.removeWhere((key, _) => !scannedSizes.containsKey(key));
      _rollbackChecked.removeWhere((key, _) => !scannedSizes.containsKey(key));
      for (final _CacheEntry entry in entries) {
        if (!scannedSizes.containsKey(entry.file.path)) continue;
        if (changes.containsKey(entry.file.path)) continue;
        // P2-#24: a failed digest read leaves the old digest behind; the
        // mtime baseline must not advance past it.
        if (digestReadFailed.contains(entry.file.path)) continue;
        final DateTime? known = _mtimes[entry.file.path];
        if (known == null ||
            entry.modified.isAfter(known) ||
            clockRollbackPaths.contains(entry.file.path)) {
          _mtimes[entry.file.path] = entry.modified;
        }
      }
      _estimatedBytes = tempBytes + _sizes.values.fold(0, (a, b) => a + b);
      // P2-#32: remember the temp pressure this scan saw, so the light
      // pass can exclude it from its eviction target and so temp-driven
      // backoff is not cleared by light-pass evictions.
      _lastScanTempBytes = tempBytes;
      // Rebuild the lightweight-eviction order from on-disk mtimes (oldest
      // first) so the backoff-period quota pass evicts approximately LRU
      // without another full scan.
      final List<String> byAge = scannedSizes.keys.toList()
        ..sort(
          (String a, String b) => (_mtimes[a] ?? DateTime(1970)).compareTo(
            _mtimes[b] ?? DateTime(1970),
          ),
        );
      _evictionOrder
        ..clear()
        ..addAll(byAge);
      return deletedBytes;
    } finally {
      _scanChanges = null;
    }
  }

  Future<JobResumeState?> loadJobState(String jobKey) async {
    final File file = await _jobStateFile(jobKey);
    if (!await file.exists()) {
      return null;
    }
    final String raw = await file.readAsString();
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return JobResumeState.fromJson(decoded);
  }

  Future<void> saveJobState(JobResumeState state) async {
    final File file = await _jobStateFile(state.jobKey);
    await file.parent.create(recursive: true);
    await _sweepStaleTempFiles(file.parent);
    // Serialize with checkpoint pruning on the per-file gate: without it,
    // the prune's stat-then-delete could land after a concurrent save
    // renamed a fresh checkpoint onto this same path, deleting live state.
    await _withFileGate(file, () async {
      await writeFileAtomically(
        file,
        const JsonEncoder.withIndent('  ').convert(state.toJson()),
      );
      _savedJobStats[file.path] = await file.stat();
    });
    await _pruneOldJobStates();
  }

  /// Content-addressed history chunks are immutable. Publish the small head
  /// only after its new chunk is durable, under the checkpoint/pruning gate.
  Future<void> saveMemoryCheckpoint(
    JobResumeState state, {
    String? chunkHash,
    String? chunk,
  }) async {
    final file = await _jobStateFile(state.jobKey);
    await file.parent.create(recursive: true);
    await _withFileGate(file, () async {
      if (chunkHash != null && chunk != null) {
        if (sha256.convert(utf8.encode(chunk)).toString() != chunkHash) {
          throw const FormatException('Memory chunk checksum mismatch.');
        }
        final chunkFile = File(
          path.join('${file.path}.history', '$chunkHash.json'),
        );
        await chunkFile.parent.create(recursive: true);
        await writeFileAtomically(chunkFile, chunk);
      }
      await writeFileAtomically(file, jsonEncode(state.toJson()));
      _savedJobStats[file.path] = await file.stat();
    });
    await _pruneOldJobStates();
  }

  Future<Map<String, dynamic>> readMemoryChunk(String key, String hash) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid memory chunk identity.');
    }
    final head = await _jobStateFile(key);
    final raw = await File(
      path.join('${head.path}.history', '$hash.json'),
    ).readAsString();
    if (sha256.convert(utf8.encode(raw)).toString() != hash) {
      throw const FormatException('Damaged memory history chunk.');
    }
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _removeMemoryHistory(File head) async {
    final directory = Directory('${head.path}.history');
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      /* Best effort; preserve checkpoint maintenance semantics. */
    }
  }

  /// Maximum retained per-job checkpoints, aligned with the 20-entry job
  /// history cap: a checkpoint whose job has scrolled out of history can no
  /// longer be resumed through the UI, so keeping more would let `jobs/`
  /// grow without bound.
  static const int _maxJobCheckpoints = 20;

  /// Minimum interval between job-checkpoint prune scans (perf-#43).
  /// [saveJobState] runs on every block save during a translation run;
  /// scanning the jobs directory on every save is O(S×N) for S saves and N
  /// files. Pruning only removes checkpoints idle for 5+ minutes, so
  /// scanning more than once a minute cannot free anything new.
  static const Duration _jobPruneThrottle = Duration(minutes: 1);

  /// Monotonic throttle clock for [_pruneOldJobStates] (perf-#53). The wall
  /// clock must not gate this: a clock rollback would stall pruning until
  /// the clock catches up.
  final Stopwatch _jobPruneStopwatch = Stopwatch();

  /// Deletes the oldest checkpoints beyond [_maxJobCheckpoints]. Best
  /// effort: checkpoint maintenance must never break a translation run. All
  /// recently active checkpoints (including the one just saved) are protected
  /// for five minutes, even when this temporarily exceeds the count cap.
  Future<void> _pruneOldJobStates() async {
    if (_jobPruneStopwatch.isRunning &&
        _jobPruneStopwatch.elapsed < _jobPruneThrottle) {
      return;
    }
    _jobPruneStopwatch
      ..reset()
      ..start();
    try {
      final Directory root = await _cacheRoot();
      await pruneJobCheckpointsForTest(
        Directory(path.join(root.path, 'jobs')),
        maxCheckpoints: _maxJobCheckpoints,
      );
    } catch (_) {
      // Best effort; a locked file is left for the next pass.
    }
  }

  /// Deletes the oldest checkpoints in [jobsDir] beyond [maxCheckpoints]
  /// (oldest first by modification time).
  ///
  /// P2-#28: [maxCheckpoints] counts tasks, not files. A job's main
  /// checkpoint and its book-memory companion are one task; counting files
  /// would prune 20 two-file jobs down to ~10 pairs.
  @visibleForTesting
  Future<void> pruneJobCheckpointsForTest(
    Directory jobsDir, {
    int maxCheckpoints = _maxJobCheckpoints,
    Future<void> Function()? onListedForTest,
  }) async {
    if (!await jobsDir.exists()) {
      return;
    }
    final List<({File file, DateTime modified})> entries =
        <({File file, DateTime modified})>[];
    await for (final FileSystemEntity entity in jobsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        entries.add((file: entity, modified: (await entity.stat()).modified));
      } catch (_) {
        // A file that vanishes mid-scan is simply skipped.
      }
    }
    // Group files into tasks: a main checkpoint stem is its job key, and a
    // book-memory file's name derives from it
    // (`sha256("$stem:book-memory")`, mirroring [_pairedCheckpointPath]),
    // so both land in the same group without reading file contents.
    // Orphans (a memory file whose main is gone) form singleton groups.
    final Map<String, String> memoryNameToJobKey = <String, String>{};
    for (final entry in entries) {
      final String stem = path.basenameWithoutExtension(entry.file.path);
      memoryNameToJobKey[sha256
              .convert(utf8.encode('$stem:book-memory'))
              .toString()] =
          stem;
    }
    final Map<String, List<({File file, DateTime modified})>> groups =
        <String, List<({File file, DateTime modified})>>{};
    for (final entry in entries) {
      final String stem = path.basenameWithoutExtension(entry.file.path);
      final String groupKey = memoryNameToJobKey[stem] ?? stem;
      (groups[groupKey] ??= <({File file, DateTime modified})>[]).add(entry);
    }
    if (groups.length <= maxCheckpoints) {
      return;
    }
    final Map<String, DateTime> listedModified = {
      for (final entry in entries) entry.file.path: entry.modified,
    };
    // Oldest tasks first; a task is as recent as its freshest file.
    final List<List<({File file, DateTime modified})>> tasks =
        groups.values.toList()..sort(
          (
            List<({File file, DateTime modified})> a,
            List<({File file, DateTime modified})> b,
          ) => _newestModified(a).compareTo(_newestModified(b)),
        );
    int remaining = tasks.length;
    final DateTime activeSince = _now().subtract(const Duration(minutes: 5));
    final List<({File file, DateTime modified})> candidates = [];
    for (final task in tasks) {
      if (remaining <= maxCheckpoints) break;
      remaining--;
      for (final entry in task) {
        if (!entry.modified.isBefore(activeSince)) continue;
        candidates.add(entry);
      }
    }
    // Pair protection: a job checkpoint and its book-memory companion are
    // kept or deleted together, never split. An active job must not lose
    // only its memory file while its main checkpoint survives.
    final Set<String> candidatePaths = {
      for (final entry in candidates) entry.file.path,
    };
    for (final entry in candidates) {
      final String? matePath = await _pairedCheckpointPath(jobsDir, entry.file);
      if (matePath == null ||
          candidatePaths.contains(matePath) ||
          !await File(matePath).exists()) {
        continue;
      }
      candidatePaths.remove(entry.file.path);
    }
    await onListedForTest?.call();
    // P2-#27: delete checkpoint pairs atomically. The two members used to
    // be deleted under separate per-file gates: a concurrent save
    // refreshing the second member between the two deletions made its
    // mtime recheck fail, leaving a broken half-pair. Members whose mate
    // is also a candidate are now deleted together under both gates
    // (acquired in path order so concurrent prunes cannot deadlock); a
    // refresh of either member aborts the whole pair deletion.
    final Set<String> pairHandled = <String>{};
    for (final entry in candidates) {
      final String entryPath = entry.file.path;
      if (!candidatePaths.contains(entryPath) || !pairHandled.add(entryPath)) {
        continue;
      }
      try {
        final String? matePath = await _pairedCheckpointPath(
          jobsDir,
          entry.file,
        );
        final DateTime? mateListedModified = matePath == null
            ? null
            : listedModified[matePath];
        final bool pairDelete =
            matePath != null &&
            mateListedModified != null &&
            candidatePaths.contains(matePath) &&
            pairHandled.add(matePath);
        if (pairDelete) {
          if (await _deleteCheckpointPair(
            entry.file,
            entry.modified,
            File(matePath),
            mateListedModified,
            activeSince,
          )) {
            // A mate removed by this pass is expected to be absent; an
            // externally vanished or refreshed mate must still block
            // deletion (handled inside the pair delete's recheck).
            listedModified.remove(entryPath);
            listedModified.remove(matePath);
          }
        } else {
          // Recheck under the per-file gate shared with [saveJobState]: a
          // resume/save that refreshed this path after the listing must not
          // have its fresh checkpoint deleted by this pass. The gate makes
          // the recheck stat and the delete atomic with respect to saves.
          final bool deleted = await _withFileGate(entry.file, () async {
            final FileStat current = await entry.file.stat();
            if (current.modified != entry.modified ||
                !current.modified.isBefore(activeSince)) {
              return false;
            }
            final String? matePath = await _pairedCheckpointPath(
              jobsDir,
              entry.file,
            );
            if (matePath != null) {
              final DateTime? listedMateModified = listedModified[matePath];
              final File mateFile = File(matePath);
              if (await mateFile.exists()) {
                final DateTime mateModified = (await mateFile.stat()).modified;
                if (listedMateModified == null ||
                    mateModified != listedMateModified) {
                  return false;
                }
              } else if (listedMateModified != null) {
                return false;
              }
            }
            await entry.file.delete();
            await _removeMemoryHistory(entry.file);
            return true;
          });
          if (deleted) {
            // A mate removed by this pass is expected to be absent; an
            // externally vanished or refreshed mate must still block
            // deletion.
            listedModified.remove(entryPath);
          }
        }
      } catch (_) {
        // Best effort; a locked file is left for the next pass.
      }
    }
  }

  /// Newest modification time in a checkpoint task group.
  static DateTime _newestModified(List<({File file, DateTime modified})> task) {
    DateTime newest = task.first.modified;
    for (final entry in task.skip(1)) {
      if (entry.modified.isAfter(newest)) newest = entry.modified;
    }
    return newest;
  }

  /// Deletes both members of a checkpoint pair atomically (P2-#27). Both
  /// per-file gates are held — acquired in path order so two concurrent
  /// prunes cannot deadlock — then both mtimes are re-verified and only
  /// then are both files deleted. A concurrent save refreshing either
  /// member serializes fully before the gates (mtime mismatch → the pair
  /// is kept) or fully after (the fresh file survives). Returns true when
  /// both members were deleted.
  ///
  /// P2-#41: the dual gate only prevents concurrent interleaving — if the
  /// second delete fails, the outer best-effort catch would swallow it and
  /// leave a half-pair. Snapshot both members first; on a second-delete
  /// failure restore the first so the pair stays whole (the next pass
  /// retries). Returns false when the pair was not deleted.
  Future<bool> _deleteCheckpointPair(
    File first,
    DateTime firstListedModified,
    File second,
    DateTime secondListedModified,
    DateTime activeSince,
  ) async {
    final List<({File file, DateTime listedModified})> ordered =
        <({File file, DateTime listedModified})>[
          (file: first, listedModified: firstListedModified),
          (file: second, listedModified: secondListedModified),
        ]..sort(
          (
            ({File file, DateTime listedModified}) a,
            ({File file, DateTime listedModified}) b,
          ) => a.file.path.compareTo(b.file.path),
        );
    return _withFileGate(ordered[0].file, () async {
      return _withFileGate(ordered[1].file, () async {
        for (final item in ordered) {
          final FileStat current = await item.file.stat();
          if (current.type != FileSystemEntityType.file ||
              current.modified != item.listedModified ||
              !current.modified.isBefore(activeSince)) {
            return false;
          }
        }
        final List<int> firstBytes = await ordered[0].file.readAsBytes();
        await ordered[0].file.delete();
        try {
          await ordered[1].file.delete();
        } catch (_) {
          // Restore the already-deleted first member: a half-pair breaks
          // the pair invariant (kept or deleted together, never split).
          // Best effort — if the restore also fails, the next pass treats
          // the remainder as an orphan singleton.
          try {
            await ordered[0].file.writeAsBytes(firstBytes, flush: true);
          } catch (_) {
            // Best effort; the next pass will retry the orphan.
          }
          return false;
        }
        await _removeMemoryHistory(ordered[0].file);
        await _removeMemoryHistory(ordered[1].file);
        return true;
      });
    });
  }

  /// Returns the paired checkpoint for [file] (job <-> book-memory
  /// companion), or null when the file is not a recognized checkpoint pair
  /// member. The memory companion's envelope carries the original job key in
  /// `inputFingerprint`; a regular job checkpoint's key is its file stem.
  Future<String?> _pairedCheckpointPath(Directory jobsDir, File file) async {
    Map<String, dynamic>? json;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      return null;
    }
    if (json == null) return null;
    final String stem = path.basenameWithoutExtension(file.path);
    if (json['status'] == 'book-memory') {
      final Object? jobKey = json['inputFingerprint'];
      if (jobKey is String && jobKey.isNotEmpty) {
        return path.join(jobsDir.path, '$jobKey.json');
      }
      return null;
    }
    final String memoryKey = sha256
        .convert(utf8.encode('$stem:book-memory'))
        .toString();
    return path.join(jobsDir.path, '$memoryKey.json');
  }

  Future<void> clearJobState(String jobKey) async {
    final File file = await _jobStateFile(jobKey);
    // Go through the per-file gate shared with [saveJobState]: without it
    // a clear racing a concurrent save could delete a checkpoint the save
    // just wrote, discarding already-paid translation progress.
    await _withFileGate(file, () async {
      final FileStat? saved = _savedJobStats[file.path];
      if (saved == null) return;
      final FileStat current = await file.stat();
      if (current.type != FileSystemEntityType.file ||
          current.modified != saved.modified ||
          current.size != saved.size) {
        return;
      }
      await file.delete();
      await _removeMemoryHistory(file);
      _savedJobStats.remove(file.path);
    });
  }

  Future<File> _blockCacheFile(String cacheKey) async {
    final Directory root = await _cacheRoot();
    return File(
      path.join(
        root.path,
        'blocks',
        cacheKey.substring(0, 2),
        '$cacheKey.html',
      ),
    );
  }

  Future<File> _jobStateFile(String jobKey) async {
    final Directory root = await _cacheRoot();
    return File(path.join(root.path, 'jobs', '$jobKey.json'));
  }

  Future<Directory> _cacheRoot() async {
    if (_rootOverride != null) return _rootOverride;
    final Future<Directory>? pending = _rootFuture;
    if (pending != null) return pending;
    final Future<Directory> future = (resolveCacheRoot ?? _resolveCacheRoot)();
    _rootFuture = future;
    try {
      return await future;
    } catch (_) {
      // A transient failure (platform channel hiccup, momentary IO error)
      // must not poison the root forever: drop the failed future so the
      // next call retries instead of replaying the same error for every
      // read, write and checkpoint.
      if (identical(_rootFuture, future)) _rootFuture = null;
      rethrow;
    }
  }

  Future<Directory> _resolveCacheRoot() async {
    final Directory appDirectory = Directory(
      await PlatformUtils.appDocumentsDirectory(),
    );
    return Directory(path.join(appDirectory.path, 'translation_cache'));
  }
}

class _CacheEntry {
  const _CacheEntry({
    required this.file,
    required this.size,
    required this.modified,
  });

  final File file;
  final int size;
  final DateTime modified;
}

/// Perf-#42: memo of a digest check for a rollback-suspect entry.
class _RollbackCheck {
  const _RollbackCheck({
    required this.modified,
    required this.size,
    required this.digest,
  });

  final DateTime modified;
  final int size;
  final Digest digest;
}
