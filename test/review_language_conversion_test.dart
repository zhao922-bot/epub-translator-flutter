import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({String input, String mono, String bi, String report})> fixture(
  Directory dir, {
  List<String> languages = const ['en'],
  String languageAttributes = 'xml:lang="en"',
  String bodyLanguageAttributes = '',
  bool legacy = false,
  bool bilingual = false,
  String target = 'Chinese',
}) async {
  final input = '${dir.path}/source.epub';
  final source =
      '<html xmlns="http://www.w3.org/1999/xhtml" $languageAttributes>'
      '<body $bodyLanguageAttributes><p id="line">Hello <em lang="it">ciao</em>.</p></body></html>';
  final archive = Archive()
    ..add(
      ArchiveFile.string('mimetype', 'application/epub+zip')
        ..compression = CompressionType.none,
    )
    ..add(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfile full-path="book.opf"/></container>',
      ),
    )
    ..add(
      ArchiveFile.string(
        'book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
            '<metadata xmlns:d="http://purl.org/dc/elements/1.1/" xmlns:x="urn:foreign">'
            '<d:title>Book</d:title><x:language>untouched</x:language>'
            '${languages.map((v) => '<d:language>$v</d:language>').join()}'
            '</metadata><manifest><item id="c" href="story.xhtml" media-type="application/xhtml+xml"/>'
            '</manifest><spine><itemref idref="c"/></spine></package>',
      ),
    )
    ..add(ArchiveFile.string('story.xhtml', source));
  File(input).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: 'story.xhtml',
    bytes: utf8.encode(source),
  );
  final translated = chapter.copyWith(
    includeInTranslation: true,
    blocks: [
      for (final b in chapter.blocks)
        b.copyWith(
          translatedHtml: '<p id="line">你好<em lang="it">ciao</em>。</p>',
        ),
    ],
  );
  final snapshots = <String, Object?>{};
  final mono = '${dir.path}/mono.epub', bi = '${dir.path}/bi.epub';
  for (final isBi in [false, true]) {
    await EpubRepacker().writeTranslatedEpub(
      inputPath: input,
      outputFilePath: isBi ? bi : mono,
      config: TranslationConfig.defaults().copyWith(
        bilingual: isBi,
        targetLanguage: target,
      ),
      chapters: [translated],
      reviewChapterPaths: {'story.xhtml'},
      reviewSnapshots: isBi == bilingual ? snapshots : null,
    );
  }
  final report = '${dir.path}/report.json';
  File(report).writeAsStringSync(
    jsonEncode({
      'version': 2,
      'outputPath': bilingual ? bi : mono,
      'corrections': [],
      'rendering': {
        'completeSnapshot': true,
        'bilingual': bilingual,
        'targetLanguage': target,
        'lockedGlossary': '',
        'chapters': snapshots,
        if (!legacy)
          'sourceLanguages': await EpubIsolateWorker.readBookLanguages(input),
      },
    }),
  );
  return (input: input, mono: mono, bi: bi, report: report);
}

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('review_lang_'),
  );
  tearDown(() => temp.delete(recursive: true));
  const store = TranslationReviewStore();

  for (final legacy in [false, true]) {
    for (final bilingual in [false, true]) {
      test(
        '${legacy ? "legacy" : "new"} report converts from bilingual=$bilingual',
        () async {
          final f = await fixture(temp, legacy: legacy, bilingual: bilingual);
          final baseline = bilingual ? f.bi : f.mono;
          final before = File(baseline).readAsBytesSync();
          final same = await store.export(
            reportPath: f.report,
            baseOutputPath: baseline,
            accepted: {},
          );
          expect(
            await EpubIsolateWorker.loadArchiveFiles(same),
            await EpubIsolateWorker.loadArchiveFiles(baseline),
          );
          final converted = await store.export(
            reportPath: f.report,
            baseOutputPath: baseline,
            accepted: {},
            bilingual: !bilingual,
          );
          expect(
            await EpubIsolateWorker.loadArchiveFiles(converted),
            await EpubIsolateWorker.loadArchiveFiles(bilingual ? f.mono : f.bi),
          );
          expect(File(baseline).readAsBytesSync(), before);
        },
      );
    }
  }

  for (final source in <List<String>>[
    ['fr', 'en'],
    ['en', 'EN', 'zh-CN'],
    [],
  ]) {
    test('new report preserves original package languages $source', () async {
      final f = await fixture(
        temp,
        languages: source,
        languageAttributes: 'lang="de"',
      );
      expect(await EpubIsolateWorker.readBookLanguages(f.input), source);
      final converted = await store.export(
        reportPath: f.report,
        baseOutputPath: f.mono,
        accepted: {},
        bilingual: true,
      );
      final files = await EpubIsolateWorker.loadArchiveFiles(converted);
      final direct = await EpubIsolateWorker.loadArchiveFiles(f.bi);
      expect(
        EpubIsolateWorker.bookLanguages(files),
        EpubIsolateWorker.bookLanguages(direct),
      );
      expect({...files}..remove('book.opf'), {...direct}..remove('book.opf'));
      expect(
        utf8.decode(files['book.opf']!),
        contains('<x:language>untouched</x:language>'),
      );
    });
  }

  test(
    'legacy body language is restored; inline foreign language is excluded',
    () async {
      final f = await fixture(
        temp,
        legacy: true,
        languageAttributes: '',
        bodyLanguageAttributes: 'lang="fr"',
        languages: ['fr'],
      );
      final converted = await store.export(
        reportPath: f.report,
        baseOutputPath: f.mono,
        accepted: {},
        bilingual: true,
      );
      expect(await EpubIsolateWorker.readBookLanguages(converted), [
        'fr',
        'zh-CN',
      ]);
    },
  );

  test(
    'legacy missing document language cannot guess from a foreign quote',
    () async {
      final f = await fixture(temp, legacy: true, languageAttributes: '');
      await expectLater(
        store.export(
          reportPath: f.report,
          baseOutputPath: f.mono,
          accepted: {},
          bilingual: true,
        ),
        throwsFormatException,
      );
      // Same-format editing remains available.
      final same = await store.export(
        reportPath: f.report,
        baseOutputPath: f.mono,
        accepted: {},
      );
      expect(
        await EpubIsolateWorker.loadArchiveFiles(same),
        await EpubIsolateWorker.loadArchiveFiles(f.mono),
      );
    },
  );

  test('unknown target language preserves package language metadata', () async {
    final f = await fixture(temp, target: 'Unmapped language');
    final converted = await store.export(
      reportPath: f.report,
      baseOutputPath: f.mono,
      accepted: {},
      bilingual: true,
    );
    expect(await EpubIsolateWorker.readBookLanguages(converted), ['en']);
  });

  test('monolingual conversion preserves language metadata ID references', () {
    final output = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: {
        'META-INF/container.xml': utf8.encode(
          '<container><rootfile full-path="b.opf"/></container>',
        ),
        'b.opf': utf8.encode(
          '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:language id="first">en</dc:language><dc:language id="second">fr</dc:language>'
          '<meta refines="#second" property="x:custom">keep</meta></metadata><manifest/></package>',
        ),
      },
      labelsByPath: {},
      languageTag: 'zh-CN',
    )['b.opf']!;
    expect(output, contains('<dc:language id="first">zh-CN</dc:language>'));
    expect(output, contains('refines="#first"'));
    expect(output, isNot(contains('refines="#second"')));
    expect(RegExp('<dc:language').allMatches(output), hasLength(1));
  });

  for (final malformed in <Object?>[
    null,
    'en',
    [123],
    [' '],
  ]) {
    test(
      'malformed source language metadata is rejected: $malformed',
      () async {
        final f = await fixture(temp);
        final report = jsonDecode(File(f.report).readAsStringSync()) as Map;
        report['rendering']['sourceLanguages'] = malformed;
        File(f.report).writeAsStringSync(jsonEncode(report));
        await expectLater(
          store.load(f.report, expectedOutputPath: f.mono),
          throwsFormatException,
        );
        await expectLater(
          store.export(
            reportPath: f.report,
            baseOutputPath: f.mono,
            accepted: {},
            bilingual: true,
          ),
          throwsFormatException,
        );
      },
    );
  }
}
