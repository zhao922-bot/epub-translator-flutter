import 'dart:async';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/cache_restoration_scanner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/io/atomic_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;
  final stores = <TranslationCacheStore>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('c_cache_regression_');
  });
  tearDown(() async {
    for (final store in stores) {
      await store.waitForMaintenanceForTest();
    }
    stores.clear();
    await root.delete(recursive: true);
  });

  File blockFile(String key) =>
      File(path.join(root.path, 'blocks', key.substring(0, 2), '$key.html'));

  test(
    'C-13: a temp promoted during listing is counted exactly once',
    () async {
      final target = blockFile('abrename');
      await target.parent.create(recursive: true);
      final temp = File(tempPathForAtomicWrite(target));
      await temp.writeAsString('paid translation' * 100);
      final bytes = await temp.length();
      final store = TranslationCacheStore(
        cacheRoot: root,
        onMaintenanceScan: () async {
          await temp.rename(target.path);
        },
      );
      stores.add(store);
      // Simulates an atomic rename from a concurrent store/process after the
      // listing has counted the temp but before accounting is reconciled.
      await store.pruneCacheDirectoryForTest(root);
      expect(store.estimatedCacheBytesForTest, bytes);
      expect(
        await store.getBlockTranslation('abrename'),
        'paid translation' * 100,
      );
    },
  );

  test(
    'C-13: local writes overlay a promoted temp without double counting',
    () async {
      final target = blockFile('abrename');
      await target.parent.create(recursive: true);
      final temp = File(tempPathForAtomicWrite(target));
      await temp.writeAsString('old');
      final entered = Completer<void>();
      final release = Completer<void>();
      int scans = 0;
      final store = TranslationCacheStore(
        cacheRoot: root,
        onMaintenanceScan: () async {
          if (++scans == 1) {
            entered.complete();
            await release.future;
          }
        },
      );
      stores.add(store);
      final pass = store.pruneCacheDirectoryForTest(root);
      await entered.future;
      await temp.rename(target.path);
      await store.putBlockTranslation('abrename', 'new translation');
      final bytes = await target.length();
      release.complete();
      await pass;
      expect(store.estimatedCacheBytesForTest, bytes);
      await store.waitForMaintenanceForTest();
      expect(store.estimatedCacheBytesForTest, bytes);
    },
  );

  test(
    'C-14: writes protected in the first scan trigger immediate cleanup',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      int scans = 0;
      final store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 250,
        onMaintenanceScan: () async {
          if (++scans == 1) {
            entered.complete();
            await release.future;
          }
        },
      );
      stores.add(store);
      await store.putBlockTranslation('abfirst', 'small');
      await entered.future;
      await store.putBlockTranslation('abfirst', 'x' * 300);
      await store.putBlockTranslation('abnew', 'y' * 300);
      release.complete();
      await store.waitForMaintenanceForTest();
      expect(scans, 2);
      expect(store.estimatedCacheBytesForTest, lessThanOrEqualTo(250));
    },
  );

  test(
    'C-15: backoff skips full rescans but light quota passes prevent stalls',
    () async {
      var now = DateTime.now();
      int scans = 0;
      final temp = '${blockFile('aborphan').path}.tmp.live';
      await File(temp).parent.create(recursive: true);
      await File(temp).writeAsString('x' * 1000);
      final store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 200,
        now: () => now,
        onMaintenanceScan: () async {
          scans++;
          // Simulate a concurrently touched/occupied entry that the scan
          // cannot safely evict, leaving only unreclaimable over-cap space.
          final trigger = blockFile('abtrigger');
          final stat = await trigger.stat();
          if (stat.type == FileSystemEntityType.file) {
            await trigger.setLastModified(
              stat.modified.add(const Duration(seconds: 1)),
            );
          }
        },
      );
      stores.add(store);
      Future<void> put() async {
        await store.putBlockTranslation('abtrigger', 'ok');
        await store.waitForMaintenanceForTest();
      }

      await put();
      final baseline = scans;
      // Puts inside the prune interval do not rescan.
      for (int i = 0; i < 10; i++) {
        await put();
      }
      expect(scans, baseline);
      // P2-#29: while the backoff is armed, over-capacity puts run the
      // lightweight quota pass instead of a full rescan — the full scan was
      // proven unable to reclaim space (the .tmp.live file is unreclaimable),
      // so walking the whole tree again would only burn IO. Eviction must
      // still not stall: the light pass keeps enforcing the quota.
      final lightBaseline = store.lightPruneCountForTest;
      for (int i = 0; i < 4; i++) {
        now = now.add(const Duration(minutes: 5));
        await put();
        // Full scans are skipped while the backoff is armed...
        expect(scans, baseline);
        // ...but the lightweight quota pass still runs (no hour-long stall).
        expect(store.lightPruneCountForTest, lightBaseline + 1 + i);
      }
      await File(temp).delete();
      // The backoff runs on a real Stopwatch, so the fake-time travel above
      // cannot expire it. In real usage the store itself deletes the temp
      // file (updating the estimate), and the next light pass clears the
      // backoff once the quota is met. Simulate that here.
      store.resetBackoffForTest();
      now = now.add(const Duration(minutes: 5));
      await put();
      expect(store.estimatedCacheBytesForTest, lessThanOrEqualTo(200));
      // A new over-cap write is scanned once the interval expires.
      final before = scans;
      now = now.add(const Duration(minutes: 5));
      await store.putBlockTranslation('ablarge', 'z' * 300);
      await store.waitForMaintenanceForTest();
      expect(scans, before + 1);
    },
  );

  test(
    'C-15: concurrent writes cannot cause unlimited no-effect follow-ups',
    () async {
      int scans = 0;
      late TranslationCacheStore store;
      store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 100,
        onMaintenanceScan: () async {
          scans++;
          // Replace every candidate during each scan. Nothing can be evicted
          // in that pass, even though writes keep arriving above capacity.
          await store.putBlockTranslation('abkey', 'x' * 200);
        },
      );
      stores.add(store);
      await store.putBlockTranslation('abkey', 'x' * 200);
      await store.waitForMaintenanceForTest().timeout(
        const Duration(seconds: 5),
      );
      expect(scans, 2);
      await store.putBlockTranslation('abkey', 'x' * 200);
      await store.waitForMaintenanceForTest();
      expect(scans, 2);
      // Shrinking the entry below capacity clears the negative cache.
      await store.putBlockTranslation('abkey', '');
      expect(store.estimatedCacheBytesForTest, lessThanOrEqualTo(100));
      await store.putBlockTranslation('abkey', 'x' * 200);
      await store.waitForMaintenanceForTest();
      expect(scans, 4);
    },
  );

  test(
    'C-16: 21 recently active checkpoints survive even the oldest two',
    () async {
      final now = DateTime.now();
      final jobs = Directory(path.join(root.path, 'jobs'));
      await jobs.create();
      for (int i = 0; i < 21; i++) {
        final file = File(path.join(jobs.path, '$i.json'));
        await file.writeAsString('{}');
        await file.setLastModified(
          now.subtract(Duration(seconds: i < 2 ? 120 : 60)),
        );
      }
      final store = TranslationCacheStore(cacheRoot: root, now: () => now);
      await store.pruneJobCheckpointsForTest(jobs);
      expect(await File(path.join(jobs.path, '0.json')).exists(), isTrue);
      expect(await File(path.join(jobs.path, '1.json')).exists(), isTrue);
      expect(await jobs.list().length, 21);
      // Age out the protection; ordinary count-based pruning resumes.
      for (final file in jobs.listSync().whereType<File>()) {
        await file.setLastModified(now.subtract(const Duration(minutes: 10)));
      }
      await store.pruneJobCheckpointsForTest(jobs);
      expect(await jobs.list().length, 20);
    },
  );

  test('C-17: concurrent lookups share a single root initialization', () async {
    int calls = 0;
    final ready = Completer<Directory>();
    final store = TranslationCacheStore(
      resolveCacheRoot: () {
        calls++;
        return ready.future;
      },
    );
    stores.add(store);
    final reads = Future.wait([
      store.getBlockTranslation('abmissing'),
      store.getBlockTranslation('cdmissing'),
      store.loadJobState('missing'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    ready.complete(root);
    await reads;
    await store.putBlockTranslation('abkey', 'cached');
    await store.waitForMaintenanceForTest();
    expect(await store.getBlockTranslation('abkey'), 'cached');
    expect(calls, 1);
    final override = TranslationCacheStore(
      cacheRoot: root,
      resolveCacheRoot: () async {
        throw StateError('override must win');
      },
    );
    expect(await override.getBlockTranslation('abkey'), 'cached');
  });

  test(
    'C-18: valid UTF-8 tampering is a miss; normal and legacy reads work',
    () async {
      final store = TranslationCacheStore(cacheRoot: root);
      stores.add(store);
      await store.putBlockTranslation('abkey', '<p>paid translation 中文</p>');
      await store.waitForMaintenanceForTest();
      expect(
        await store.getBlockTranslation('abkey'),
        '<p>paid translation 中文</p>',
      );
      final file = blockFile('abkey');
      final raw = await file.readAsString();
      await file.writeAsString(raw.replaceFirst('paid', 'laid'));
      expect(await store.getBlockTranslation('abkey'), isNull);
      final chapter = _chapter('chapter', [_block('a', 'source')]);
      final result =
          await CacheRestorationScanner(
            readTranslation: store.getBlockTranslation,
          ).scan(
            chapters: [chapter],
            cacheKeyFor: (_, _) => 'abkey',
            throwIfCancelled: () {},
          );
      expect(result.cachedBlocks, 0);
      expect(result.lastPendingChapterIndex, 0);
      await file.writeAsString('<p>legacy paid work</p>');
      expect(
        await store.getBlockTranslation('abkey'),
        '<p>legacy paid work</p>',
      );
    },
  );

  test(
    'C-19: ETA excludes restored blocks and null preserves old behavior',
    () {
      const base = TranslationRunEstimate(
        selectedChapters: 1,
        totalBlocks: 2000,
        estimatedApiBatches: 50,
      );
      final estimate = base.withProgress(
        completedBlocks: 1000,
        totalBlocks: 2000,
        apiTranslatedBlocks: 100,
        elapsed: const Duration(minutes: 1),
      );
      expect(estimate.completedBlocks, 1000);
      expect(estimate.blocksPerMinute, closeTo(100, 0.001));
      expect(estimate.estimatedRemaining, const Duration(minutes: 10));
      final legacy = base.withProgress(
        completedBlocks: 1000,
        totalBlocks: 2000,
        apiTranslatedBlocks: null,
        elapsed: const Duration(minutes: 1),
      );
      expect(legacy.blocksPerMinute, 1000);
      expect(legacy.estimatedRemaining, const Duration(minutes: 1));
      final onlyCache = base.withProgress(
        completedBlocks: 1000,
        totalBlocks: 2000,
        apiTranslatedBlocks: 0,
        elapsed: const Duration(minutes: 1),
      );
      expect(onlyCache.blocksPerMinute, isNull);
      expect(onlyCache.estimatedRemaining, isNull);
    },
  );

  test('C-20: batch estimate matches real title and snippet planning', () {
    final blocks = List.generate(20, (i) => _block('$i', 'source text ' * 10));
    for (final title in ['Title ' * 100, 'Short title']) {
      final chapter = _chapter(title, blocks);
      final planned = const TranslationBatchPlanner().plan(
        pendingBlocks: blocks,
        chapterBlocks: blocks,
        chapterTitle: title,
        chunkSize: 1000,
      );
      final estimate = TranslationRunEstimate.staticPart([
        chapter,
      ], chunkSize: 1000);
      expect(estimate.estimatedApiBatches, planned.length);
      expect(
        planned.length,
        greaterThan(5),
        reason: 'old hand-copy packed five batches',
      );
    }
  });
}

ExtractedBlock _block(String id, String text) => ExtractedBlock(
  id: id,
  tagName: 'p',
  sourceHtml: '<p>$text</p>',
  sourceText: text,
);
InspectedChapter _chapter(String title, List<ExtractedBlock> blocks) =>
    InspectedChapter(
      path: 'chapter.xhtml',
      title: title,
      body: '',
      originalHtml: '',
      blocks: blocks,
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );
