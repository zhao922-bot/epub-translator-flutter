import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/actionable_error.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_source_guard.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

class AuditCache extends TranslationCacheStore {
  final values = <String, String>{};
  @override
  Future<String?> getBlockTranslation(String key) async => values[key];
  @override
  Future<void> putBlockTranslation(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<JobResumeState?> loadJobState(String key) async => null;
  @override
  Future<void> saveJobState(JobResumeState state) async {}
  @override
  Future<void> clearJobState(String key) async {}
}

Future<File> writeBook(
  Directory dir, {
  String body = '<p>The morning was cold.</p>',
  String chapterName = 'chapter.xhtml',
  String? ncx,
}) async {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/content.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:language>en</dc:language></metadata><manifest><item id="ch" href="${Uri.encodeComponent(chapterName)}" media-type="application/xhtml+xml"/>${ncx == null ? '' : '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'}</manifest><spine${ncx == null ? '' : ' toc="ncx"'}><itemref idref="ch"/></spine></package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/$chapterName',
        '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>Chapter</title></head><body>$body</body></html>',
      ),
    );
  if (ncx != null) archive.addFile(ArchiveFile.string('OPS/toc.ncx', ncx));
  return File(
    '${dir.path}/source.epub',
  ).writeAsBytes(ZipEncoder().encodeBytes(archive));
}

String? language(dom.Element element) {
  dom.Element? current = element;
  while (current != null) {
    final result = current.attributes['xml:lang'] ?? current.attributes['lang'];
    if (result != null) return result;
    current = current.parent;
  }
  return null;
}

