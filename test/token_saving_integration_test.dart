import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _chapterCount = 20;
const _omittedSentence = 'The silver lantern cast a steady glow.';
const _sentences = <String, String>{
  _omittedSentence: '银灯投下了稳定的光芒。',
  'Aster Vale closed the wooden shutters before dusk.': '阿斯特谷在黄昏前关上了木百叶窗。',
  'Every shelf held a polished clay cup.': '每个架子上都放着磨光的陶杯。',
  'The river carried fallen leaves past the stone bridge.': '河水载着落叶流过石桥。',
  'Quiet footsteps crossed the empty courtyard.': '轻轻的脚步声穿过空荡的院子。',
  'A woven basket rested near the open doorway.': '一只编织篮放在敞开的门口旁。',
  'The keeper fetched a fresh candle from the pantry.': '守门人从储藏室拿来一支新蜡烛。',
  'The brass bell rang across the meadow.': '铜铃声传遍草地。',
  'Wind stirred the tall grass beyond the wall.': '风吹动了墙外的高草。',
  'The old key turned easily in the lock.': '旧钥匙轻松转动了锁芯。',
  'The sun slowly warmed the stone steps.': '阳光慢慢晒暖了石阶。',
  'An empty wagon stood beside the orchard gate.': '一辆空马车停在果园门边。',
  'The worktable held a row of hand-carved bowls.': '工作台上排着一列手工雕刻的碗。',
  'The baker wrapped the warm loaf in linen.': '面包师用亚麻布裹好温热的面包。',
  'The harbor lamps shimmered on the still water.': '港口的灯光在平静水面上闪烁。',
  'The path wound through a grove of young trees.': '小路蜿蜒穿过一片小树林。',
  'The paper map showed a narrow track through the hills.': '纸地图上画着一条穿过山丘的小路。',
  'The bell rope hung beside the oak door.': '铃绳垂在橡木门旁。',
  'This note records the keeper’s daily duties.': '这条注释记录了守门人的日常职责。',
  'The lantern was still burning.': '灯还亮着。',
  'He waited beside the ': '他在',
  'stone arch': '石拱门',
  ' until dusk.': '旁等到黄昏。',
  'The Lantern Log': '银灯日志',
};

void main() {
  test(
    'token-saving mode reduces wire input while preserving the EPUB',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'token_saving_fixture_',
      );
      addTearDown(() => root.delete(recursive: true));
      final epub = await _writeBook(root);
      final legacy = await _runBook(root, epub, tokenSaving: false);
      final optimized = await _runBook(root, epub, tokenSaving: true);

      _printMeasurement('legacy', legacy);
      _printMeasurement('token-saving', optimized);
      _expectComplete(legacy);
      _expectComplete(optimized);
      expect(
        _readOutputChapters(optimized.result.job.outputPath),
        _readOutputChapters(legacy.result.job.outputPath),
      );
      expect(
        optimized.adapter.promptBytes,
        lessThan(legacy.adapter.promptBytes),
      );
      expect(
        optimized.adapter.requestCount,
        lessThan(legacy.adapter.requestCount),
      );
      expect(legacy.adapter.requestsByKind['chapterMemoryBatch'], isNull);
      expect(
        optimized.adapter.requestsByKind['chapterMemoryBatch'],
        greaterThan(0),
      );
      expect(
        optimized.adapter.memoryRequests,
        lessThan(legacy.adapter.memoryRequests),
      );
      expect(legacy.adapter.bodyRequestsWithUnrelatedGlossary, greaterThan(0));
      expect(optimized.adapter.bodyRequestsWithUnrelatedGlossary, 0);
      expect(optimized.adapter.bodyRequestsWithLockedName, greaterThan(0));
      expect(legacy.adapter.thinkingDisabledBodyRequests, 0);
      expect(optimized.adapter.thinkingDisabledBodyRequests, greaterThan(0));
      expect(optimized.adapter.thinkingDisabledOtherRequests, 0);
      expect(legacy.adapter.omittedBlocks, 1);
      expect(optimized.adapter.omittedBlocks, 1);
      expect(optimized.adapter.repairBlockCounts, [1]);
      expect(optimized.adapter.bodyBlockRetries, 1);
      expect(optimized.adapter.retryBytes, lessThan(legacy.adapter.retryBytes));
    },
  );
}

