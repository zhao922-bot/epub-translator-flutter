import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

class Fixture {
  late Directory dir;
  late HttpServer server;
  late File book;
  late EpubTranslationRepository repo;
  late TranslationConfig config;
  final requests = <Map<String, dynamic>>[];
  bool truncateStyle = false, malformedReview = false;
  int styleCalls = 0;
  String reviewCategory = 'emotion', reviewConfidence = 'high';
  String? reviewQuoteOverride;
  bool omitUsage = false, reviewUnchanged = false;
  List<dynamic> Function(List<Map<String, Object?>>)? reviewItemsOverride;

  Future<void> init({
    int blocks = 2,
    int chunkSize = 3000,
    int reviewLimit = 8,
    String sourcePrefix = '',
  }) async {
    dir = await Directory.systemTemp.createTemp('real_book_fix_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final data =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(data);
      final messages = data['messages'] as List;
      final system = (messages.first as Map)['content'] as String;
      final user = (messages.last as Map)['content'] as String;
      dynamic payload;
      try {
        payload = jsonDecode(user);
      } on FormatException {
        payload = null;
      }
      var finish = 'stop';
      String content;
      if (payload is Map && payload['kind'] == 'styleProfile') {
        styleCalls++;
        if (truncateStyle && styleCalls == 1) {
          finish = 'length';
          content = '{';
        } else {
          content = jsonEncode({
            'primaryGenre': 'literary fiction',
            'tone': 'ironic',
            'confidence': 'high',
            'translationConstraints': [
              'Preserve contrasts and currency units.',
            ],
          });
        }
      } else if (payload is Map && payload['kind'] == 'initialBookMemory') {
        content = jsonEncode({
          'bookSummary': 'A couple exchanges gifts.',
          'styleGuide': ['Preserve emotion.'],
          'glossary': [
            {'source': 'Della', 'target': '德拉'},
            {'source': 'Dell', 'target': '德拉'},
          ],
          'recentChapters': [],
        });
      } else if (payload is Map && payload['kind'] == 'semanticReview') {
        final items = <Map<String, Object?>>[
          for (final item in payload['blocks'] as List)
            {
              'id': malformedReview ? 'unknown' : item['id'],
              'html': reviewUnchanged
                  ? item['draftHtml']
                  : '<p>她先欢喜，接着却伤心地哭喊起来。</p>',
              'category': reviewCategory,
              'confidence': reviewConfidence,
              'sourceQuote': reviewQuoteOverride ?? 'alas',
              'issues': ['The emotional contrast was reversed.'],
            },
        ];
        content = jsonEncode({
          'blocks': reviewItemsOverride?.call(items) ?? items,
        });
      } else if (payload is Map && payload['kind'] == 'chapterMemory') {
        content = jsonEncode({
          'title': 'Story',
          'summary': 'Done',
          'continuityNotes': [],
          'glossary': [],
        });
      } else if (system.startsWith('Translate the book title')) {
        content = '麦琪的礼物';
      } else if (payload is Map && payload['blocks'] is List) {
        content = jsonEncode({
          'blocks': [
            for (final item in payload['blocks'] as List)
              {'id': item['id'], 'html': '<p>她高兴得喜极而泣，欢天喜地。</p>'},
          ],
        });
      } else {
        throw StateError('Unexpected test request shape');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
              'finish_reason': finish,
            },
          ],
          if (!omitUsage)
            'usage': {'prompt_tokens': 10, 'completion_tokens': 20},
        }),
      );
      await request.response.close();
    });
    final story =
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Story</title></head><body>${List.generate(blocks, (i) => '<p>${sourcePrefix}First she screamed with joy; then alas she burst into distress and tears. Scene $i.</p>').join()}</body></html>';
    final files = {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
      'content.opf':
          '<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Gift of the Magi</dc:title><dc:language>en</dc:language></metadata><manifest><item id="story" href="story.xhtml" media-type="application/xhtml+xml"/><item id="license" href="opaque.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="story"/><itemref idref="license"/></spine></package>',
      'toc.ncx':
          '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><docTitle><text>The Gift of the Magi</text></docTitle><navMap><navPoint id="c" playOrder="1"><navLabel><text>Story</text></navLabel><content src="story.xhtml"/></navPoint></navMap></ncx>',
      'story.xhtml': story,
      'opaque.xhtml':
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>THE FULL PROJECT GUTENBERG™ LICENSE</title></head><body><p>*** END OF THE PROJECT GUTENBERG EBOOK THE GIFT OF THE MAGI ***</p><p>Permission and terms.</p></body></html>',
    };
    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile.string(e.key, e.value));
    }
    book = File('${dir.path}/book.epub');
    await book.writeAsBytes(ZipEncoder().encodeBytes(archive));
    repo = EpubTranslationRepository(
      cacheStore: TranslationCacheStore(
        cacheRoot: Directory('${dir.path}/cache'),
      ),
    );
    config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'fixture-key',
      model: 'zai-org/GLM-5.3-Flash',
      semanticQualityCheck: true,
      maxSemanticReviewRequests: reviewLimit,
      chunkSize: chunkSize,
      maxConcurrent: 2,
      timeoutSeconds: 30,
      uiLanguage: UiLanguage.chinese,
    );
  }

  Future<void> dispose() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  }
}

