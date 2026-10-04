import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart' as xml;

const EpubHtmlExtractor extractor = EpubHtmlExtractor();

void main() {
  group('elementText br handling', () {
    test('br contributes a space instead of gluing words', () {
      final dom.Document document = html_parser.parse(
        '<html><body><p>first<br>second<br/>third</p></body></html>',
      );
      final dom.Element paragraph = document.querySelector('p')!;
      expect(extractor.elementText(paragraph), 'first second third');
    });

    test('sourceHtml is untouched by the br handling', () {
      final dom.Document document = html_parser.parse(
        '<html><body><p>first<br>second</p></body></html>',
      );
      final dom.Element paragraph = document.querySelector('p')!;
      extractor.elementText(paragraph);
      expect(paragraph.outerHtml, contains('<br>'));
    });

    test('plain paragraphs render exactly as before', () {
      final dom.Document document = html_parser.parse(
        '<html><body><p>Hello <b>bold</b> world.</p></body></html>',
      );
      expect(
        extractor.elementText(document.querySelector('p')!),
        'Hello bold world.',
      );
    });
  });

  group('categorizeChapter word boundaries', () {
    test('footnotes in title no longer matches notes', () {
      expect(
        extractor.categorizeChapter('OEBPS/ch7.xhtml', 'Footnotes to History'),
        ChapterCategory.content,
      );
    });

    test('advertisement in title no longer matches advert', () {
      expect(
        extractor.categorizeChapter('OEBPS/ch8.xhtml', 'Advertisement'),
        ChapterCategory.content,
      );
    });

    test('standalone notes title still matches', () {
      expect(
        extractor.categorizeChapter('OEBPS/ch9.xhtml', 'My Notes'),
        ChapterCategory.reference,
      );
    });

    test('path substring matching is unchanged', () {
      expect(
        extractor.categorizeChapter('OEBPS/notes.xhtml', 'Chapter Nine'),
        ChapterCategory.reference,
      );
      expect(
        extractor.categorizeChapter('OEBPS/book_cop_r1.htm', 'Example'),
        ChapterCategory.ancillary,
      );
    });
  });

  group('isProtectedMarkerText page-list markers', () {
    test('Page 12 is protected', () {
      expect(extractor.isProtectedMarkerText('Page 12'), isTrue);
    });

    test('lowercase page with extra spaces is protected', () {
      expect(extractor.isProtectedMarkerText('  page   7 '), isTrue);
    });

    test('ordinary prose is not protected', () {
      expect(extractor.isProtectedMarkerText('Turn the page'), isFalse);
      expect(extractor.isProtectedMarkerText('Homepage'), isFalse);
    });
  });

  group('manifest href decoding', () {
    Map<String, List<int>> opfFiles(String href) {
      return <String, List<int>>{
        'OEBPS/content.opf': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="c1" href="$href" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>'''),
      };
    }

    test('literal percent in href does not fail inspection', () {
      final result = EpubInspector.chapterPathsFromOpfBytes(
        files: opfFiles('100%.xhtml'),
        opfPath: 'OEBPS/content.opf',
      );
      expect(result.chapterPaths, <String>['OEBPS/100%.xhtml']);
      expect(result.unresolvedIdRefs, isEmpty);
    });

    test('unresolved idrefs are reported instead of silently dropped', () {
      final Map<String, List<int>> files = <String, List<int>>{
        'OEBPS/content.opf': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="ghost"/></spine>
</package>'''),
      };
      final result = EpubInspector.chapterPathsFromOpfBytes(
        files: files,
        opfPath: 'OEBPS/content.opf',
      );
      expect(result.chapterPaths, <String>['OEBPS/ch1.xhtml']);
      expect(result.unresolvedIdRefs, <String>['ghost']);
    });
  });

  group('missing chapter warnings', () {
    test('inspect warns about missing files without failing', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_missing_chapter_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File epubFile = File('${temp.path}/damaged.epub');
      await epubFile.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(
              ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
            )
            ..addFile(
              ArchiveFile.string('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="ghost"/>
  </spine>
</package>'''),
            )
            ..addFile(
              ArchiveFile.string('OEBPS/ch1.xhtml', '''
<html><head><title>One</title></head><body><p>Hello</p></body></html>'''),
            ),
        ),
        flush: true,
      );

      final InspectionResult result = await EpubInspector().inspect(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );

      expect(result.chapters, hasLength(1));
      expect(result.chapters.single.path, 'OEBPS/ch1.xhtml');
      expect(result.warnings, hasLength(2));
      expect(
        result.warnings.join(' '),
        allOf(contains('OEBPS/ch2.xhtml'), contains('ghost')),
      );
    });
  });

  group('renderNavigationMetadata', () {
    const String containerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

    const String opfWithoutLanguage = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test</dc:title>
    <dc:identifier id="id">test-id</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="chapter%201.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
  </spine>
</package>''';

    const String ncxXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>One</text></navLabel>
      <content src="chapter%201.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';

    Map<String, List<int>> archiveFiles() => <String, List<int>>{
      'META-INF/container.xml': utf8.encode(containerXml),
      'OEBPS/content.opf': utf8.encode(opfWithoutLanguage),
      'OEBPS/toc.ncx': utf8.encode(ncxXml),
    };

    test('URI-encoded NCX src matches decoded label keys', () {
      final Map<String, String> result =
          EpubIsolateWorker.renderNavigationMetadata(
            archiveFiles: archiveFiles(),
            labelsByPath: const <String, String>{
              'OEBPS/chapter 1.xhtml': 'Translated One',
            },
            languageTag: 'zh-CN',
          );
      expect(result['OEBPS/toc.ncx'], contains('Translated One'));
    });

    test('percent-encoded NCX href resolves to the decoded archive entry', () {
      const String opf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test</dc:title>
    <dc:identifier id="id">test-id</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc%E4%B8%AD.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
  </spine>
</package>''';
      final Map<String, List<int>> files = <String, List<int>>{
        'META-INF/container.xml': utf8.encode(containerXml),
        'OEBPS/content.opf': utf8.encode(opf),
        // Archive entry names are decoded; the OPF href is URI-encoded.
        'OEBPS/toc中.ncx': utf8.encode(ncxXml),
      };
      final Map<String, String> result =
          EpubIsolateWorker.renderNavigationMetadata(
            archiveFiles: files,
            labelsByPath: const <String, String>{},
            languageTag: 'zh-CN',
          );
      expect(result['OEBPS/toc中.ncx'], isNotNull);
    });

    test('missing dc:language is appended instead of skipped', () {
      final Map<String, String> result =
          EpubIsolateWorker.renderNavigationMetadata(
            archiveFiles: archiveFiles(),
            labelsByPath: const <String, String>{},
            languageTag: 'zh-CN',
          );
      final String? opf = result['OEBPS/content.opf'];
      expect(opf, isNotNull);
      final language = xml.XmlDocument.parse(opf!).descendants
          .whereType<xml.XmlElement>()
          .singleWhere((element) => element.name.local == 'language');
      expect(language.innerText, 'zh-CN');
      expect(language.namespaceUri, 'http://purl.org/dc/elements/1.1/');
    });

    test('OPF without any dc namespace declaration stays well-formed', () {
      final Map<String, List<int>> files = archiveFiles();
      files['OEBPS/content.opf'] = utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata>
    <title>Test</title>
  </metadata>
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>''');
      final Map<String, String> result =
          EpubIsolateWorker.renderNavigationMetadata(
            archiveFiles: files,
            labelsByPath: const <String, String>{},
            languageTag: 'zh-CN',
          );
      final String? opf = result['OEBPS/content.opf'];
      expect(opf, contains('zh-CN'));
      expect(() => xml.XmlDocument.parse(opf!), returnsNormally);
    });
  });

  group('HTML TOC label sync', () {
    InspectedChapter chapter({
      required String path,
      required String title,
      required String originalHtml,
      List<ExtractedBlock> blocks = const <ExtractedBlock>[],
    }) {
      return InspectedChapter(
        path: path,
        title: title,
        body: title,
        originalHtml: originalHtml,
        blocks: blocks,
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      );
    }

    test('nested elements inside anchors are preserved', () {
      final String out = EpubRepacker().synchronizeHtmlTocForTest(
        tocPath: 'OEBPS/toc.xhtml',
        tocHtml:
            '<html><body><a href="ch1.xhtml"><span class="pagenum">1</span> One</a></body></html>',
        chapters: <InspectedChapter>[
          chapter(
            path: 'OEBPS/toc.xhtml',
            title: 'Contents',
            originalHtml:
                '<html><body><a href="ch1.xhtml"><span class="pagenum">1</span> One</a></body></html>',
          ),
          chapter(
            path: 'OEBPS/ch1.xhtml',
            title: 'One',
            originalHtml: '<html><body><h1>One</h1></body></html>',
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'h1-1',
                tagName: 'h1',
                sourceHtml: '<h1>One</h1>',
                sourceText: 'One',
                translatedHtml: '<h1>Translated One</h1>',
              ),
            ],
          ),
        ],
      );
      expect(out, contains('<span class="pagenum">1</span>'));
      expect(out, contains('Translated One'));
      expect(out, isNot(contains('> One</a>')));
    });

    test('a "protocols" chapter is not mistaken for a TOC page', () {
      // "Protocols" contains the substring "toc": the old
      // `token.contains('toc')` heuristic rewrote body-text cross-references
      // into chapter titles. Whole-stem / whole-word matching must not.
      final String out = EpubRepacker().synchronizeHtmlTocForTest(
        tocPath: 'OEBPS/protocols.xhtml',
        tocHtml:
            '<html><body><p>See <a href="ch1.xhtml">chapter 1</a> for details.</p></body></html>',
        chapters: <InspectedChapter>[
          chapter(
            path: 'OEBPS/protocols.xhtml',
            title: 'Protocols',
            originalHtml:
                '<html><body><p>See <a href="ch1.xhtml">chapter 1</a> for details.</p></body></html>',
          ),
          chapter(
            path: 'OEBPS/ch1.xhtml',
            title: 'One',
            originalHtml: '<html><body><h1>One</h1></body></html>',
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'h1-1',
                tagName: 'h1',
                sourceHtml: '<h1>One</h1>',
                sourceText: 'One',
                translatedHtml: '<h1>Translated One</h1>',
              ),
            ],
          ),
        ],
      );
      expect(out, contains('>chapter 1</a>'));
      expect(out, isNot(contains('Translated One')));
    });

    test('a genuine "Table of Contents" title still syncs labels', () {
      final String out = EpubRepacker().synchronizeHtmlTocForTest(
        tocPath: 'OEBPS/front.xhtml',
        tocHtml: '<html><body><a href="ch1.xhtml">One</a></body></html>',
        chapters: <InspectedChapter>[
          chapter(
            path: 'OEBPS/front.xhtml',
            title: 'Table of Contents',
            originalHtml:
                '<html><body><a href="ch1.xhtml">One</a></body></html>',
          ),
          chapter(
            path: 'OEBPS/ch1.xhtml',
            title: 'One',
            originalHtml: '<html><body><h1>One</h1></body></html>',
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'h1-1',
                tagName: 'h1',
                sourceHtml: '<h1>One</h1>',
                sourceText: 'One',
                translatedHtml: '<h1>Translated One</h1>',
              ),
            ],
          ),
        ],
      );
      expect(out, contains('Translated One'));
      expect(out, isNot(contains('>One</a>')));
    });

    test('percent-encoded toc hrefs still sync labels', () {
      // `ch%E4%B8%AD.xhtml` must decode to `ch中.xhtml` before path
      // resolution, otherwise the label lookup misses and the TOC keeps the
      // untranslated title.
      final String out = EpubRepacker().synchronizeHtmlTocForTest(
        tocPath: 'OEBPS/toc.xhtml',
        tocHtml:
            '<html><body><a href="ch%E4%B8%AD.xhtml">One</a></body></html>',
        chapters: <InspectedChapter>[
          chapter(
            path: 'OEBPS/toc.xhtml',
            title: 'Contents',
            originalHtml: '<html><body></body></html>',
          ),
          chapter(
            path: 'OEBPS/ch中.xhtml',
            title: 'One',
            originalHtml: '<html><body><h1>One</h1></body></html>',
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'h1-1',
                tagName: 'h1',
                sourceHtml: '<h1>One</h1>',
                sourceText: 'One',
                translatedHtml: '<h1>第一章</h1>',
              ),
            ],
          ),
        ],
      );
      expect(out, contains('第一章'));
      expect(out, isNot(contains('>One</a>')));
    });
  });

  group('repack mimetype fallback', () {
    test(
      'missing mimetype is synthesized as first uncompressed entry',
      () async {
        final Directory temp = await Directory.systemTemp.createTemp(
          'epub_mimetype_fallback_test_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final File input = File('${temp.path}/no-mimetype.epub');
        await input.writeAsBytes(
          ZipEncoder().encodeBytes(
            Archive()..addFile(
              ArchiveFile.string(
                'OEBPS/ch1.xhtml',
                '<html><body><p>hi</p></body></html>',
              ),
            ),
          ),
          flush: true,
        );

        final String tempPath =
            await EpubIsolateWorker.writeTranslatedEpubToTempForTest(
              inputPath: input.path,
              outputFilePath: '${temp.path}/out.epub',
              translatedHtmlByPath: const <String, String>{},
            );
        final Archive archive = ZipDecoder().decodeBytes(
          await File(tempPath).readAsBytes(),
        );
        final List<ArchiveFile> files = archive.files.toList();
        expect(files.first.name, 'mimetype');
        expect(files.first.compression, CompressionType.none);
        expect(
          utf8.decode(files.first.content.toList()),
          'application/epub+zip',
        );
      },
    );

    test('empty mimetype entry is replaced with the standard value', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_mimetype_empty_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File input = File('${temp.path}/empty-mimetype.epub');
      await input.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(ArchiveFile.string('mimetype', ''))
            ..addFile(
              ArchiveFile.string(
                'OEBPS/ch1.xhtml',
                '<html><body><p>hi</p></body></html>',
              ),
            ),
        ),
        flush: true,
      );

      final String tempPath =
          await EpubIsolateWorker.writeTranslatedEpubToTempForTest(
            inputPath: input.path,
            outputFilePath: '${temp.path}/out.epub',
            translatedHtmlByPath: const <String, String>{},
          );
      final Archive archive = ZipDecoder().decodeBytes(
        await File(tempPath).readAsBytes(),
      );
      final List<ArchiveFile> files = archive.files.toList();
      expect(files.first.name, 'mimetype');
      expect(files.first.compression, CompressionType.none);
      expect(utf8.decode(files.first.content.toList()), 'application/epub+zip');
    });

    test('whitespace-padded mimetype entry is normalized', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_mimetype_padded_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File input = File('${temp.path}/padded-mimetype.epub');
      await input.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip\n'))
            ..addFile(
              ArchiveFile.string(
                'OEBPS/ch1.xhtml',
                '<html><body><p>hi</p></body></html>',
              ),
            ),
        ),
        flush: true,
      );

      final String tempPath =
          await EpubIsolateWorker.writeTranslatedEpubToTempForTest(
            inputPath: input.path,
            outputFilePath: '${temp.path}/out.epub',
            translatedHtmlByPath: const <String, String>{},
          );
      final Archive archive = ZipDecoder().decodeBytes(
        await File(tempPath).readAsBytes(),
      );
      final List<ArchiveFile> files = archive.files.toList();
      expect(files.first.name, 'mimetype');
      expect(utf8.decode(files.first.content.toList()), 'application/epub+zip');
    });
  });

  group('NCX encoding sniff at inspection time', () {
    const String opfWithNcx = '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>''';

    Map<String, List<int>> filesWithOpf(String opfXml) {
      return <String, List<int>>{'OEBPS/content.opf': utf8.encode(opfXml)};
    }

    test('ncxPathFromOpfBytes resolves the spine toc reference', () {
      expect(
        EpubInspector.ncxPathFromOpfBytes(
          files: filesWithOpf(opfWithNcx),
          opfPath: 'OEBPS/content.opf',
        ),
        'OEBPS/toc.ncx',
      );
    });

    test('ncxPathFromOpfBytes decodes a percent-encoded href', () {
      const String opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="ncx" href="toc%E4%B8%AD.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>''';
      expect(
        EpubInspector.ncxPathFromOpfBytes(
          files: filesWithOpf(opf),
          opfPath: 'OEBPS/content.opf',
        ),
        'OEBPS/toc中.ncx',
      );
    });

    test('ncxPathFromOpfBytes returns null when no NCX is declared', () {
      const String opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>''';
      expect(
        EpubInspector.ncxPathFromOpfBytes(
          files: filesWithOpf(opf),
          opfPath: 'OEBPS/content.opf',
        ),
        isNull,
      );
    });

    test('non-UTF-8 NCX fails loudly before any paid work', () {
      final Map<String, List<int>> files = filesWithOpf(opfWithNcx);
      files['OEBPS/toc.ncx'] = utf8.encode(
        '<?xml version="1.0" encoding="gbk"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"></ncx>',
      );
      expect(
        () => EpubInspector.validateNavigationEncodings(
          files: files,
          opfPath: 'OEBPS/content.opf',
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException error) => error.message,
            'message',
            contains('Unsupported text encoding'),
          ),
        ),
      );
    });

    test('UTF-8 NCX and missing NCX pass the sniff', () {
      final Map<String, List<int>> files = filesWithOpf(opfWithNcx);
      files['OEBPS/toc.ncx'] = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?><ncx/>',
      );
      expect(
        () => EpubInspector.validateNavigationEncodings(
          files: files,
          opfPath: 'OEBPS/content.opf',
        ),
        returnsNormally,
      );
      // No NCX entry at all: nothing to sniff, must not throw.
      expect(
        () => EpubInspector.validateNavigationEncodings(
          files: filesWithOpf(opfWithNcx),
          opfPath: 'OEBPS/content.opf',
        ),
        returnsNormally,
      );
    });
  });

  group('inspect progress/log localization', () {
    test('Chinese strings replace the hardcoded English log lines', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_inspect_i18n_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File epubFile = File('${temp.path}/book.epub');
      await epubFile.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(
              ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
            )
            ..addFile(
              ArchiveFile.string('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>'''),
            )
            ..addFile(
              ArchiveFile.string('OEBPS/ch1.xhtml', '''
<html><head><title>One</title></head><body><p>Hello</p></body></html>'''),
            ),
        ),
        flush: true,
      );

      final List<String> logs = <String>[];
      final List<String?> currentChapters = <String?>[];
      const AppStrings strings = AppStrings(UiLanguage.chinese);
      final InspectionResult result = await EpubInspector().inspect(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
        strings: strings,
        onProgress: (TranslationJob job, String logLine) {
          logs.add(logLine);
          currentChapters.add(job.currentChapter);
        },
      );

      expect(result.chapters, hasLength(1));
      // The replaced English phrases must not leak through.
      const List<String> englishPhrases = <String>[
        'Opening EPUB:',
        'Located package:',
        'Found ',
        'Indexed chapter',
        'Opening archive',
        'Spine ready',
        'Ready for translation',
        'chapters found',
      ];
      for (final String phrase in englishPhrases) {
        expect(logs.join('\n'), isNot(contains(phrase)), reason: phrase);
        expect(currentChapters, isNot(contains(phrase)), reason: phrase);
      }
      // And the Chinese keys actually render.
      expect(logs.first, strings.inspectLogOpeningEpub('book.epub'));
      expect(
        logs.join('\n'),
        contains(strings.inspectLogLocatedPackage('OEBPS/content.opf')),
      );
      expect(logs.join('\n'), contains(strings.inspectLogFoundChapters(1)));
      expect(currentChapters, contains(strings.inspectProgressReady));
    });
  });
}