void main() {
  test('control: normal XHTML chapter can be inspected and exported', () async {
    final dir = await Directory.systemTemp.createTemp('epub-audit4-control-');
    addTearDown(() => dir.delete(recursive: true));
    final source = await writeBook(
      dir,
      ncx:
          '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint id="one"><navLabel><text>Chapter</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>',
    );
    final inspected = await EpubInspector().inspect(
      inputPath: source.path,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
    );
    expect(inspected.chapters.length, 1);
    await EpubRepacker().writeTranslatedEpub(
      inputPath: source.path,
      outputFilePath: '${dir.path}/output.epub',
      config: TranslationConfig.defaults(),
      chapters: inspected.chapters,
    );
    expect(await File('${dir.path}/output.epub').exists(), isTrue);
  });

  test(
    'malformed NCX must fail inspection before translation can be billed',
    () async {
      final dir = await Directory.systemTemp.createTemp('epub-audit4-ncx-');
      addTearDown(() => dir.delete(recursive: true));
      final source = await writeBook(
        dir,
        ncx: '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap></ncx>',
      );
      Object? inspectionError;
      InspectionResult? inspected;
      try {
        inspected = await EpubInspector().inspect(
          inputPath: source.path,
          outputDirectory: dir.path,
          cancelToken: CancelToken(),
        );
      } catch (caught) {
        inspectionError = caught;
      }
      if (inspected != null) {
        // Establish that the current export cannot handle input accepted above.
        await expectLater(
          EpubRepacker().writeTranslatedEpub(
            inputPath: source.path,
            outputFilePath: '${dir.path}/output.epub',
            config: TranslationConfig.defaults(),
            chapters: inspected.chapters,
          ),
          throwsA(anything),
        );
      }
      expect(
        inspectionError,
        isA<XmlTagException>(),
        reason:
            'Reject the broken NCX before paid translation, not only during export.',
      );
    },
  );

  test(
    'percent-encoded hash in chapter filename resolves to the ZIP entry',
    () async {
      final dir = await Directory.systemTemp.createTemp('epub-audit4-path-');
      addTearDown(() => dir.delete(recursive: true));
      final source = await writeBook(dir, chapterName: 'chapter#1.xhtml');
      final inspected = await EpubInspector().inspect(
        inputPath: source.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      expect(inspected.chapters.map((c) => c.path), ['OPS/chapter#1.xhtml']);
    },
  );

  test('bilingual degraded source must retain its original language', () {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/chapter.xhtml',
      bytes: utf8.encode(
        '<html lang="en" xml:lang="en"><body><p>The morning was cold.</p></body></html>',
      ),
    );
    final block = chapter.blocks.single;
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter.copyWith(
        blocks: [block.copyWith(translatedHtml: block.sourceHtml)],
      ),
      bilingual: true,
      targetLanguage: 'French',
      degradedBlockIds: {
        EpubRepacker.degradedKeyForBlock(
          chapterPath: chapter.path,
          blockId: block.id,
        ),
      },
    );
    final fallback = html
        .parse(output)
        .querySelector('[data-translation="true"]')!;
    expect(fallback.text, 'The morning was cold.');
    expect(language(fallback), 'en');
  });

  test('translated EPUB3 TOC text must override nested original language', () {
    final output = synchronizeEpub3Navigation(
      markup:
          '<html lang="en" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#intro"><span lang="en" xml:lang="en">Introduction</span></a></li></ol></nav></body></html>',
      documentPath: 'OPS/nav.xhtml',
      labelsByPath: {'OPS/chapter.xhtml#intro': '引言'},
      languageTag: 'zh-CN',
    );
    final label = html.parse(output).querySelector('a span')!;
    expect(label.text, '引言');
    expect(language(label), 'zh-CN');
  });

  test(
    'TOC mixed label and page number retain separate languages on repeated sync',
    () {
      var markup =
          '<html lang="en" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><a href="chapter.xhtml">Introduction <span class="pagenum">12</span></a></nav></body></html>';
      for (var pass = 0; pass < 2; pass++) {
        markup = synchronizeEpub3Navigation(
          markup: markup,
          documentPath: 'OPS/nav.xhtml',
          labelsByPath: {'OPS/chapter.xhtml': '引言'},
          languageTag: 'zh-CN',
        );
        final document = html.parse(markup);
        final anchor = document.querySelector('a')!;
        expect(language(anchor.querySelector('[lang="zh-CN"]')!), 'zh-CN');
        expect(language(anchor.querySelector('.pagenum')!), 'en');
        expect(anchor.querySelector('.pagenum')!.text, '12');
        expect(anchor.querySelectorAll('span').length, 2);
      }
    },
  );

  test('source change routes a translation error to reinspection', () {
    final error = ActionableErrorFactory.fromMessage(
      'Translation failed: ${const EpubSourceChangedException()}',
      preferredKind: ActionableErrorKind.retryTranslation,
    );
    expect(error!.actionKind, ActionableErrorKind.retryInspection);
  });

  test(
    'changed zero-block source is rejected before replacing existing output',
    () async {
      final dir = await Directory.systemTemp.createTemp('epub-audit4-empty-');
      addTearDown(() => dir.delete(recursive: true));
      final source = await writeBook(
        dir,
        body: '<img src="cover.png" alt="Cover"/>',
      );
      final repository = EpubTranslationRepository(cacheStore: AuditCache());
      final config = TranslationConfig.defaults();
      final inspected = await repository.startJob(
        inputPath: source.path,
        outputDirectory: dir.path,
        config: config,
      );
      expect(inspected.chapters.single.blocks, isEmpty);
      final selected = inspected.chapters
          .map((c) => c.copyWith(includeInTranslation: true))
          .toList();
      await writeBook(dir);
      final output = await File(
        '${dir.path}/source_translated.epub',
      ).writeAsString('previous completed output');
      await expectLater(
        repository.translateChapters(
          inputPath: source.path,
          outputDirectory: dir.path,
          config: config,
          chapters: selected,
        ),
        throwsA(isA<EpubSourceChangedException>()),
      );
      expect(await output.readAsString(), 'previous completed output');
    },
  );

  for (final changeDuringRun in [false, true]) {
    test(
      'source change is rejected ${changeDuringRun ? 'during translation' : 'before paid translation and style analysis'}',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'epub-audit4-changed-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requests = 0;
        server.listen((request) async {
          requests++;
          if (changeDuringRun && requests == 1) {
            await writeBook(
              dir,
              body:
                  '<p>The morning was cold.</p><p>NEW PARAGRAPH ADDED DURING TRANSLATION.</p>',
            );
          }
          final data =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final payload =
              jsonDecode(
                    ((data['messages'] as List).last as Map)['content']
                        as String,
                  )
                  as Map;
          final Object response;
          if (payload['kind'] == 'initialBookMemory') {
            response = {
              'bookSummary': 'A chapter.',
              'styleGuide': [],
              'glossary': [],
              'recentChapters': [],
            };
          } else if (payload['kind'] == 'chapterMemory') {
            response = {
              'title': 'Chapter',
              'summary': 'A chapter.',
              'continuityNotes': [],
              'glossary': [],
            };
          } else {
            response = {
              'blocks': [
                for (final block in payload['blocks'] as List)
                  {'id': (block as Map)['id'], 'html': '<p>早晨很冷。</p>'},
              ],
            };
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(response)},
                },
              ],
            }),
          );
          await request.response.close();
        });
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'audit-placeholder',
          model: 'audit-model',
          styleProfileEnabled: false,
          residualQualityCheck: false,
          maxConcurrent: 1,
          maxRetries: 1,
        );
        final repository = EpubTranslationRepository(cacheStore: AuditCache());
        final source = await writeBook(dir);
        final inspected = await repository.startJob(
          inputPath: source.path,
          outputDirectory: dir.path,
          config: config,
        );
        // A book editor saves a newer chapter while the user is on the preview page.
        if (!changeDuringRun) {
          await writeBook(
            dir,
            body:
                '<p>The morning was cold.</p><p>NEW PARAGRAPH ADDED AFTER INSPECTION.</p>',
          );
        }
        final output = await File(
          '${dir.path}/source_translated.epub',
        ).writeAsString('previous completed output');
        await expectLater(
          repository.translateChapters(
            inputPath: source.path,
            outputDirectory: dir.path,
            config: config,
            chapters: inspected.chapters,
          ),
          throwsA(isA<EpubSourceChangedException>()),
        );
        expect(
          requests,
          changeDuringRun ? greaterThan(0) : 0,
          reason:
              'Inspection belongs to older file bytes; reinspection must precede any paid requests.',
        );
        expect(await output.readAsString(), 'previous completed output');
        await expectLater(
          repository.generateStyleProfile(
            config: config.copyWith(styleProfileEnabled: true),
            chapters: inspected.chapters,
          ),
          throwsA(isA<EpubSourceChangedException>()),
        );
        if (!changeDuringRun) expect(requests, 0);
        // Reinspection updates the identity and permits translating the new text.
        final fresh = await repository.startJob(
          inputPath: source.path,
          outputDirectory: dir.path,
          config: config,
        );
        expect(fresh.chapters.single.blocks.length, 2);
        final result = await repository.translateChapters(
          inputPath: source.path,
          outputDirectory: dir.path,
          config: config,
          chapters: fresh.chapters,
        );
        final archive = ZipDecoder().decodeBytes(
          await File(result.job.outputPath).readAsBytes(),
        );
        final document = html.parse(
          utf8.decode(
            archive.findFile('OPS/chapter.xhtml')!.content as List<int>,
          ),
        );
        expect(document.querySelectorAll('p').length, 2);
      },
    );
  }
}