Future<({TranslationRunResult result, _FixtureAdapter adapter})> _runBook(
  Directory root,
  File epub, {
  required bool tokenSaving,
}) async {
  final runDirectory = await Directory(
    p.join(root.path, tokenSaving ? 'optimized' : 'legacy'),
  ).create();
  final cache = TranslationCacheStore(
    cacheRoot: Directory(p.join(runDirectory.path, 'empty-cache')),
  );
  final adapter = _FixtureAdapter();
  final repository = EpubTranslationRepository(
    cacheStore: cache,
    translator: EpubChapterTranslator(
      cacheStore: cache,
      apiClient: _FixtureClient(adapter),
    ),
  );
  // All requests use the fixture adapter, including documented provider URLs.
  final config = TranslationConfig.defaults().copyWith(
    apiKey: 'offline-fixture',
    chunkSize: 1400,
    maxConcurrent: 2,
    maxRetries: 1,
    retryDelaySeconds: 0,
    styleProfileEnabled: false,
    tokenSavingMode: tokenSaving,
    lockedGlossary: [
      'Aster Vale => 阿斯特谷',
      for (var index = 0; index < 24; index++)
        'Unrelated glossary entry $index => 无关术语$index',
    ].join('\n'),
  );
  try {
    final inspection = await repository.startJob(
      inputPath: epub.path,
      outputDirectory: runDirectory.path,
      config: config,
    );
    expect(inspection.chapters, hasLength(_chapterCount));
    final result = await repository.translateChapters(
      inputPath: epub.path,
      outputDirectory: runDirectory.path,
      config: config,
      chapters: inspection.chapters,
    );
    return (result: result, adapter: adapter);
  } finally {
    await cache.waitForMaintenanceForTest();
  }
}

void _expectComplete(
  ({TranslationRunResult result, _FixtureAdapter adapter}) run,
) {
  final (result: result, adapter: adapter) = run;
  expect(result.job.status, TranslationJobStatus.completed);
  expect(result.job.completedFiles, _chapterCount);
  expect(result.job.completedBlocks, result.job.totalBlocks);
  expect(result.job.degradedBlockCount, 0);
  expect(result.job.apiDegradedBlocks, 0);
  expect(result.job.consistencyWarningCount, 0);
  expect(result.job.apiUsage, result.apiUsage);
  expect(result.apiUsage['requests'], adapter.requestCount);
  expect(result.apiUsage['usageReportedRequests'], adapter.requestCount);
  expect(result.apiUsage['promptTokens'], adapter.promptTokenProxy);
  expect(result.apiUsage['completionTokens'], adapter.completionTokenProxy);
  expect(result.apiUsage['byKind'], adapter.requestsByKind);
  final chapters = _readOutputChapters(result.job.outputPath);
  expect(chapters, hasLength(_chapterCount));
  expect(chapters.first, contains('阿斯特谷'));
  expect(chapters.first, contains('银灯投下了稳定的光芒。'));
  expect(chapters.last, contains('href="#chapter-note"'));
  expect(chapters.last, contains('id="chapter-note"'));
  expect(chapters.last, contains('这条注释记录了守门人的日常职责。'));
  expect(chapters.last, contains('<em>石拱门</em>'));
}

void _printMeasurement(
  String mode,
  ({TranslationRunResult result, _FixtureAdapter adapter}) run,
) {
  final (result: result, adapter: adapter) = run;
  // The fake usage divides serialized message/reply bytes by four to exercise
  // the production usage counters. These values are not provider token counts.
  stdout.writeln(
    jsonEncode({
      'mode': mode,
      'chapters': result.job.completedFiles,
      'blocks': result.job.completedBlocks,
      'requestBodyUtf8Bytes': adapter.totalBytes,
      'promptMessagesUtf8Bytes': adapter.promptBytes,
      'requestBodyBytesByKind': adapter.bytesByKind,
      'requestsByKind': adapter.requestsByKind,
      'fixtureInputTokenProxy': adapter.promptTokenProxy,
      'fixtureOutputTokenProxy': adapter.completionTokenProxy,
      'omittedBlocks': adapter.omittedBlocks,
      'retriedBodyBlocks': adapter.bodyBlockRetries,
      'retryRequestBodyBytes': adapter.retryBytes,
      'repairBlockCounts': adapter.repairBlockCounts,
      'ordinaryBodyCallsWithThinkingDisabled':
          adapter.thinkingDisabledBodyRequests,
      'translationOutputTokenLimits':
          adapter.translationOutputTokenLimits.toList()..sort(),
      'degradedBlocks': result.job.degradedBlockCount,
      'consistencyWarnings': result.job.consistencyWarningCount,
    }),
  );
}

List<String> _readOutputChapters(String outputPath) => [
  for (final entry in ZipDecoder().decodeBytes(
    File(outputPath).readAsBytesSync(),
  ))
    if (RegExp(r'^OPS/chapter-[a-t]\.xhtml$').hasMatch(entry.name))
      utf8.decode(entry.content as List<int>),
];

