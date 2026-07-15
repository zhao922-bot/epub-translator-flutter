import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  test('inspection resolves URL-encoded OPF hrefs to archive paths', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_inspection_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File epubFile = File('${temp.path}/encoded_href.epub');
    await epubFile.writeAsBytes(
      ZipEncoder().encodeBytes(
        Archive()
          ..addFile(
            ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
          )
          ..addFile(
            ArchiveFile.string('OPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="chapter-1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter-1"/>
  </spine>
</package>
'''),
          )
          ..addFile(
            ArchiveFile.string('OPS/Text/chapter 1.xhtml', '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body><p>Hello world.</p></body>
</html>
'''),
          ),
      ),
      flush: true,
    );

    final result = await EpubTranslationRepository().startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: TranslationConfig.defaults(),
    );

    expect(result.chapters, hasLength(1));
    expect(result.chapters.single.path, 'OPS/Text/chapter 1.xhtml');
    expect(result.chapters.single.blocks.single.sourceText, 'Hello world.');
  });

  test('inspection extracts real prose from pagebreak spans', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_pagebreak_span_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File epubFile = File('${temp.path}/pagebreak_span.epub');
    await epubFile.writeAsBytes(
      ZipEncoder().encodeBytes(
        Archive()
          ..addFile(
            ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
          )
          ..addFile(
            ArchiveFile.string('OPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="chapter-1" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter-1"/>
  </spine>
</package>
'''),
          )
          ..addFile(
            ArchiveFile.string('OPS/Text/chapter.xhtml', '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body>
    <span epub:type="pagebreak" role="doc-pagebreak">This pagebreak span contains real body prose with many English words.</span>
    <p>Before <span epub:type="pagebreak" role="doc-pagebreak">the split sentence continues here with real prose</span> after.</p>
    <span epub:type="pagebreak" role="doc-pagebreak">12</span>
  </body>
</html>
'''),
          ),
      ),
      flush: true,
    );

    final result = await EpubTranslationRepository().startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: TranslationConfig.defaults(),
    );

    expect(
      result.chapters.single.blocks.map((block) => block.sourceText).toList(),
      <String>[
        'This pagebreak span contains real body prose with many English words.',
        'Before the split sentence continues here with real prose after.',
      ],
    );
  });

  test(
    'translation writes blocks back to matching non-empty elements',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_writeback_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final StreamSubscription<HttpRequest> subscription = server.listen((
        HttpRequest request,
      ) async {
        final String rawBody = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> requestBody =
            jsonDecode(rawBody) as Map<String, dynamic>;
        final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
        final Map<String, dynamic> payload =
            jsonDecode(
                  (messages.last as Map<String, dynamic>)['content'] as String,
                )
                as Map<String, dynamic>;

        final Object responsePayload = switch (payload['kind']) {
          'initialBookMemory' => <String, Object?>{
            'bookSummary': '',
            'styleGuide': <Object?>[],
            'glossary': <Object?>[],
            'recentChapters': <Object?>[],
          },
          'chapterMemory' => <String, Object?>{
            'title': 'Chapter',
            'summary': 'Translated chapter.',
            'continuityNotes': <Object?>[],
            'glossary': <Object?>[],
          },
          _ => <String, Object?>{
            'blocks': (payload['blocks'] as List<dynamic>)
                .cast<Map<String, dynamic>>()
                .map(
                  (Map<String, dynamic> block) => <String, Object?>{
                    'id': block['id'],
                    'html': switch (block['id']) {
                      'p-1' => '<p>你好。</p>',
                      'p-2' => '<p>世界。</p>',
                      _ => block['html'],
                    },
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
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      final File epubFile = File('${temp.path}/empty_first.epub');
      await epubFile.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(
              ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
            )
            ..addFile(
              ArchiveFile.string('OPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="chapter-1" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter-1"/>
  </spine>
</package>
'''),
            )
            ..addFile(
              ArchiveFile.string('OPS/Text/chapter.xhtml', '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p></p><p>Hello.</p><p>World.</p></body>
</html>
'''),
            ),
        ),
        flush: true,
      );

      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: TranslationConfig.defaults(),
      );

      expect(
        inspection.chapters.single.blocks
            .map((block) => block.sourceText)
            .toList(),
        <String>['Hello.', 'World.'],
      );

      final run = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'sk-test',
          model: 'test-model',
        ),
        chapters: inspection.chapters,
      );

      final Archive translatedArchive = ZipDecoder().decodeBytes(
        await File(run.job.outputPath).readAsBytes(),
      );
      final ArchiveFile? translatedChapter = translatedArchive.find(
        'OPS/Text/chapter.xhtml',
      );
      expect(translatedChapter, isNotNull);
      final String translatedHtml = utf8.decode(
        translatedChapter!.content as List<int>,
      );
      final paragraphs = html_parser
          .parse(translatedHtml)
          .querySelectorAll('p')
          .map((element) => element.text)
          .toList();

      expect(paragraphs, <String>['', '你好。', '世界。']);
    },
  );
}
