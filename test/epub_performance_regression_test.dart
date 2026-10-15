import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/cache_restoration_scanner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_work_queue.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MeasuredStore extends TranslationCacheStore {
  _MeasuredStore(Directory root) : super(cacheRoot: root);
  int bytes = 0;
  int largestWrite = 0;
  bool failNext = false;
  @override
  Future<void> saveMemoryCheckpoint(
    JobResumeState state, {
    String? chunkHash,
    String? chunk,
  }) async {
    if (failNext) {
      failNext = false;
      throw const FileSystemException('injected disk failure');
    }
    final size =
        utf8.encode(jsonEncode(state.toJson())).length +
        (chunk == null ? 0 : utf8.encode(chunk).length);
    bytes += size;
    if (size > largestWrite) largestWrite = size;
    await super.saveMemoryCheckpoint(state, chunkHash: chunkHash, chunk: chunk);
  }
}

String memoryKey(String job) =>
    sha256.convert(utf8.encode('$job:book-memory')).toString();

final class _HeadWriteFailure extends IOOverrides {
  _HeadWriteFailure(this.headPath);
  final String headPath;
  @override
  File createFile(String path) {
    if (path.startsWith('$headPath.tmp.')) {
      throw FileSystemException('injected checkpoint commit failure', path);
    }
    return super.createFile(path);
  }
}

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('epub-performance-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test(
    '600 chapter checkpoint writes stay linear and restore every snapshot',
    () async {
      final cache = _MeasuredStore(root);
      final write =
          await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
            cacheStore: cache,
            jobKey: 'linear',
            chunkSize: 3000,
          );
      final entries = <({String path, Map<String, Object?> memory})>[];
      var bytesAt100 = 0;
      for (var index = 0; index < 600; index++) {
        entries.add((
          path: 'chapter-$index.xhtml',
          memory: {
            'bookSummary': 'Summary $index ${'a' * 420}',
            'glossary': [
              for (var term = 0; term < 10; term++)
                {'source': 'Term $term', 'target': '术语 $term'},
            ],
          },
        ));
        await write(entries);
        if (index == 99) bytesAt100 = cache.bytes;
      }
      expect(cache.bytes, lessThan(bytesAt100 * 7));
      expect(cache.largestWrite, lessThan(8000));
      final restored =
          await EpubChapterTranslator.loadBookMemoryTimelineForTest(
            cacheStore: TranslationCacheStore(cacheRoot: root),
            jobKey: 'linear',
            chunkSize: 3000,
          );
      expect(restored.length, 600);
      expect(restored.first['path'], 'chapter-0.xhtml');
      expect(restored.last['path'], 'chapter-599.xhtml');
      // Printed measurements count actual payloads passed to atomic writes.
      // ignore: avoid_print
      print(
        'CHECKPOINT 100=$bytesAt100 bytes; 600=${cache.bytes} bytes; largest=${cache.largestWrite} bytes',
      );
    },
    // Complexity is asserted through bytes written, not disk throughput.
    // Allow slow Windows CI disks to finish 600 durable checkpoints and reads.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('failed save leaves the watermark at the durable head', () async {
    final cache = _MeasuredStore(root);
    final write = await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
      cacheStore: cache,
      jobKey: 'failure',
      chunkSize: 3000,
    );
    final entries = [
      for (var i = 0; i < 3; i++)
        (path: '$i.xhtml', memory: <String, Object?>{'bookSummary': '$i'}),
    ];
    await write(entries.take(1).toList());
    cache.failNext = true;
    await expectLater(
      write(entries.take(2).toList()),
      throwsA(isA<FileSystemException>()),
    );
    var restored = await EpubChapterTranslator.loadBookMemoryTimelineForTest(
      cacheStore: cache,
      jobKey: 'failure',
      chunkSize: 3000,
    );
    expect(restored.length, 1);
    await write(entries);
    restored = await EpubChapterTranslator.loadBookMemoryTimelineForTest(
      cacheStore: cache,
      jobKey: 'failure',
      chunkSize: 3000,
    );
    expect(restored.map((e) => e['path']), ['0.xhtml', '1.xhtml', '2.xhtml']);
  });

  test(
    'a durable chunk without a committed head leaves the old checkpoint intact',
    () async {
      final cache = TranslationCacheStore(cacheRoot: root);
      final write =
          await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
            cacheStore: cache,
            jobKey: 'commit-failure',
            chunkSize: 3000,
          );
      final entries = [
        for (var i = 0; i < 2; i++)
          (path: '$i.xhtml', memory: <String, Object?>{'bookSummary': '$i'}),
      ];
      await write(entries.take(1).toList());
      final key = memoryKey('commit-failure');
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => write(entries),
          _HeadWriteFailure(
            '${root.path}${Platform.pathSeparator}jobs${Platform.pathSeparator}$key.json',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await EpubChapterTranslator.loadBookMemoryTimelineForTest(
          cacheStore: cache,
          jobKey: 'commit-failure',
          chunkSize: 3000,
        )).length,
        1,
      );
      await write(entries);
      expect(
        (await EpubChapterTranslator.loadBookMemoryTimelineForTest(
          cacheStore: cache,
          jobKey: 'commit-failure',
          chunkSize: 3000,
        )).length,
        2,
      );
    },
  );

  test('legacy envelope migrates and damaged history is rejected', () async {
    final cache = TranslationCacheStore(cacheRoot: root);
    final key = memoryKey('migration');
    await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
      cacheStore: cache,
      jobKey: 'migration',
      chunkSize: 3000,
      memory: {'bookSummary': 'old'},
    );
    final initial = (await cache.loadJobState(key))!;
    final envelope = jsonDecode(initial.currentChapter) as Map<String, dynamic>;
    envelope.remove('timelineHead');
    envelope.remove('timelineFormat');
    envelope.remove('timelineLength');
    envelope['schema'] = EpubChapterTranslator.qualityCacheSchemaVersion;
    envelope['completedChapterPaths'] = ['old.xhtml'];
    envelope['memoryTimeline'] = [
      {
        'path': 'old.xhtml',
        'memory': {'bookSummary': 'old'},
      },
    ];
    await cache.saveJobState(
      JobResumeState.fromJson({
        ...initial.toJson(),
        'currentChapter': jsonEncode(envelope),
      }),
    );
    final write = await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
      cacheStore: cache,
      jobKey: 'migration',
      chunkSize: 3000,
      resume: true,
    );
    await write([
      (path: 'old.xhtml', memory: <String, Object?>{'bookSummary': 'old'}),
      (path: 'new.xhtml', memory: <String, Object?>{'bookSummary': 'new'}),
    ]);
    expect(
      (await EpubChapterTranslator.loadBookMemoryTimelineForTest(
        cacheStore: cache,
        jobKey: 'migration',
        chunkSize: 3000,
      )).length,
      2,
    );
    final state = (await cache.loadJobState(key))!;
    final head = jsonDecode(state.currentChapter)['timelineHead'];
    await File(
      '${root.path}/jobs/$key.json.history/$head.json',
    ).writeAsString('{}');
    expect(
      await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: 'migration',
        chunkSize: 3000,
      ),
      isNull,
    );
  });

  test('clearing checkpoint also removes its immutable history', () async {
    final cache = TranslationCacheStore(cacheRoot: root);
    await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
      cacheStore: cache,
      jobKey: 'cleanup',
      chunkSize: 3000,
      memory: {},
      timeline: [(path: 'c.xhtml', memory: {})],
    );
    final key = memoryKey('cleanup');
    final history = Directory('${root.path}/jobs/$key.json.history');
    expect(await history.exists(), isTrue);
    await cache.clearJobState(key);
    expect(await history.exists(), isFalse);
  });

  test(
    'cache scan retains one chapter and snapshots survive cache eviction',
    () async {
      final chapters = [
        for (var i = 0; i < 30; i++)
          InspectedChapter(
            path: '$i.xhtml',
            title: '$i',
            body: '',
            originalHtml: '',
            category: ChapterCategory.content,
            recommendedForTranslation: true,
            includeInTranslation: true,
            blocks: [
              ExtractedBlock(
                id: 'p-1',
                tagName: 'p',
                sourceHtml: '<p>Source</p>',
                sourceText: 'Source',
              ),
            ],
          ),
      ];
      final values = {
        for (final chapter in chapters) chapter.path: '<p>${'译文' * 5000}</p>',
      };
      final spool = CacheRestorationSpool();
      addTearDown(spool.dispose);
      final result =
          await CacheRestorationScanner(
            readTranslation: (key) async => values[key],
          ).scan(
            chapters: chapters,
            cacheKeyFor: (chapter, _) => chapter.path,
            throwIfCancelled: () {},
            persistChapter: spool.save,
          );
      expect(result.cachedBlocks, 30);
      expect(result.translationsByChapter, isEmpty);
      values.clear();
      for (final chapter in chapters) {
        await spool.loadChapter(result, chapter.path);
        expect(result.translationsByChapter.length, 1);
        expect(result.translationFor(chapter.path, 'p-1'), contains('译文'));
        result.translationsByChapter.remove(chapter.path);
      }
    },
  );

  test(
    'queued requests honor shared cooldown and cancellation releases permit',
    () async {
      final budget = TranslationRequestBudget(1);
      final firstGate = Completer<void>();
      final first = budget.run(() => firstGate.future);
      var started = false;
      var cancelled = false;
      final next = budget.run(
        () async {
          started = true;
        },
        throwIfCancelled: () {
          if (cancelled) throw const TranslationCancelledException();
        },
      );
      budget.deferFor(const Duration(seconds: 1));
      firstGate.complete();
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(started, isFalse);
      cancelled = true;
      await expectLater(next, throwsA(isA<TranslationCancelledException>()));
      // A cancelled waiter releases its permit; subsequent work can run.
      expect(await budget.run(() async => 42), 42);
    },
  );

  test('inspection rejects extreme depth before parsing or serialization', () {
    final html = '${'<div>' * 20000}deep${'</div>' * 20000}';
    expect(
      () => const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'deep.xhtml',
        bytes: utf8.encode(html),
      ),
      throwsFormatException,
    );
  });
}
