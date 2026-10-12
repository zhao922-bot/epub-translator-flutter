import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

InspectedChapter _chapter(String title, String path, {String text = 'Original prose.'}) {
  return const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: path,
    bytes: utf8.encode('<html><head><title>$title</title></head><body><p>$text</p></body></html>'),
  ).copyWith(title: title, category: ChapterCategory.content, includeInTranslation: true);
}

Future<void> _writeEpub(File input, List<InspectedChapter> chapters) async {
  final archive = Archive();
  for (final entry in {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
    'OPS/content.opf': '<package><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Book</dc:title></metadata></package>',
    for (final c in chapters) c.path: c.originalHtml,
  }.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  await input.writeAsBytes(ZipEncoder().encode(archive));
}

class _Api extends TranslationApiClient {
  final List<Map<String, dynamic>> requests = [];
  final List<Object> replies = [];
  int initialMemoryCalls = 0;
  int chapterMemoryCalls = 0;
  int individualCalls = 0;

  /// Overrides the default per-request plain-text reply (used by slot-text
  /// and single-block paths, which reject HTML wrappers).
  String individualReply = '<p>这是一段已翻译的文字。</p>';

  @override
  Dio buildDio(TranslationConfig config) => Dio(BaseOptions(baseUrl: config.apiBaseUrl));

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio, required Map<String, dynamic> data, CancelToken? cancelToken,
  }) async {
    requests.add(data);
    final messages = data['messages'] as List;
    final user = messages.last['content'] as String;
    Object reply;
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      if (payload['kind'] == 'initialBookMemory') {
        initialMemoryCalls++;
        reply = {'bookSummary': 'Persistent summary', 'glossary': [
          {'source': 'prose', 'target': '散文'},
        ]};
      } else if (payload['kind'] == 'chapterMemory') {
        chapterMemoryCalls++;
        reply = {'title': 't', 'summary': 'continuity', 'glossary': []};
      } else {
        reply = replies.isNotEmpty ? replies.removeAt(0) : {
          'blocks': [for (final b in payload['blocks'] as List) {
            'id': b['id'], 'html': '<p>这是一段已翻译的文字。</p>',
          }],
        };
      }
    } else {
      individualCalls++;
      reply = individualReply;
    }
    return Response(requestOptions: RequestOptions(), data: {
      'choices': [{'message': {'content': reply is String ? reply : jsonEncode(reply)}}],
    });
  }
}

class _Repacker extends EpubRepacker {
  @override
  Future<void> writeTranslatedEpub({
    required String inputPath, required String outputFilePath,
    required TranslationConfig config, required List<InspectedChapter> chapters,
    CancelToken? cancelToken, bool Function()? isCancelled,
    Set<String> degradedBlockIds = const {}, String? translatedTitle,
    void Function(int, int)? onProgress,
  }) async {
    await File(outputFilePath).writeAsString('translated epub');
  }
}

DioException _dio400(String body) => DioException(
  requestOptions: RequestOptions(),
  type: DioExceptionType.badResponse,
  response: Response(requestOptions: RequestOptions(), statusCode: 400, data: body),
);

void main() {
  final config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://example.com/v1', apiKey: 'test-key', model: 'test',
    residualQualityCheck: false, styleProfileEnabled: false, maxRetries: 3,
  );

  group('#18 max_tokens ceiling and context-overflow routing', () {
    test('max_tokens is clamped to the model output ceiling', () async {
      final api = _Api();
      final bigText = List.filled(60000, 'word ').join();
      await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config), config: config,
        blocks: _chapter('Big', 'big.xhtml', text: bigText).blocks,
      );
      final maxTokens = api.requests.single['max_tokens'] as int;
      expect(maxTokens, lessThanOrEqualTo(32768));
    });

    test('context-window 400 responses are detected as overflow, not deterministic', () {
      expect(TranslationApiClient.isContextOverflowError(_dio400(
        '{"error":{"message":"This model\'s maximum context length is 8192 tokens"}}',
      )), isTrue);
      expect(TranslationApiClient.isContextOverflowError(_dio400(
        'Requested max_tokens 40000 exceeds the model limit of 32768',
      )), isTrue);
      expect(TranslationApiClient.isContextOverflowError(_dio400('invalid request: unknown model')), isFalse);
      expect(TranslationApiClient.isContextOverflowError(_dio400('')), isFalse);
      final e401 = DioException(
        requestOptions: RequestOptions(), type: DioExceptionType.badResponse,
        response: Response(requestOptions: RequestOptions(), statusCode: 401, data: 'context length'),
      );
      expect(TranslationApiClient.isContextOverflowError(e401), isFalse);
    });

    test('context-overflow 400 routes to shrink fallback instead of termination', () {
      expect(EpubChapterTranslator.shouldFallbackBatchDioExceptionForTest(
        _dio400('maximum context length exceeded')), isTrue);
      expect(EpubChapterTranslator.shouldFallbackBatchDioExceptionForTest(
        _dio400('bad request: malformed json')), isFalse);
      expect(TranslationApiClient.isDeterministicHttpError(_dio400('context length exceeded')), isTrue,
        reason: 'the overflow error is deterministic, but the fallback check must win first');
    });
  });

  group('#19 per-slot requests omit the full source HTML', () {
    test('slot context carries a bounded summary, not the complete block', () async {
      final api = _Api()..individualReply = '这是槽位译文';
      // Fail the slot batch so the flow falls back to the per-slot path.
      api.replies.add('this is not JSON at all');
      final block = _chapter(
        'Note', 'note.xhtml',
        text: 'Before <a id="footnote_ref_1" href="#note-1">*</a> after.',
      ).blocks.single;
      await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config.copyWith(maxRetries: 1)), config: config.copyWith(maxRetries: 1),
        blocks: [block],
      );
      final slotRequests = api.requests.where((data) {
        final messages = data['messages'] as List;
        return messages.any((m) => (m['content'] as String).contains('blockSummary'));
      }).toList();
      expect(slotRequests, isNotEmpty, reason: 'the per-slot path must have been reached');
      for (final data in slotRequests) {
        final system = (data['messages'] as List)
            .map((m) => m['content'] as String)
            .firstWhere((c) => c.contains('blockSummary'));
        expect(system, isNot(contains('footnote_ref_1')),
          reason: 'per-slot context must not repeat the full source HTML');
      }
    });
  });

  group('#20 positional memory snapshots', () {
    List<Map<String, Object?>> timeline() => [
      {'path': 'ch1.xhtml', 'memory': {
        'bookSummary': 'summary-1',
        'recentChapters': [{'title': 'Ch1', 'path': 'ch1.xhtml', 'summary': 's1'}],
      }},
      {'path': 'ch2.xhtml', 'memory': {
        'bookSummary': 'summary-2',
        'recentChapters': [{'title': 'Ch2', 'path': 'ch2.xhtml', 'summary': 's2'}],
      }},
    ];
    const paths = ['ch1.xhtml', 'ch2.xhtml', 'ch3.xhtml'];
    const fallback = {'bookSummary': 'live'};

    test('an earlier chapter never sees later chapters rolling memory', () {
      final snapshot = EpubChapterTranslator.positionalMemorySnapshotForTest(
        timeline: timeline(), orderedPaths: paths,
        chapterPath: 'ch2.xhtml', fallback: fallback,
      );
      expect(snapshot!['bookSummary'], 'summary-1');
      expect((snapshot['recentChapters'] as List).single['title'], 'Ch1');
    });

    test('the first chapter falls back to the live memory', () {
      final snapshot = EpubChapterTranslator.positionalMemorySnapshotForTest(
        timeline: timeline(), orderedPaths: paths,
        chapterPath: 'ch1.xhtml', fallback: fallback,
      );
      expect(snapshot, fallback);
    });

    test('a later chapter sees the newest earlier entry', () {
      final snapshot = EpubChapterTranslator.positionalMemorySnapshotForTest(
        timeline: timeline(), orderedPaths: paths,
        chapterPath: 'ch3.xhtml', fallback: fallback,
      );
      expect(snapshot!['bookSummary'], 'summary-2');
    });

    test('memory timeline survives the checkpoint round-trip', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-memory-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);
      await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
        cacheStore: cache, jobKey: 'job1', chunkSize: 3000,
        memory: {'bookSummary': 'live', 'glossary': [
          {'source': 't', 'target': '译'},
        ]},
        timeline: [(path: 'ch1.xhtml', memory: {'bookSummary': 's1'})],
      );
      final loaded = await EpubChapterTranslator.loadBookMemoryTimelineForTest(
        cacheStore: cache, jobKey: 'job1', chunkSize: 3000,
      );
      expect(loaded, hasLength(1));
      expect(loaded.single['path'], 'ch1.xhtml');
      expect((loaded.single['memory'] as Map)['bookSummary'], 's1');
    });
  });

  group('#21 paired checkpoint pruning', () {
    Future<void> writeOld(Directory jobs, String name, String content, Duration age) async {
      final file = File('${jobs.path}/$name');
      await file.writeAsString(content);
      file.setLastModifiedSync(DateTime.now().subtract(age));
    }

    test('an active job keeps its memory companion', () async {
      final root = await Directory.systemTemp.createTemp('a-round7-prune-');
      addTearDown(() => root.delete(recursive: true));
      final jobs = await Directory('${root.path}/jobs').create();
      // Active job: fresh, so never a prune candidate.
      await File('${jobs.path}/job-new.json')
          .writeAsString('{"jobKey":"job-new","status":"translating"}');
      // Its memory companion is the oldest file on disk.
      final memKey = sha256.convert(utf8.encode('job-new:book-memory')).toString();
      final companion = File('${jobs.path}/$memKey.json');
      await writeOld(jobs, '$memKey.json',
        '{"status":"book-memory","inputFingerprint":"job-new"}', const Duration(minutes: 60));
      for (int i = 0; i < 20; i++) {
        await writeOld(jobs, 'old$i.json', '{"jobKey":"old$i"}', const Duration(minutes: 30));
      }
      await TranslationCacheStore().pruneJobCheckpointsForTest(jobs, maxCheckpoints: 20);
      expect(await companion.exists(), isTrue,
        reason: 'paired with an active job, the memory file must be kept');
      expect(await File('${jobs.path}/job-new.json').exists(), isTrue);
      expect(await File('${jobs.path}/old0.json').exists(), isFalse,
        reason: 'the oldest unpaired checkpoint is pruned instead');
    });

    test('a stale pair is deleted together', () async {
      final root = await Directory.systemTemp.createTemp('a-round7-prune-stale-');
      addTearDown(() => root.delete(recursive: true));
      final jobs = await Directory('${root.path}/jobs').create();
      await writeOld(jobs, 'job-old.json', '{"jobKey":"job-old"}', const Duration(minutes: 50));
      final memKey = sha256.convert(utf8.encode('job-old:book-memory')).toString();
      await writeOld(jobs, '$memKey.json',
        '{"status":"book-memory","inputFingerprint":"job-old"}', const Duration(minutes: 60));
      for (int i = 0; i < 20; i++) {
        await writeOld(jobs, 'old$i.json', '{"jobKey":"old$i"}', const Duration(minutes: 30));
      }
      await TranslationCacheStore().pruneJobCheckpointsForTest(jobs, maxCheckpoints: 20);
      expect(await File('${jobs.path}/$memKey.json').exists(), isFalse);
      expect(await File('${jobs.path}/job-old.json').exists(), isFalse);
      expect(await File('${jobs.path}/old0.json').exists(), isTrue);
    });
  });

  group('#22 damaged checkpoints are discarded, not silently used', () {
    Future<void> writeRawCheckpoint(
      TranslationCacheStore cache, String jobKey, Map<String, Object?> memory,
    ) async {
      final key = sha256.convert(utf8.encode('$jobKey:book-memory')).toString();
      await cache.saveJobState(JobResumeState(
        jobKey: key, inputFingerprint: jobKey, inputPath: 'in.epub',
        outputPath: 'out.epub', status: 'book-memory',
        completedFiles: 0, totalFiles: 1, completedBlocks: 0, totalBlocks: 1,
        cachedBlocks: 0, resumedBlocks: 0,
        currentChapter: jsonEncode({
          'schema': EpubChapterTranslator.qualityCacheSchemaVersion,
          'jobKey': jobKey, 'chunkSize': 3000,
          'memory': memory, 'completedChapterPaths': <String>[],
        }),
        updatedAtIso8601: DateTime.now().toIso8601String(),
      ));
    }

    test('a non-list glossary discards the checkpoint', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-corrupt-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);
      await writeRawCheckpoint(cache, 'job1', {'glossary': 'not-a-list', 'bookSummary': 's'});
      expect(await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
        cacheStore: cache, jobKey: 'job1', chunkSize: 3000,
      ), isNull);
    });

    test('a structurally intact checkpoint still loads', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-intact-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);
      await writeRawCheckpoint(cache, 'job1', {'bookSummary': 's', 'glossary': [
        {'source': 't', 'target': '译'},
      ]});
      final loaded = await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
        cacheStore: cache, jobKey: 'job1', chunkSize: 3000,
      );
      expect(loaded, isNotNull);
      expect(loaded!['bookSummary'], 's');
    });
  });

  group('#23 user locks beat model-declared locks', () {
    test('model-declared locked:true is not trusted', () async {
      final api = _Api();
      final memory = await EpubChapterTranslator(apiClient: api).generateInitialBookMemoryForTest(
        dio: api.buildDio(config), config: config, chapters: [_chapter('Body', 'body.xhtml')],
      );
      final terms = (memory['glossary'] as List).cast<Map>();
      final prose = terms.singleWhere((t) => t['source'] == 'prose');
      expect(prose['target'], '散文');
      expect(prose.containsKey('locked'), isFalse);
    });

    test('an explicit user re-lock replaces the older locked term', () {
      final base = {'glossary': [
        {'source': 'Macbeth', 'target': '麦克佩斯', 'locked': 'true', 'lastUsed': '1'},
      ]};
      final chapter = {'title': 't', 'summary': 's', 'glossary': [
        {'source': 'Macbeth', 'target': '麦克白', 'locked': 'true'},
      ]};
      final merged = EpubChapterTranslator.mergeBookMemoryForTest(base, chapter,
        trustedMemoryLocks: true, trustedChapterLocks: true);
      final terms = (merged['glossary'] as List).cast<Map>();
      expect(terms.singleWhere((t) => t['source'] == 'Macbeth')['target'], '麦克白');
    });

    test('a user-locked term survives model updates', () {
      final base = {'glossary': [
        {'source': 'Macbeth', 'target': '麦克白', 'locked': 'true', 'lastUsed': '1'},
      ]};
      final chapter = {'title': 't', 'summary': 's', 'glossary': [
        {'source': 'Macbeth', 'target': '模型译'},
      ]};
      final merged = EpubChapterTranslator.mergeBookMemoryForTest(base, chapter,
        trustedMemoryLocks: true, trustedChapterLocks: true);
      final terms = (merged['glossary'] as List).cast<Map>();
      expect(terms.singleWhere((t) => t['source'] == 'Macbeth')['target'], '麦克白');
    });
  });

  group('#24/#25/#44 spool restore', () {
    Future<(String epubPath, String fingerprint)> writeMalformedEpub(Directory temp) async {
      final malformed = <int>[
        ...utf8.encode('<html><body><p>Valid start '),
        0xFF, 0xFE, 0xC3,
        ...utf8.encode(' valid end</p></body></html>'),
      ];
      // The fixture really is undecodable with strict UTF-8.
      expect(() => utf8.decode(malformed), throwsA(isA<FormatException>()));
      final archive = Archive();
      for (final entry in {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
        'OPS/content.opf': '<package><metadata/></package>',
        'Text/ch1.xhtml': malformed,
      }.entries) {
        final bytes = entry.value is String ? utf8.encode(entry.value as String) : entry.value as List<int>;
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      final epubPath = '${temp.path}/malformed.epub';
      await File(epubPath).writeAsBytes(ZipEncoder().encode(archive));
      final snapshot = await EpubIsolateWorker.loadArchiveSnapshot(epubPath);
      return (epubPath, snapshot.fingerprint);
    }

    InspectedChapter releasedChapter(String epubPath, String fingerprint) {
      // Build the released (sources cleared) shape the same way production
      // code does: a single <p> block keeps a deterministic 'p-0' id, so the
      // re-parsed chapter passes the restorer's block-order validation.
      final inspected = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'Text/ch1.xhtml',
        bytes: utf8.encode('<p>a</p>'),
      );
      return inspected.copyWith(
        blocks: [
          for (final block in inspected.blocks)
            block.copyWith(sourceHtml: '', sourceText: '', translatedHtml: '<p>译文</p>'),
        ],
        originalHtml: '', body: '', translatedBody: '译文正文',
        sourceIdentity: EpubSourceIdentity(inputPath: epubPath, sha256: fingerprint),
      );
    }

    test('spool-missing restore uses lenient decoding and restores the body', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-spool-');
      addTearDown(() => temp.delete(recursive: true));
      final (epubPath, fingerprint) = await writeMalformedEpub(temp);
      final chapter = releasedChapter(epubPath, fingerprint);
      final spoolDir = Directory('${temp.path}/spool-missing');
      await spoolDir.create();
      final restored = await EpubChapterTranslator.restoreChapterSourcesForTest(chapter, spoolDir);
      expect(restored.blocks.single.sourceHtml, isNotEmpty, reason: '#24 lenient decode must not throw');
      expect(restored.body, isNotEmpty, reason: '#25 body must be restored alongside originalHtml');
    });

    test('release/restore round-trips through the worker isolate', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-spool-rt-');
      addTearDown(() => temp.delete(recursive: true));
      final chapter = _chapter('Body', 'body.xhtml');
      final released = await EpubChapterTranslator.releaseChapterSourcesForTest(chapter, temp);
      expect(released.originalHtml, isEmpty);
      expect(released.body, isEmpty);
      final restored = await EpubChapterTranslator.restoreChapterSourcesForTest(released, temp);
      expect(restored.originalHtml, chapter.originalHtml);
      expect(restored.body, chapter.body);
      expect(restored.blocks.single.sourceHtml, chapter.blocks.single.sourceHtml);
    });
  });

  group('#26 spool restore cancellation', () {
    test('the spool-missing fallback checks cancellation', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-cancel-');
      addTearDown(() => temp.delete(recursive: true));
      final chapter = _chapter('Body', 'body.xhtml').copyWith(
        originalHtml: '', body: '',
        blocks: [
          for (final block in _chapter('Body', 'body.xhtml').blocks)
            block.copyWith(sourceHtml: '', sourceText: ''),
        ],
      );
      await expectLater(
        EpubChapterTranslator.restoreChapterSourcesForTest(
          chapter, temp, isCancelled: () => true),
        throwsA(isA<TranslationCancelledException>()),
      );
    });
  });

  group('#27 underscore-separated structure pages', () {
    test('cover_page.xhtml is excluded from style sampling', () {
      final samples = EpubChapterTranslator.styleProfileSourceChaptersForTest([
        _chapter('Cover', 'Text/cover_page.xhtml'),
        _chapter('Discovery', 'Text/discovery.xhtml'),
        _chapter('Body', 'Text/chapter_one.xhtml', text: 'Long enough body text. ' * 50),
      ]);
      expect(samples.map((s) => s['path']), isNot(contains('Text/cover_page.xhtml')));
      expect(samples.map((s) => s['title']), contains('Discovery'));
    });

    test('prologue_page.xhtml front matter is still recognized', () {
      final samples = EpubChapterTranslator.styleProfileSourceChaptersForTest([
        _chapter('Prologue', 'Text/prologue_page.xhtml')
            .copyWith(category: ChapterCategory.frontMatter),
      ]);
      expect(samples.where((s) => s['role'] == 'frontMatter').map((s) => s['title']),
        contains('Prologue'));
    });
  });

  group('#38 empty block HTML fails only that block', () {
    test('an empty item enters per-block collection, not whole-batch retry', () async {
      final api = _Api();
      final blocks = _chapter('Body', 'body.xhtml',
        text: 'First paragraph.</p><p>Second paragraph.').blocks;
      expect(blocks, hasLength(2));
      api.replies.add({'blocks': [
        {'id': blocks[0].id, 'html': '<p>译文一</p>'},
        {'id': blocks[1].id, 'html': '   '},
      ]});
      final result = await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config), config: config, blocks: blocks,
      );
      expect(result, hasLength(2));
      expect(result.every((html) => html.trim().isNotEmpty), isTrue);
      final batchRequests = api.requests.where((data) {
        final messages = data['messages'] as List;
        return (messages.last['content'] as String).startsWith('{');
      });
      expect(batchRequests, hasLength(1), reason: 'the batch must not be resent as a whole');
      expect(api.individualCalls, 1, reason: 'only the empty block is retried individually');
    });
  });

  group('#39 fenced non-object JSON is deterministic', () {
    test('a fenced array does not retry the batch as syntax jitter', () async {
      final api = _Api();
      api.replies.add('```json\n["not", "an", "object"]\n```');
      await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config), config: config,
        blocks: _chapter('Body', 'body.xhtml').blocks,
      );
      final batchRequests = api.requests.where((data) {
        final messages = data['messages'] as List;
        return (messages.last['content'] as String).startsWith('{');
      });
      expect(batchRequests, hasLength(1), reason: 'no batch-level retry for deterministic content');
      expect(api.individualCalls, 1, reason: 'straight to per-block recovery');
    });
  });

  group('#40 unified DOM entry', () {
    test('a fenced single-block reply decodes through the shared pipeline', () async {
      final api = _Api()..individualReply = '```html\n<p>译文正文</p>\n```';
      // Fail the batch so the flow falls back to the single-block path.
      api.replies.add('garbage not json');
      final result = await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config), config: config,
        blocks: _chapter('Body', 'body.xhtml').blocks,
      );
      expect(api.individualCalls, 1);
      expect(result.single, contains('译文正文'));
      expect(result.single.trim().startsWith('<'), isTrue);
    });
  });

  group('#42 chapter-source release notifies the caller', () {
    test('onChapterSourcesReleased fires for every released chapter', () async {
      final temp = await Directory.systemTemp.createTemp('a-round7-release-cb-');
      addTearDown(() => temp.delete(recursive: true));
      final chapters = [
        _chapter('One', 'OPS/one.xhtml'),
        _chapter('Two', 'OPS/two.xhtml'),
      ];
      final input = File('${temp.path}/book.epub');
      await _writeEpub(input, chapters);
      final cache = TranslationCacheStore(cacheRoot: Directory('${temp.path}/cache'));
      final translator = EpubChapterTranslator(
        cacheStore: cache, apiClient: _Api(), repacker: _Repacker());
      final released = <String>[];
      await translator.translateChapters(
        inputPath: input.path, outputDirectory: temp.path, config: config,
        chapters: chapters, cancelToken: CancelToken(),
        onChapterSourcesReleased: released.add,
      );
      expect(released, containsAll(['OPS/one.xhtml', 'OPS/two.xhtml']));
      await cache.waitForMaintenanceForTest();
    });
  });
}