Future<File> _writeBook(Directory directory) async {
  final archive = Archive()
    ..addFile(
      ArchiveFile.noCompress(
        'mimetype',
        20,
        utf8.encode('application/epub+zip'),
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OPS/book.opf" '
            'media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
    );
  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navigation = StringBuffer();
  final ordinary = _sentences.keys.take(18).toList();
  for (var chapter = 0; chapter < _chapterCount; chapter++) {
    final name = String.fromCharCode('a'.codeUnitAt(0) + chapter);
    manifest.write(
      '<item id="$name" href="chapter-$name.xhtml" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.write('<itemref idref="$name"/>');
    navigation.write(
      '<li><a href="chapter-$name.xhtml">Lantern Passage $name</a></li>',
    );
    final paragraphs = chapter == 0
        ? ordinary.take(5)
        : chapter < 18
        ? List.generate(
            4,
            (index) => ordinary[1 + ((chapter * 4 + index) % 17)],
          )
        : List.generate(32, (index) => ordinary[1 + ((chapter + index) % 17)]);
    final attachedNote = chapter == _chapterCount - 1
        ? '<p>The lantern was still burning.'
              '<a epub:type="noteref" href="#chapter-note">1</a></p>'
              '<p>He waited beside the <em>stone arch</em> until dusk.</p>'
              '<aside epub:type="footnote" id="chapter-note">'
              '<p>This note records the keeper’s daily duties.</p></aside>'
        : '';
    archive.addFile(
      ArchiveFile.string(
        'OPS/chapter-$name.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en"><head>'
            '<title>Lantern Passage $name</title></head><body>'
            '<h1>Lantern Passage $name</h1>'
            '${paragraphs.map((sentence) => '<p>$sentence</p>').join()}'
            '$attachedNote</body></html>',
      ),
    );
  }
  archive
    ..addFile(
      ArchiveFile.string(
        'OPS/nav.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title>'
            '</head><body><nav epub:type="toc"><ol>$navigation</ol></nav></body></html>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:identifier id="book-id">urn:uuid:080fa65a-e140-4d41-ac61-08b64f8deaa2</dc:identifier>'
            '<dc:title>The Lantern Log</dc:title><dc:language>en</dc:language>'
            '<meta property="dcterms:modified">2026-11-20T00:00:00Z</meta></metadata>'
            '<manifest>$manifest<item id="nav" href="nav.xhtml" properties="nav" '
            'media-type="application/xhtml+xml"/></manifest><spine>$spine</spine></package>',
      ),
    );
  return File(
    p.join(directory.path, 'lantern-log.epub'),
  ).writeAsBytes(ZipEncoder().encodeBytes(archive));
}

class _FixtureClient extends TranslationApiClient {
  const _FixtureClient(this.adapter);

  final _FixtureAdapter adapter;

  @override
  Dio buildDio(TranslationConfig config) =>
      super.buildDio(config)..httpClientAdapter = adapter;
}

class _FixtureAdapter implements HttpClientAdapter {
  final requestsByKind = <String, int>{};
  final bytesByKind = <String, int>{};
  final repairBlockCounts = <int>[];
  final translationOutputTokenLimits = <int>{};
  int thinkingDisabledBodyRequests = 0;
  int thinkingDisabledOtherRequests = 0;
  int requestCount = 0;
  int totalBytes = 0;
  int promptBytes = 0;
  int promptTokenProxy = 0;
  int completionTokenProxy = 0;
  int omittedBlocks = 0;
  int _omissionFixtureAttempts = 0;
  int bodyBlockRetries = 0;
  int retryBytes = 0;
  int bodyRequestsWithUnrelatedGlossary = 0;
  int bodyRequestsWithLockedName = 0;

  int get memoryRequests =>
      (requestsByKind['chapterMemory'] ?? 0) +
      (requestsByKind['chapterMemoryBatch'] ?? 0);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in requestStream!) {
      bytes.add(chunk);
    }
    final rawRequest = bytes.takeBytes();
    final request = jsonDecode(utf8.decode(rawRequest)) as Map;
    final messages = request['messages'] as List;
    final user = (messages.last as Map)['content'] as String;
    final kind = options.extra['requestKind'] as String;
    final thinkingDisabled =
        (request['thinking'] as Map?)?['type'] == 'disabled';
    if (kind == 'translation') {
      translationOutputTokenLimits.add(request['max_tokens'] as int);
      if (thinkingDisabled) thinkingDisabledBodyRequests++;
    } else if (thinkingDisabled) {
      thinkingDisabledOtherRequests++;
    }
    final payload = user.startsWith('{') ? jsonDecode(user) as Map : null;
    final priorRetries = bodyBlockRetries;
    final requestBytes = rawRequest.length;
    final response = _reply(kind, payload, user);
    if (bodyBlockRetries > priorRetries) retryBytes += requestBytes;
    if (kind == 'bodyRepair') {
      repairBlockCounts.add((payload!['blocks'] as List).length);
    }
    final serializedMessages = jsonEncode(messages);
    if (kind == 'translation' || kind == 'bodyRepair') {
      if (serializedMessages.contains('Unrelated glossary entry') ||
          serializedMessages.contains('Unrelated memory entry')) {
        bodyRequestsWithUnrelatedGlossary++;
      }
      final blocks = payload?['blocks'];
      final selectedTerms = (payload?['context'] as Map?)?['lockedGlossary'];
      if (blocks is List &&
          blocks.any(
            (block) =>
                ((block as Map)['html'] as String?)?.contains('Aster Vale') ==
                true,
          ) &&
          selectedTerms is List &&
          selectedTerms.whereType<Map>().any(
            (term) =>
                term['source'] == 'Aster Vale' && term['target'] == '阿斯特谷',
          )) {
        bodyRequestsWithLockedName++;
      }
    }
    final content = response is String ? response : jsonEncode(response);
    final messageBytes = utf8.encode(serializedMessages).length;
    final input = (messageBytes / 4).ceil();
    final output = (utf8.encode(content).length / 4).ceil();
    requestCount++;
    totalBytes += requestBytes;
    promptBytes += messageBytes;
    promptTokenProxy += input;
    completionTokenProxy += output;
    requestsByKind.update(kind, (value) => value + 1, ifAbsent: () => 1);
    bytesByKind.update(
      kind,
      (value) => value + requestBytes,
      ifAbsent: () => requestBytes,
    );
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': input, 'completion_tokens': output},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  Object _reply(String kind, Map? payload, String user) {
    switch (kind) {
      case 'initialBookMemory':
        return {
          'bookSummary': 'The keeper dutifully tends the lantern.',
          'styleGuide': ['Retain emphasis and use clear everyday words.'],
          'recentChapters': [],
          'glossary': [
            {'source': 'Aster Vale', 'target': '阿斯特谷'},
            {'source': 'silver lantern', 'target': '银灯'},
            for (var index = 0; index < 18; index++)
              {
                'source': 'Unrelated memory entry $index',
                'target': '无关记忆$index',
              },
          ],
        };
      case 'chapterMemory':
        return _memoryReply(payload?['chapter'] as Map?);
      case 'chapterMemoryBatch':
        final chapters = payload!['chapters'] as List;
        return _memoryReply(chapters.last as Map);
      case 'bookTitle':
        return _translate(user);
    }
    if (payload?['blocks'] case final List blocks) {
      final translated = <Map<String, Object?>>[];
      for (final block in blocks.cast<Map>()) {
        final html = block['html'] as String?;
        if (html != null) {
          _recordBodyAttempt(html);
          if (omittedBlocks == 0 &&
              blocks.length > 1 &&
              html.contains(_omittedSentence)) {
            omittedBlocks++;
            continue;
          }
          translated.add({'id': block['id'], 'html': _translate(html)});
        } else if (block['slots'] case final List slots) {
          translated.add({
            'id': block['id'],
            'slots': [
              for (final slot in slots.cast<Map>())
                {'id': slot['id'], 'text': _translate(slot['text'] as String)},
            ],
          });
        } else if (block['text'] case final String text) {
          _recordBodyAttempt(text);
          translated.add({'id': block['id'], 'text': _translate(text)});
        } else {
          throw StateError('Unexpected fixture block fields ${block.keys}');
        }
      }
      return {'blocks': translated};
    }
    if (kind == 'translation') {
      _recordBodyAttempt(user);
      return _translate(user);
    }
    throw StateError(
      'Unexpected fixture request $kind with fields ${payload?.keys}',
    );
  }

  Map<String, Object?> _memoryReply(Map? chapter) => {
    'title': chapter?['title'] ?? 'Lantern Passage',
    'summary': 'The keeper tends the lantern as the evening approaches.',
    'continuityNotes': ['Retain the established word for lantern.'],
    'glossary': [],
  };

  void _recordBodyAttempt(String source) {
    if (!source.contains(_omittedSentence)) return;
    _omissionFixtureAttempts++;
    if (_omissionFixtureAttempts > 1) bodyBlockRetries++;
  }

  String _translate(String source) {
    for (final entry in _sentences.entries) {
      source = source.replaceAll(entry.key, entry.value);
    }
    return source.replaceAllMapped(
      RegExp(r'Lantern Passage ([a-t])'),
      (match) =>
          '明灯篇${String.fromCharCode(0x7532 + match[1]!.codeUnitAt(0) - 97)}',
    );
  }

  @override
  void close({bool force = false}) {}
}