void main() {
  test(
    'cross-file footnotes share review budget without colliding p-1 identities',
    () async {
      final f = Fixture();
      await f.init(reviewLimit: 1);
      addTearDown(f.dispose);
      final translator = EpubChapterTranslator(cacheStore: f.repo.cacheStore);
      final dio = const TranslationApiClient().buildDio(f.config);
      addTearDown(() => dio.close(force: true));
      final refs = [
        for (var i = 0; i < 2; i++)
          FootnoteBlockReference(
            chapterIndex: i,
            chapter: const EpubHtmlExtractor().inspectChapterBytes(
              chapterPath: 'note-$i.xhtml',
              bytes: utf8.encode(
                '<html><head><title>Endnotes</title></head><body><p>First she screamed with joy; then alas she burst into distress and tears.</p></body></html>',
              ),
            ),
            block: const ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>Then alas she cried in distress.</p>',
              sourceText: 'Then alas she cried in distress.',
            ),
          ),
      ];
      final validated = <String, String>{};
      final first = await translator.translateFootnoteBatchForTest(
        dio: dio,
        config: f.config,
        references: refs,
        onValidated: (id, html) async {
          validated[id] = html;
        },
      );
      expect(first, hasLength(2));
      expect(validated, hasLength(1));
      expect(
        first[refs.first.requestId],
        contains('喜极而泣'),
        reason: 'Review suggestions require user approval.',
      );
      expect(first[refs.last.requestId], contains('喜极而泣'));
      final before = f.requests.length;
      validated.clear();
      await translator.translateFootnoteBatchForTest(
        dio: dio,
        config: f.config.copyWith(maxSemanticReviewRequests: 2),
        references: refs,
        onValidated: (id, html) async {
          validated[id] = html;
        },
      );
      expect(validated, hasLength(2));
      expect(
        f.requests.length - before,
        1,
        reason:
            'Both drafts and the completed review survive; only the missing review is requested.',
      );
    },
  );
  test(
    'new controls round-trip safely and unknown APIs keep automatic defaults',
    () {
      final original = TranslationConfig.defaults().copyWith(
        reasoningEffort: ModelReasoningEffort.high,
        maxOutputTokens: 12288,
        semanticQualityCheck: true,
        maxSemanticReviewRequests: 12,
        semanticReviewScope: SemanticReviewScope.all,
        maxSemanticReviewTokens: 128000,
      );
      final restored = TranslationConfig.fromJson(original.toJson());
      expect(restored.reasoningEffort, ModelReasoningEffort.high);
      expect(restored.maxOutputTokens, 12288);
      expect(restored.semanticQualityCheck, isTrue);
      expect(restored.maxSemanticReviewRequests, 12);
      expect(restored.semanticReviewScope, SemanticReviewScope.all);
      expect(restored.maxSemanticReviewTokens, 128000);
      expect(
        TranslationConfig.defaults()
            .copyWith(model: 'custom-model')
            .effectiveReasoningEffort,
        isNull,
      );
      expect(
        TranslationConfig.defaults()
            .copyWith(model: 'zai-org/GLM-5.3-Flash')
            .effectiveReasoningEffort,
        'low',
      );
      final bounded = TranslationConfig.fromJson({
        'maxOutputTokens': 999999,
        'maxSemanticReviewRequests': -1,
      });
      expect(bounded.maxOutputTokens, 32768);
      expect(bounded.maxSemanticReviewRequests, 1);
    },
  );
  test(
    'real transport: GLM retry, semantics, valid NCX, title/style/body cache and complete usage',
    () async {
      final f = Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.truncateStyle = true;
      final inspected = await f.repo.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: f.config,
      );
      final license = inspected.chapters.singleWhere(
        (c) => c.path == 'opaque.xhtml',
      );
      expect(license.includeInTranslation, isFalse);
      final selected = inspected.chapters
          .where((c) => c.includeInTranslation)
          .toList();
      final style = await f.repo.generateStyleProfile(
        config: f.config,
        chapters: selected,
      );
      expect(f.requests, hasLength(2));
      expect(f.requests[0]['max_tokens'], 4096);
      expect(f.requests[1]['max_tokens'], 8192);
      expect(f.requests[0]['reasoning_effort'], 'low');
      // Clicking style generation again is free and must not erase the usage
      // of the first paid generation from the eventual workflow totals.
      await f.repo.generateStyleProfile(config: f.config, chapters: selected);
      expect(f.requests, hasLength(2));
      final logs = <String>[];
      final result = await f.repo.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: f.config,
        chapters: selected,
        confirmedStyleProfile: style,
        onProgress: (_, line) => logs.add(line),
      );
      expect(result.job.status, TranslationJobStatus.completedWithWarnings);
      expect(result.apiUsage['requests'], f.requests.length);
      expect(result.apiUsage['promptTokens'], f.requests.length * 10);
      expect(result.apiUsage['completionTokens'], f.requests.length * 20);
      final zip = ZipDecoder().decodeBytes(
        await File(result.job.outputPath).readAsBytes(),
      );
      final story = utf8.decode(
        zip.findFile('story.xhtml')!.content as List<int>,
      );
      expect(story, isNot(contains('伤心地哭喊')));
      expect(story, contains('喜极而泣'));
      final ncx = XmlDocument.parse(
        utf8.decode(zip.findFile('toc.ncx')!.content as List<int>),
      );
      for (final node in ncx.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'text',
      )) {
        expect(node.getAttribute('xml:lang'), isNull);
      }
      final quality = jsonDecode(
        await File(result.qualityReportPath!).readAsString(),
      );
      expect(quality['complete'], isTrue);
      expect(quality['corrections'], hasLength(2));
      expect(quality['corrections'].first['beforeHtml'], contains('喜极而泣'));
      expect(quality['corrections'].first['afterHtml'], contains('伤心地哭喊'));
      final paid = f.requests.length;
      await f.repo.generateStyleProfile(config: f.config, chapters: selected);
      final bilingual = await f.repo.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: f.config.copyWith(bilingual: true, outputSuffix: '_bi'),
        chapters: selected,
        confirmedStyleProfile: style,
      );
      expect(bilingual.job.status, TranslationJobStatus.completedWithWarnings);
      expect(bilingual.job.cachedBlocks, 2);
      expect(
        f.requests.length,
        paid,
        reason: 'Body, book title and style must all reuse paid results.',
      );
      expect(bilingual.apiUsage['requests'], 0);
    },
  );

  test(
    'review budget preserves paid drafts; resume only reviews missing blocks',
    () async {
      final f = Fixture();
      await f.init(blocks: 3, chunkSize: 1, reviewLimit: 1);
      addTearDown(f.dispose);
      final inspection = await f.repo.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: f.config,
      );
      final selected = inspection.chapters
          .where((c) => c.includeInTranslation)
          .toList();
      final style = await f.repo.generateStyleProfile(
        config: f.config,
        chapters: selected,
      );
      final first = await f.repo.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: f.config,
        chapters: selected,
        confirmedStyleProfile: style,
      );
      expect(first.job.status, TranslationJobStatus.completedWithWarnings);
      final q = jsonDecode(await File(first.qualityReportPath!).readAsString());
      expect(q['requests'], 1);
      expect(q['unreviewed'], hasLength(2));
      int bodyCalls() => f.requests
          .where(
            (r) => ((r['messages'] as List).first as Map)['content']
                .toString()
                .startsWith('You translate EPUB HTML'),
          )
          .length;
      final paidBodies = bodyCalls();
      final done = await f.repo.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: f.config.copyWith(maxSemanticReviewRequests: 3),
        chapters: selected,
        confirmedStyleProfile: style,
      );
      expect(done.job.status, TranslationJobStatus.completedWithWarnings);
      expect(
        bodyCalls(),
        paidBodies,
        reason:
            'Unreviewed blocks reuse saved drafts, not a second translation call.',
      );
      final finalQ = jsonDecode(
        await File(done.qualityReportPath!).readAsString(),
      );
      expect(finalQ['complete'], isTrue);
      expect(finalQ['requests'], 2);
    },
  );

  test('malformed reviewer reply cannot corrupt or certify a draft', () async {
    final f = Fixture();
    await f.init();
    addTearDown(f.dispose);
    f.malformedReview = true;
    final inspection = await f.repo.startJob(
      inputPath: f.book.path,
      outputDirectory: f.dir.path,
      config: f.config,
    );
    final selected = inspection.chapters
        .where((c) => c.includeInTranslation)
        .toList();
    final style = await f.repo.generateStyleProfile(
      config: f.config,
      chapters: selected,
    );
    final result = await f.repo.translateChapters(
      inputPath: f.book.path,
      outputDirectory: f.dir.path,
      config: f.config,
      chapters: selected,
      confirmedStyleProfile: style,
    );
    expect(result.job.status, TranslationJobStatus.completedWithWarnings);
    final q = jsonDecode(await File(result.qualityReportPath!).readAsString());
    expect(q['unreviewed'], hasLength(2));
    expect(q['corrections'], isEmpty);
  });

  test(
    'large style notes do not collapse the body budget or get sent twice',
    () {
      final blocks = List.generate(
        12,
        (i) => ExtractedBlock(
          id: 'p-$i',
          tagName: 'p',
          sourceHtml: '<p>${'x' * 200}</p>',
          sourceText: 'x' * 200,
        ),
      );
      final memory = <String, Object?>{
        'bookSummary': 'x' * 4000,
        'styleProfile': {
          'translationConstraints': ['rule ' * 1000],
        },
        'styleProfileConfirmed': true,
      };
      final batches = const TranslationBatchPlanner().plan(
        pendingBlocks: blocks,
        chapterBlocks: blocks,
        chunkSize: 3000,
        bookMemory: memory,
      );
      expect(batches.length, lessThanOrEqualTo(3));
      for (final batch in batches) {
        final sent = batch.context.toJson()['bookMemory'] as Map;
        expect(sent.containsKey('styleProfile'), isFalse);
        expect(sent['bookSummary'], memory['bookSummary']);
        expect(
          batch.context.bookMemory!['styleProfile'],
          memory['styleProfile'],
        );
      }
    },
  );

  test('publication classifier does not exclude a copyright-themed story', () {
    const extractor = EpubHtmlExtractor();
    final chapter = extractor.inspectChapterBytes(
      chapterPath: 'story.xhtml',
      bytes: utf8.encode(
        '<html><head><title>Copyright and Fair Use</title></head><body><p>A story about licensing and copyright.</p></body></html>',
      ),
    );
    expect(chapter.includeInTranslation, isTrue);
    final header = extractor.inspectChapterBytes(
      chapterPath: 'opaque.xhtml',
      bytes: utf8.encode(
        '<html><head><title>A book</title></head><body><p>The Project Gutenberg eBook of A book</p><p>Release date: 2026.</p></body></html>',
      ),
    );
    expect(header.includeInTranslation, isFalse);
  });

  test(
    'Gutenberg header merged with story remains selectable for style analysis',
    () {
      const extractor = EpubHtmlExtractor();
      for (final body in ['', '<p>A ghost waited in the hall.</p>']) {
        final chapter = extractor.inspectChapterBytes(
          chapterPath: 'opaque-main.xhtml',
          bytes: utf8.encode(
            '<html><head><title>The Canterville Ghost</title></head><body>'
            '<header><h2>The Project Gutenberg eBook of The Canterville Ghost</h2>'
            '<p>Release date: 2004.</p>'
            '<p>*** START OF THE PROJECT GUTENBERG EBOOK THE CANTERVILLE GHOST ***</p>'
            '</header>$body'
            '<p>*** END OF THE PROJECT GUTENBERG EBOOK THE CANTERVILLE GHOST ***</p>'
            '<p>License terms.</p></body></html>',
          ),
        );
        expect(chapter.includeInTranslation, body.isNotEmpty);
        expect(
          chapter.category,
          body.isEmpty ? ChapterCategory.ancillary : ChapterCategory.content,
        );
      }
    },
  );
}
