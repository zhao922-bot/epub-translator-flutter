import 'helpers/memory_history_cache.dart';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

const _oldQualitySchema = 'v16-quality-memory-lru';
const _blockSchema = 'v17-structure-repair';
const _source = 'これはまだほんやくされていない文章です。';
const _oldHtml = '<p>$_source</p>';
const _translatedHtml = '<p>这段文字还没有翻译。</p>';

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

String _cacheKey({
  required TranslationConfig config,
  required ExtractedBlock block,
  required String chapterPath,
  required String fingerprint,
  required String qualitySchema,
  String contextIdentity = '',
}) => _hash(
  [
    _blockSchema,
    qualitySchema,
    const TranslationApiClient().normalizedBaseUrl(config.apiBaseUrl),
    config.model.trim(),
    config.targetLanguage.trim(),
    config.lockedGlossary.trim(),
    config.chunkSize,
    config.residualQualityCheck,
    config.styleProfileEnabled,
    'none',
    fingerprint,
    chapterPath,
    if (contextIdentity.isNotEmpty) 'selection-context-v1:$contextIdentity',
    block.id,
    block.sourceHtml,
  ].join('|'),
);

class _MemoryCache extends TranslationCacheStore with MemoryHistoryCache {
  final blocks = <String, String>{};
  final states = <String, JobResumeState>{};
  final reads = <String>[];

  @override
  Future<String?> getBlockTranslation(String cacheKey) async {
    reads.add(cacheKey);
    return blocks[cacheKey];
  }

  @override
  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    blocks[cacheKey] = translatedHtml;
  }

  @override
  Future<JobResumeState?> loadJobState(String jobKey) async => states[jobKey];

  @override
  Future<void> saveJobState(JobResumeState state) async {
    states[state.jobKey] = state;
  }
}

class _Api extends TranslationApiClient {
  int blockCalls = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final user = (data['messages'] as List).last['content'] as String;
    final payload = user.startsWith('{')
        ? jsonDecode(user) as Map<String, dynamic>
        : {'kind': 'bookTitle'};
    final Object reply;
    if (payload['kind'] == 'bookTitle') {
      reply = '边界样本';
    } else if (payload['kind'] == 'initialBookMemory') {
      reply = {'bookSummary': '边界样本', 'glossary': []};
    } else if (payload['kind'] == 'chapterMemory') {
      reply = {'title': '正文', 'summary': '边界样本', 'glossary': []};
    } else {
      blockCalls++;
      reply = {
        'blocks': [
          for (final block in payload['blocks'] as List)
            {'id': block['id'], 'html': _translatedHtml},
        ],
      };
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': reply is String ? reply : jsonEncode(reply)},
          },
        ],
      },
    );
  }
}

class _Repacker extends EpubRepacker {
  final exportedHtml = <String>[];

  @override
  Future<void> writeTranslatedEpub({
    Set<String> reviewChapterPaths = const {},
    Map<String, Object?>? reviewSnapshots,
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    Set<String> degradedBlockIds = const {},
    String? translatedTitle,
    void Function(int completedChapters, int totalChapters)? onProgress,
  }) async {
    exportedHtml.add(chapters.single.blocks.single.translatedHtml!);
    await File(outputFilePath).writeAsString('边界样本');
  }
}

void main() {
  final config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://example.invalid/v1',
    apiKey: 'test-key',
    model: 'test-model',
    targetLanguage: 'Chinese',
    residualQualityCheck: true,
    styleProfileEnabled: false,
    maxRetries: 1,
  );

  test('P2-05 质量身份更新与块结构身份的一致性验证', () {
    const block = ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml: _oldHtml,
      sourceText: _source,
    );
    final current = EpubChapterTranslator.blockCacheKeyForTest(
      config: config,
      block: block,
      chapterPath: 'body.xhtml',
    );
    expect(
      current,
      _cacheKey(
        config: config,
        block: block,
        chapterPath: 'body.xhtml',
        fingerprint: 'test-book',
        qualitySchema: EpubChapterTranslator.qualityCacheSchemaVersion,
      ),
    );
    expect(
      current,
      isNot(
        _cacheKey(
          config: config,
          block: block,
          chapterPath: 'body.xhtml',
          fingerprint: 'test-book',
          qualitySchema: _oldQualitySchema,
        ),
      ),
    );
  });

  test('P2-05 旧版缓存边界样本与当前缓存命中路径一致性验证', () async {
    final temp = await Directory.systemTemp.createTemp('round12-c-p2-05-');
    addTearDown(() => temp.delete(recursive: true));
    final input = File('${temp.path}/book.epub');
    const chapterPath = 'body.xhtml';
    const chapterHtml = '<html><body>$_oldHtml</body></html>';
    final archive = Archive();
    for (final entry in {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf':
          '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>边界样本</dc:title></metadata></package>',
      chapterPath: chapterHtml,
    }.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
    final chapter = const EpubHtmlExtractor()
        .inspectChapterBytes(
          chapterPath: chapterPath,
          bytes: utf8.encode(chapterHtml),
        )
        .copyWith(
          category: ChapterCategory.content,
          includeInTranslation: true,
        );
    final sourceHash = sha256.convert(await input.readAsBytes()).toString();
    String fingerprint(String qualitySchema) => _hash(
      [
        _blockSchema,
        qualitySchema,
        EpubChapterTranslator.normalizeInputPathForCacheForTest(input.path),
        sourceHash,
      ].join('|'),
    );
    final contextIdentity = _hash(jsonEncode([chapterPath]));
    String key(String qualitySchema) => _cacheKey(
      config: config,
      block: chapter.blocks.single,
      chapterPath: chapterPath,
      fingerprint: fingerprint(qualitySchema),
      qualitySchema: qualitySchema,
      contextIdentity: contextIdentity,
    );
    final legacyKey = key(_oldQualitySchema);
    final currentKey = key(EpubChapterTranslator.qualityCacheSchemaVersion);
    final cache = _MemoryCache()..blocks[legacyKey] = _oldHtml;
    final api = _Api();
    final repacker = _Repacker();
    final translator = EpubChapterTranslator(
      cacheStore: cache,
      apiClient: api,
      repacker: repacker,
    );
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: _oldHtml,
        translatedHtml: _oldHtml,
        targetLanguage: 'Chinese',
      )?.kind,
      TranslationResidualKind.longSourceText,
    );

    final first = await translator.translateChapters(
      inputPath: input.path,
      outputDirectory: temp.path,
      config: config,
      chapters: [chapter],
      cancelToken: CancelToken(),
    );
    expect(first.job.cachedBlocks, 0);
    expect(first.job.degradedBlockCount, 0);
    expect(api.blockCalls, 1);
    expect(cache.reads, contains(currentKey));
    expect(cache.reads, isNot(contains(legacyKey)));
    expect(cache.blocks[legacyKey], _oldHtml);
    expect(cache.blocks[currentKey], _translatedHtml);
    expect(repacker.exportedHtml, [_translatedHtml]);

    final repeated = await translator.translateChapters(
      inputPath: input.path,
      outputDirectory: temp.path,
      config: config,
      chapters: [chapter],
      cancelToken: CancelToken(),
    );
    expect(repeated.job.cachedBlocks, 1);
    expect(api.blockCalls, 1);
    expect(repacker.exportedHtml, [_translatedHtml, _translatedHtml]);
  });
}
