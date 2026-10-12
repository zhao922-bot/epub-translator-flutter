import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'T1: P2-#11 lightweight eviction preserves same-size rewritten cache',
    () async {
      final root = await Directory.systemTemp.createTemp('c_round9_cache_');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026);
      final store = TranslationCacheStore(
        cacheRoot: root,
        // Small enough that a single entry exceeds the cap: the throwing
        // full scan arms the backoff, so the next over-capacity put takes
        // the lightweight path.
        maxCacheBytes: 300,
        now: () => now,
        onMaintenanceScan: () async {
          throw StateError('no scan');
        },
      );

      await store.putBlockTranslation('kA', 'x' * 300);
      await store.waitForMaintenanceForTest();
      final fileA = File(p.join(root.path, 'blocks', 'kA', 'kA.html'));
      final length = await fileA.length();
      final replacement = 'z' * length;
      await fileA.writeAsString(replacement);
      await fileA.setLastModified(DateTime.now().add(const Duration(hours: 1)));
      expect(await fileA.length(), length);

      // Move past the prune interval (fake clock): the next over-capacity
      // put skips the throwing full scan (the backoff, on a real stopwatch,
      // is still armed) and enforces the quota with the lightweight pass.
      now = now.add(const Duration(minutes: 6));
      await store.putBlockTranslation('kB', 'y' * 300);
      await store.waitForMaintenanceForTest();

      // The same-size rewrite must survive: a type+size-only check would
      // have deleted it. The fresh entry is evicted instead.
      expect(await fileA.exists(), isTrue);
      expect(await fileA.readAsString(), replacement);
      final fileB = File(p.join(root.path, 'blocks', 'kB', 'kB.html'));
      expect(await fileB.exists(), isFalse);
    },
  );

  test('T2: P2-#12 checkpoint pruning rechecks the paired checkpoint', () async {
    final root = await Directory.systemTemp.createTemp('c_round9_pair_');
    addTearDown(() => root.delete(recursive: true));
    final store = TranslationCacheStore(cacheRoot: root);
    final jobsDir = await Directory(p.join(root.path, 'jobs')).create();
    final job = File(p.join(jobsDir.path, 'job-abc.json'));
    final memoryKey = sha256.convert(utf8.encode('job-abc:book-memory'));
    final memory = File(p.join(jobsDir.path, '$memoryKey.json'));
    await job.writeAsString('{"jobKey":"job-abc"}');
    await memory.writeAsString(
      '{"status":"book-memory","inputFingerprint":"job-abc"}',
    );
    final old = DateTime.now().subtract(const Duration(minutes: 10));
    await job.setLastModified(old);
    await memory.setLastModified(old);

    const refreshed = '{"jobKey":"job-abc","v":2}';
    await store.pruneJobCheckpointsForTest(
      jobsDir,
      maxCheckpoints: 0,
      onListedForTest: () async {
        await job.writeAsString(refreshed);
      },
    );

    expect(await job.exists(), isTrue);
    expect(await job.readAsString(), refreshed);
    expect(await memory.exists(), isTrue);

    // Without a concurrent refresh, deleting one mate must not block the other.
    await job.setLastModified(old);
    await memory.setLastModified(old);
    await store.pruneJobCheckpointsForTest(jobsDir, maxCheckpoints: 0);
    expect(await job.exists(), isFalse);
    expect(await memory.exists(), isFalse);
  });
}
