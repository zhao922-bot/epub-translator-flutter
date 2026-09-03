import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repackages selected chapters with zero translatable blocks', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_zero_blocks_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File epubFile = File('${temp.path}/image_only.epub');
    await _writeTestEpub(
      epubFile,
      chapters: const <String, String>{
        'OPS/Text/cover.xhtml': '<img src="cover.jpg" alt=""/>',
      },
    );
    final TranslationConfig config = TranslationConfig.defaults();
    final EpubTranslationRepository repository = EpubTranslationRepository();
    final inspection = await repository.startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
    );
    final chapters = inspection.chapters
        .map((chapter) => chapter.copyWith(includeInTranslation: true))
        .toList();
    expect(chapters, isNotEmpty);
    expect(chapters.expand((chapter) => chapter.blocks), isEmpty);

    final result = await repository.translateChapters(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
      chapters: chapters,
    );

    expect(result.job.status, TranslationJobStatus.completed);
    expect(result.job.totalBlocks, 0);
    expect(result.job.degradedBlockCount, 0);
    expect(result.job.hasExportableEpub, isTrue);
    expect(await File(result.job.outputPath).exists(), isTrue);
  });

  test(
    'cache restoration scans every block before the first API request',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_cache_order_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final List<String> events = <String>[];
      final HttpServer server = await _startFakeTranslationServer(events);
      addTearDown(() => server.close(force: true));
      final _EventRecordingCacheStore cacheStore = _EventRecordingCacheStore(
        events,
      );

      final File epubFile = File('${temp.path}/cache_order.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/01.xhtml': '<p>First chapter.</p>',
          'OPS/Text/02.xhtml': '<p>Second chapter.</p>',
        },
      );
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'cache-order-model-${server.port}',
        chunkSize: 1000,
        maxConcurrent: 1,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository(
        cacheStore: cacheStore,
      );
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      final int firstApiIndex = events.indexWhere(
        (String event) => event != 'cache',
      );
      expect(firstApiIndex, greaterThanOrEqualTo(0));
      expect(
        events.take(firstApiIndex),
        hasLength(
          inspection.chapters.fold<int>(
            0,
            (int sum, chapter) => sum + chapter.blocks.length,
          ),
        ),
      );
      expect(events.take(firstApiIndex), everyElement('cache'));
    },
  );

  test('unreadable job state still allows block cache restoration', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_unreadable_job_state_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final List<String> events = <String>[];
    final HttpServer server = await _startFakeTranslationServer(events);
    addTearDown(() => server.close(force: true));
    final _EventRecordingCacheStore cacheStore = _EventRecordingCacheStore(
      events,
      throwOnLoadJobState: true,
    );
    final File epubFile = File('${temp.path}/broken_state.epub');
    await _writeTestEpub(
      epubFile,
      chapters: const <String, String>{
        'OPS/Text/chapter.xhtml': '<p>Recover me.</p>',
      },
    );
    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'sk-test',
      model: 'broken-state-model-${server.port}',
      chunkSize: 1000,
    );
    final EpubTranslationRepository repository = EpubTranslationRepository(
      cacheStore: cacheStore,
    );
    final inspection = await repository.startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
    );

    final result = await repository.translateChapters(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
      chapters: inspection.chapters,
    );

    expect(result.job.status, TranslationJobStatus.completed);
    expect(events.first, 'cache');
  });

  test(
    'reuses cached translations without extra memory or translation requests',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_cached_performance_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final List<String> requestKinds = <String>[];
      final HttpServer server = await _startFakeTranslationServer(requestKinds);
      addTearDown(() => server.close(force: true));

      final File epubFile = File('${temp.path}/cached_run.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/chapter.xhtml': '<p>Hello.</p><p>World.</p>',
        },
      );

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'cache-performance-model-${server.port}',
        chunkSize: 1000,
        maxConcurrent: 2,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();

      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );
      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, contains('initialBookMemory'));
      expect(requestKinds, contains('blocks'));
      requestKinds.clear();

      final secondRun = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, isEmpty);
      expect(secondRun.job.phase, TranslationJobPhase.translation);
      expect(secondRun.job.hasExportableEpub, isTrue);
    },
  );

  test(
    'partial timeout result is exportable and retries only degraded blocks',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_warning_retry_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File epubFile = File('${temp.path}/partial.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/chapter.xhtml':
              '<p>First paragraph.</p><p>Second paragraph.</p>',
        },
      );
      final List<String> cacheEvents = <String>[];
      final _EventRecordingCacheStore cacheStore = _EventRecordingCacheStore(
        cacheEvents,
      );
      final _SelectiveTimeoutAdapter adapter = _SelectiveTimeoutAdapter(
        timedOutBlockIds: <String>{'p-1'},
      );
      final EpubChapterTranslator translator = EpubChapterTranslator(
        cacheStore: cacheStore,
        apiClient: _ControlledTranslationApiClient(adapter),
      );
      final EpubTranslationRepository repository = EpubTranslationRepository(
        cacheStore: cacheStore,
        translator: translator,
      );
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test/v1',
        apiKey: 'sk-test',
        model: 'warning-retry-${temp.path.hashCode}',
        targetLanguage: 'Chinese',
        chunkSize: 1,
        maxConcurrent: 1,
        maxRetries: 0,
        retryDelaySeconds: 0,
      );
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      final firstRun = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(
        firstRun.job.status,
        TranslationJobStatus.completedWithWarnings,
        reason:
            'requests=${adapter.blockRequestIds}, '
            'degraded=${firstRun.job.degradedBlockCount}, '
            'total=${firstRun.job.totalBlocks}',
      );
      expect(firstRun.job.degradedBlockCount, 1);
      expect(firstRun.job.hasExportableEpub, isTrue);
      expect(cacheStore.translations, hasLength(1));

      adapter
        ..timedOutBlockIds.clear()
        ..blockRequestIds.clear();
      final secondRun = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(adapter.blockRequestIds, <List<String>>[
        <String>['p-1'],
      ]);
      expect(secondRun.job.status, TranslationJobStatus.completed);
      expect(secondRun.job.degradedBlockCount, 0);
    },
  );

  test('all degraded blocks produce a non-exportable failed job', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_all_degraded_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final File epubFile = File('${temp.path}/all_degraded.epub');
    await _writeTestEpub(
      epubFile,
      chapters: const <String, String>{
        'OPS/Text/chapter.xhtml':
            '<p>First paragraph.</p><p>Second paragraph.</p>',
      },
    );
    final _EventRecordingCacheStore cacheStore = _EventRecordingCacheStore(
      <String>[],
    );
    final _SelectiveTimeoutAdapter adapter = _SelectiveTimeoutAdapter(
      timedOutBlockIds: <String>{'p-1', 'p-2'},
    );
    final EpubTranslationRepository repository = EpubTranslationRepository(
      cacheStore: cacheStore,
      translator: EpubChapterTranslator(
        cacheStore: cacheStore,
        apiClient: _ControlledTranslationApiClient(adapter),
      ),
    );
    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'https://api.example.test/v1',
      apiKey: 'sk-test',
      model: 'all-degraded-${temp.path.hashCode}',
      targetLanguage: 'Chinese',
      chunkSize: 1,
      maxConcurrent: 1,
      maxRetries: 0,
      retryDelaySeconds: 0,
    );
    final inspection = await repository.startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
    );

    final result = await repository.translateChapters(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
      chapters: inspection.chapters,
    );

    expect(
      result.job.status,
      TranslationJobStatus.failed,
      reason:
          'requests=${adapter.blockRequestIds}, '
          'degraded=${result.job.degradedBlockCount}, '
          'total=${result.job.totalBlocks}',
    );
    expect(result.job.degradedBlockCount, result.job.totalBlocks);
    expect(result.job.hasExportableEpub, isFalse);
    expect(cacheStore.translations, isEmpty);
  });

  test(
    'skips chapter memory when no later uncached chapter can use it',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_final_memory_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final List<String> requestKinds = <String>[];
      final HttpServer server = await _startFakeTranslationServer(requestKinds);
      addTearDown(() => server.close(force: true));

      final File epubFile = File('${temp.path}/single_chapter.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/chapter.xhtml': '<p>Only chapter.</p>',
        },
      );

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'single-chapter-performance-model-${server.port}',
        chunkSize: 1000,
        maxConcurrent: 2,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, contains('initialBookMemory'));
      expect(requestKinds, contains('blocks'));
      expect(requestKinds, isNot(contains('chapterMemory')));
    },
  );

  test(
    'batches duplicate p-1 footnotes across files and reuses their caches',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_footnote_batch_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final _FootnoteFakeServer server = await _FootnoteFakeServer.start(
        reverseResponses: true,
      );
      addTearDown(server.close);

      final File epubFile = File('${temp.path}/footnotes.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/01-fn.xhtml':
              '<p id="note-1">Footnote one. <a href="chapter.xhtml#ref-1">Back</a></p>',
          'OPS/Text/02-fn.xhtml':
              '<p id="note-2">Footnote two. <a href="chapter.xhtml#ref-2">Back</a></p>',
          'OPS/Text/03-fn.xhtml':
              '<p id="note-3">Footnote three. <a href="chapter.xhtml#ref-3">Back</a></p>',
        },
      );

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'footnote-batch-model-${server.port}',
        targetLanguage: 'Chinese',
        chunkSize: 5000,
        maxConcurrent: 2,
        maxRetries: 1,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      expect(
        inspection.chapters.map((chapter) => chapter.blocks.single.id),
        <String>['p-1', 'p-1', 'p-1'],
      );
      final List<String> progressLogs = <String>[];
      final firstRun = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
        onProgress: (_, String logLine) => progressLogs.add(logLine),
      );

      expect(
        server.totalRequests,
        1,
        reason: 'A pure footnote run must not request initial book memory.',
      );
      expect(
        progressLogs.any(
          (String logLine) =>
              RegExp(r'book memory .* across 0 requests').hasMatch(logLine),
        ),
        isTrue,
        reason: 'No-op memory preparation must not increment request metrics.',
      );
      expect(server.blockRequestIds, <List<String>>[
        <String>['f0:p-1', 'f1:p-1', 'f2:p-1'],
      ]);
      final String first = await _readXhtml(
        firstRun.job.outputPath,
        'OPS/Text/01-fn.xhtml',
      );
      final String second = await _readXhtml(
        firstRun.job.outputPath,
        'OPS/Text/02-fn.xhtml',
      );
      final String third = await _readXhtml(
        firstRun.job.outputPath,
        'OPS/Text/03-fn.xhtml',
      );
      expect(first, contains('脚注甲'));
      expect(second, contains('脚注乙'));
      expect(third, contains('脚注丙'));
      expect(first, contains('id="note-1"'));
      expect(second, contains('href="chapter.xhtml#ref-2"'));
      expect(third, contains('id="note-3"'));

      server.resetRequests();
      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(server.totalRequests, 0);
      expect(server.blockRequestIds, isEmpty);
    },
  );

  test(
    'protected cross-file footnotes use one shuffled slot request and source skeletons',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_protected_slot_batch_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final _FootnoteFakeServer server = await _FootnoteFakeServer.start(
        reverseResponses: true,
      );
      addTearDown(server.close);
      final File epubFile = File('${temp.path}/protected_slots.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/01-fn.xhtml':
              '<p id="body">x<a href="notes.xhtml#n"><span class="FOOTNOTE_REF small">A</span></a>y</p>',
          'OPS/Text/02-fn.xhtml':
              '<p id="note-1">z<a href="chapter.xhtml#ref"><span class="Footnote_Num dropcap">1</span></a>w</p>',
        },
      );
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'protected-slot-model-${server.port}',
        targetLanguage: 'Chinese',
        chunkSize: 5000,
        maxRetries: 1,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      final result = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(server.totalRequests, 1);
      expect(server.blockRequestIds, <List<String>>[
        <String>['f0:p-1', 'f1:p-1'],
      ]);
      final Map<String, dynamic> payload = server.blockPayloads.single;
      final List<Map<String, dynamic>> blocks =
          (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        blocks.map((Map<String, dynamic> block) => block.keys.toSet()),
        everyElement(<String>{'id', 'slots'}),
      );
      expect(jsonEncode(payload), isNot(contains('notes.xhtml#n')));
      expect(jsonEncode(payload), isNot(contains('chapter.xhtml#ref')));
      expect(jsonEncode(payload), isNot(contains('<a')));

      final String body = await _readXhtml(
        result.job.outputPath,
        'OPS/Text/01-fn.xhtml',
      );
      final String note = await _readXhtml(
        result.job.outputPath,
        'OPS/Text/02-fn.xhtml',
      );
      expect(body, contains('href="notes.xhtml#n"'));
      expect(body, contains('class="FOOTNOTE_REF small"'));
      expect(body, contains('>A</span>'));
      expect(note, contains('href="chapter.xhtml#ref"'));
      expect(note, contains('class="Footnote_Num dropcap"'));
      expect(note, contains('>1</span>'));
      expect(body, contains('&lt;script&gt;'));
      expect(note, contains('&lt;script&gt;'));
      expect(body, isNot(contains('<script>')));
      expect(note, isNot(contains('<script>')));
    },
  );

  test(
    'CJK chapter preparation keeps class-only footnote markers on the slot path',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_cjk_protected_slot_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final _FootnoteFakeServer server = await _FootnoteFakeServer.start();
      addTearDown(server.close);
      final File epubFile = File('${temp.path}/cjk_protected_slot.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/chapter.xhtml':
              '<p>x<a href="notes.xhtml#n"><span class="FOOTNOTE_REF small">A</span></a>y</p>',
        },
      );
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'cjk-protected-slot-model-${server.port}',
        targetLanguage: 'Chinese',
        chunkSize: 5000,
        maxRetries: 1,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      final result = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      final Map<String, dynamic> payload = server.blockPayloads.single;
      final Map<String, dynamic> block =
          (payload['blocks'] as List<dynamic>).single as Map<String, dynamic>;
      expect(block.keys.toSet(), <String>{'id', 'slots'});
      expect(jsonEncode(payload), isNot(contains('<a')));
      expect(jsonEncode(payload), isNot(contains('href')));
      expect(jsonEncode(payload), isNot(contains('notes.xhtml#n')));
      final String chapter = await _readXhtml(
        result.job.outputPath,
        'OPS/Text/chapter.xhtml',
      );
      expect(chapter, contains('href="notes.xhtml#n"'));
      expect(chapter, contains('class="FOOTNOTE_REF small"'));
      expect(chapter, contains('>A</span>'));
    },
  );

  test(
    'isolates malformed multi-footnote ids with verified split requests',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_footnote_bad_ids_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final _FootnoteFakeServer server = await _FootnoteFakeServer.start(
        duplicateMultiResponseId: true,
      );
      addTearDown(server.close);

      final File epubFile = File('${temp.path}/footnotes_bad_ids.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/01-fn.xhtml':
              '<p>Footnote one. <a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
          'OPS/Text/02-fn.xhtml':
              '<p>Footnote two. <a href="chapter.xhtml#footnote_ref_2" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
          'OPS/Text/03-fn.xhtml':
              '<p>Footnote three. <a href="chapter.xhtml#footnote_ref_3" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        },
      );
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'footnote-bad-ids-model-${server.port}',
        targetLanguage: 'Chinese',
        chunkSize: 5000,
        maxRetries: 1,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      final result = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(result.job.status, TranslationJobStatus.completed);
      expect(server.blockRequestIds, <List<String>>[
        <String>['f0:p-1', 'f1:p-1', 'f2:p-1'],
        <String>['f0:p-1'],
        <String>['f1:p-1', 'f2:p-1'],
        <String>['f1:p-1'],
        <String>['f2:p-1'],
      ]);
      expect(
        server.blockRequestIds,
        everyElement(
          predicate<List<String>>(
            (List<String> ids) => ids.toSet().length == ids.length,
            'contains only unique request ids',
          ),
        ),
      );

      server.resetRequests();
      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );
      expect(server.blockRequestIds, isEmpty);
    },
  );

  test('persists one recoverable checkpoint after a footnote batch', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_footnote_checkpoint_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final _FootnoteFakeServer server = await _FootnoteFakeServer.start();
    addTearDown(server.close);
    final _RecordingCheckpointCacheStore cacheStore =
        _RecordingCheckpointCacheStore();

    final File epubFile = File('${temp.path}/footnote_checkpoint.epub');
    await _writeTestEpub(
      epubFile,
      chapters: const <String, String>{
        'OPS/Text/01-fn.xhtml':
            '<p>Footnote one. <a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        'OPS/Text/02-fn.xhtml':
            '<p>Footnote two. <a href="chapter.xhtml#footnote_ref_2" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        'OPS/Text/03-fn.xhtml':
            '<p>Footnote three. <a href="chapter.xhtml#footnote_ref_3" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
      },
    );
    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'sk-test',
      model: 'footnote-checkpoint-model-${server.port}',
      targetLanguage: 'Chinese',
      chunkSize: 5000,
      maxRetries: 1,
    );
    final EpubTranslationRepository repository = EpubTranslationRepository(
      cacheStore: cacheStore,
    );
    final inspection = await repository.startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
    );

    await repository.translateChapters(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
      chapters: inspection.chapters,
    );

    expect(
      cacheStore.savedStates.where(
        (JobResumeState state) =>
            state.completedBlocks > 0 && state.completedBlocks < 3,
      ),
      isEmpty,
      reason:
          'A multi-block batch should not force one job-state flush per block.',
    );
    expect(
      cacheStore.savedStates.any(
        (JobResumeState state) =>
            state.status == 'running' && state.completedBlocks == 3,
      ),
      isTrue,
      reason: 'The completed batch must be recoverable before EPUB repacking.',
    );
  });

  test('413 fallback keeps every global footnote request id unique', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_footnote_413_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final _FootnoteFakeServer server = await _FootnoteFakeServer.start(
      rejectMultiBlockWith413: true,
    );
    addTearDown(server.close);
    final _RecordingCheckpointCacheStore cacheStore =
        _RecordingCheckpointCacheStore();

    final File epubFile = File('${temp.path}/footnotes_413.epub');
    await _writeTestEpub(
      epubFile,
      chapters: const <String, String>{
        'OPS/Text/01-fn.xhtml':
            '<p>Footnote one. <a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        'OPS/Text/02-fn.xhtml':
            '<p>Footnote two. <a href="chapter.xhtml#footnote_ref_2" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        'OPS/Text/03-fn.xhtml':
            '<p>Footnote three. <a href="chapter.xhtml#footnote_ref_3" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
      },
    );
    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'sk-test',
      model: 'footnote-413-model-${server.port}',
      targetLanguage: 'Chinese',
      chunkSize: 5000,
      maxRetries: 1,
    );
    final EpubTranslationRepository repository = EpubTranslationRepository(
      cacheStore: cacheStore,
    );
    final inspection = await repository.startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
    );

    await repository.translateChapters(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
      chapters: inspection.chapters,
    );

    expect(server.blockRequestIds.map((List<String> ids) => ids.length), <int>[
      3,
      1,
      2,
      1,
      1,
    ]);
    expect(
      server.blockRequestIds
          .where((List<String> ids) => ids.length == 1)
          .expand((List<String> ids) => ids),
      <String>['f0:p-1', 'f1:p-1', 'f2:p-1'],
    );
    expect(
      server.blockRequestIds,
      everyElement(
        predicate<List<String>>(
          (List<String> ids) => ids.toSet().length == ids.length,
          'contains only unique request ids',
        ),
      ),
    );
    expect(
      cacheStore.savedStates.where(
        (JobResumeState state) =>
            state.completedBlocks > 0 && state.completedBlocks < 3,
      ),
      isEmpty,
      reason: '413 fallback must checkpoint once after the planned batch.',
    );
  });

  test(
    'single oversized footnote preserves 413 without resending it',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_single_footnote_413_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final _FootnoteFakeServer server = await _FootnoteFakeServer.start(
        rejectAllBlocksWith413: true,
      );
      addTearDown(server.close);

      final File epubFile = File('${temp.path}/single_footnote_413.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/01-fn.xhtml': '<p>One oversized footnote.</p>',
        },
      );
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'single-footnote-413-model-${server.port}',
        targetLanguage: 'Chinese',
        chunkSize: 1,
        maxRetries: 1,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      await expectLater(
        repository.translateChapters(
          inputPath: epubFile.path,
          outputDirectory: temp.path,
          config: config,
          chapters: inspection.chapters,
        ),
        throwsA(
          isA<DioException>().having(
            (DioException error) => error.response?.statusCode,
            'statusCode',
            HttpStatus.requestEntityTooLarge,
          ),
        ),
      );

      expect(server.totalRequests, 1);
      expect(server.blockRequestIds, <List<String>>[
        <String>['f0:p-1'],
      ]);
    },
  );
}

class _RecordingCheckpointCacheStore extends TranslationCacheStore {
  final List<JobResumeState> savedStates = <JobResumeState>[];

  @override
  Future<void> saveJobState(JobResumeState state) async {
    savedStates.add(state);
    await super.saveJobState(state);
  }
}

class _EventRecordingCacheStore extends TranslationCacheStore {
  _EventRecordingCacheStore(this.events, {this.throwOnLoadJobState = false});

  final List<String> events;
  final bool throwOnLoadJobState;
  final Map<String, String> translations = <String, String>{};
  JobResumeState? jobState;

  @override
  Future<String?> getBlockTranslation(String cacheKey) async {
    events.add('cache');
    return translations[cacheKey];
  }

  @override
  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    translations[cacheKey] = translatedHtml;
  }

  @override
  Future<JobResumeState?> loadJobState(String jobKey) async {
    if (throwOnLoadJobState) {
      throw const FormatException('corrupt job state');
    }
    return jobState;
  }

  @override
  Future<void> saveJobState(JobResumeState state) async {
    jobState = state;
  }
}

class _ControlledTranslationApiClient extends TranslationApiClient {
  const _ControlledTranslationApiClient(this.adapter);

  final HttpClientAdapter adapter;

  @override
  Dio buildDio(TranslationConfig config) {
    return Dio(BaseOptions(baseUrl: config.apiBaseUrl))
      ..httpClientAdapter = adapter;
  }
}

class _SelectiveTimeoutAdapter implements HttpClientAdapter {
  _SelectiveTimeoutAdapter({required this.timedOutBlockIds});

  final Set<String> timedOutBlockIds;
  final List<List<String>> blockRequestIds = <List<String>>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final BytesBuilder bytes = BytesBuilder();
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        bytes.add(chunk);
      }
    }
    final Map<String, dynamic> request =
        jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
    final List<dynamic> messages = request['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    final String kind = payload['kind'] as String? ?? 'blocks';
    final Object responsePayload;
    if (kind == 'initialBookMemory') {
      responsePayload = <String, Object?>{
        'bookSummary': 'A short test book.',
        'styleGuide': <Object?>[],
        'glossary': <Object?>[],
        'recentChapters': <Object?>[],
      };
    } else if (kind == 'chapterMemory') {
      responsePayload = <String, Object?>{
        'title': 'Chapter',
        'summary': 'A translated chapter.',
        'continuityNotes': <Object?>[],
        'glossary': <Object?>[],
      };
    } else {
      final List<Map<String, dynamic>> blocks =
          (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
      final List<String> ids = blocks
          .map((Map<String, dynamic> block) => block['id'] as String)
          .toList(growable: false);
      blockRequestIds.add(ids);
      if (ids.any(timedOutBlockIds.contains)) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
          message: 'simulated connection timeout',
        );
      }
      responsePayload = <String, Object?>{
        'blocks': blocks
            .map(
              (Map<String, dynamic> block) => <String, Object?>{
                'id': block['id'],
                'html': '<p>译文。</p>',
              },
            )
            .toList(growable: false),
      };
    }

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(responsePayload),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _FootnoteFakeServer {
  _FootnoteFakeServer._(
    this._server, {
    required this.reverseResponses,
    required this.rejectMultiBlockWith413,
    required this.duplicateMultiResponseId,
    required this.rejectAllBlocksWith413,
  });

  final HttpServer _server;
  final bool reverseResponses;
  final bool rejectMultiBlockWith413;
  final bool duplicateMultiResponseId;
  final bool rejectAllBlocksWith413;
  final List<List<String>> blockRequestIds = <List<String>>[];
  final List<Map<String, dynamic>> blockPayloads = <Map<String, dynamic>>[];
  int totalRequests = 0;

  int get port => _server.port;

  static Future<_FootnoteFakeServer> start({
    bool reverseResponses = false,
    bool rejectMultiBlockWith413 = false,
    bool duplicateMultiResponseId = false,
    bool rejectAllBlocksWith413 = false,
  }) async {
    final HttpServer httpServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FootnoteFakeServer server = _FootnoteFakeServer._(
      httpServer,
      reverseResponses: reverseResponses,
      rejectMultiBlockWith413: rejectMultiBlockWith413,
      duplicateMultiResponseId: duplicateMultiResponseId,
      rejectAllBlocksWith413: rejectAllBlocksWith413,
    );
    httpServer.listen(server._handle);
    return server;
  }

  Future<void> close() => _server.close(force: true);

  void resetRequests() {
    totalRequests = 0;
    blockRequestIds.clear();
    blockPayloads.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    totalRequests += 1;
    final String rawBody = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> requestBody =
        jsonDecode(rawBody) as Map<String, dynamic>;
    final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    final String kind = payload['kind'] as String? ?? 'blocks';

    if (kind != 'blocks') {
      final Object responsePayload = kind == 'initialBookMemory'
          ? <String, Object?>{
              'bookSummary': 'A book with three footnotes.',
              'styleGuide': <Object?>[],
              'glossary': <Object?>[],
              'recentChapters': <Object?>[],
            }
          : <String, Object?>{
              'title': 'Footnote',
              'summary': 'A translated footnote.',
              'continuityNotes': <Object?>[],
              'glossary': <Object?>[],
            };
      await _writeChatResponse(request.response, responsePayload);
      return;
    }

    final List<Map<String, dynamic>> blocks =
        (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
    blockPayloads.add(payload);
    final List<String> ids = blocks
        .map((Map<String, dynamic> block) => block['id'] as String)
        .toList();
    blockRequestIds.add(ids);
    if (rejectAllBlocksWith413 ||
        (rejectMultiBlockWith413 && blocks.length > 1)) {
      request.response.statusCode = HttpStatus.requestEntityTooLarge;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, String>{'error': 'too large'}),
      );
      await request.response.close();
      return;
    }

    if (duplicateMultiResponseId && blocks.length > 1) {
      final String duplicateId = blocks.first['id'] as String;
      await _writeChatResponse(request.response, <String, Object?>{
        'blocks': blocks
            .map(
              (Map<String, dynamic> block) => block.containsKey('slots')
                  ? <String, Object?>{
                      'id': duplicateId,
                      'slots': _translatedSlots(block),
                    }
                  : <String, Object?>{
                      'id': duplicateId,
                      'html': _translatedFootnoteHtml(duplicateId),
                    },
            )
            .toList(),
      });
      return;
    }

    Iterable<Map<String, dynamic>> responseBlocks = blocks;
    if (reverseResponses) {
      responseBlocks = responseBlocks.toList().reversed;
    }
    await _writeChatResponse(request.response, <String, Object?>{
      'blocks': responseBlocks.map((Map<String, dynamic> block) {
        final String id = block['id'] as String;
        return block.containsKey('slots')
            ? <String, Object?>{'id': id, 'slots': _translatedSlots(block)}
            : <String, Object?>{'id': id, 'html': _translatedFootnoteHtml(id)};
      }).toList(),
    });
  }

  static List<Map<String, String>> _translatedSlots(
    Map<String, dynamic> block,
  ) {
    final String id = block['id'] as String;
    return (block['slots'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((Map<String, dynamic> slot) {
          final String slotId = slot['id'] as String;
          final String text = switch ((id, slotId)) {
            ('f0:p-1', 's0') => '正文甲',
            ('f0:p-1', 's1') => '<script>alert("body")</script>正文乙',
            ('f1:p-1', 's0') => '<script>alert("note")</script>脚注乙',
            ('f2:p-1', 's0') => '脚注丙',
            _ => '脚注译文',
          };
          return <String, String>{'id': slotId, 'text': text};
        })
        .toList(growable: false);
  }

  static String _translatedFootnoteHtml(String id) {
    return switch (id) {
      'f0:p-1' => '<p id="note-1">脚注甲。<a href="chapter.xhtml#ref-1">返回</a></p>',
      'f1:p-1' => '<p id="note-2">脚注乙。<a href="chapter.xhtml#ref-2">返回</a></p>',
      'f2:p-1' => '<p id="note-3">脚注丙。<a href="chapter.xhtml#ref-3">返回</a></p>',
      _ => '<p>脚注译文。</p>',
    };
  }

  static Future<void> _writeChatResponse(
    HttpResponse response,
    Object payload,
  ) async {
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': jsonEncode(payload)},
          },
        ],
      }),
    );
    await response.close();
  }
}

Future<HttpServer> _startFakeTranslationServer(
  List<String> requestKinds,
) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest request) async {
    final String rawBody = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> requestBody =
        jsonDecode(rawBody) as Map<String, dynamic>;
    final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    final String kind = payload['kind'] as String? ?? 'blocks';
    requestKinds.add(kind);

    final Object responsePayload = switch (kind) {
      'initialBookMemory' => <String, Object?>{
        'bookSummary': 'A tiny test book.',
        'styleGuide': <Object?>[],
        'glossary': <Object?>[],
        'recentChapters': <Object?>[],
      },
      'chapterMemory' => <String, Object?>{
        'title': 'Chapter',
        'summary': 'The chapter was translated.',
        'continuityNotes': <Object?>[],
        'glossary': <Object?>[],
      },
      _ => <String, Object?>{
        'blocks': (payload['blocks'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(
              (Map<String, dynamic> block) => <String, Object?>{
                'id': block['id'],
                'html': '<p>Translated ${block['id']}</p>',
              },
            )
            .toList(),
      },
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(responsePayload),
            },
          },
        ],
      }),
    );
    await request.response.close();
  });
  return server;
}

Future<void> _writeTestEpub(
  File epubFile, {
  required Map<String, String> chapters,
}) async {
  final Archive archive = Archive()
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
    );

  final String manifest = chapters.keys
      .map((String path) {
        final String id = path.split('/').last.replaceAll('.', '-');
        final String href = path.replaceFirst('OPS/', '');
        return '<item id="$id" href="$href" media-type="application/xhtml+xml"/>';
      })
      .join('\n    ');
  final String spine = chapters.keys
      .map((String path) {
        final String id = path.split('/').last.replaceAll('.', '-');
        return '<itemref idref="$id"/>';
      })
      .join('\n    ');
  archive.addFile(
    ArchiveFile.string('OPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    $manifest
  </manifest>
  <spine>
    $spine
  </spine>
</package>
'''),
  );

  for (final MapEntry<String, String> entry in chapters.entries) {
    archive.addFile(
      ArchiveFile.string(entry.key, '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body>${entry.value}</body>
</html>
'''),
    );
  }

  await epubFile.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
}

Future<String> _readXhtml(String epubPath, String entryPath) async {
  final Archive archive = ZipDecoder().decodeBytes(
    await File(epubPath).readAsBytes(),
  );
  final ArchiveFile? entry = archive.findFile(entryPath);
  if (entry == null) {
    throw StateError('Missing EPUB entry: $entryPath');
  }
  return utf8.decode(entry.content as List<int>);
}
