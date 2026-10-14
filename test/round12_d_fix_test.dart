import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _xhtmlNamespace = 'http://www.w3.org/1999/xhtml';
const _extractor = EpubHtmlExtractor();

Map<String, dynamic> _response(String content) => <String, dynamic>{
  'choices': <dynamic>[
    <String, dynamic>{
      'message': <String, dynamic>{'content': content},
    },
  ],
};

InspectedChapter _inspect(String path, String source) => _extractor
    .inspectChapterBytes(chapterPath: path, bytes: utf8.encode(source));

TranslationJob _job(String id) => TranslationJob(
  id: id,
  inputPath: '/in.epub',
  outputPath: '/out.epub',
  status: TranslationJobStatus.completed,
  progress: 1,
);

void main() {
  test(
    'P2-06 trailing reasoning boundary samples retain literal JSON tags',
    () {
      const client = TranslationApiClient();
      final json = '{"t":"${List.filled(6400, '<think>').join()}</think>"}';
      final stopwatch = Stopwatch()..start();
      final output = client.extractMessageContent(
        _response('$json<think>trailing</think>'),
      );
      stopwatch.stop();
      expect(output, json);
      expect(stopwatch.elapsedMilliseconds, lessThan(500));

      const samples = <String, String>{
        '{"t":"literal <think>inside</think>"}<think type="x">tail</think>':
            '{"t":"literal <think>inside</think>"}',
        '{"t":"literal <think>"}<think>tail</think>': '{"t":"literal <think>"}',
        '```json\n{"t":"literal <think>"}\n```<think>tail</think>':
            '```json\n{"t":"literal <think>"}\n```',
        '{"a":1}<think>one</think> \n<think mode="r">two</think>\t\r\n':
            '{"a":1}',
        'data<THINK TYPE="x">tail</THINK>  \n': 'data',
      'data<think type="literal </think>">tail</think>': 'data',
        'data<think>outer <think>inner</think>': 'data',
        'Ordinary text': 'Ordinary text',
        '{"t":"literal <think>inside</think>"}':
            '{"t":"literal <think>inside</think>"}',
        'data<think>unfinished': 'data<think>unfinished',
      };
      for (final sample in samples.entries) {
        expect(
          client.extractMessageContent(_response(sample.key)),
          sample.value,
          reason: sample.key,
        );
      }
      expect(client.extractMessageContent(_response(json)), json);
    },
  );

  test(
    'P2-08 prefixed XHTML export preserves its root and namespace',
    () async {
      final temp = await Directory.systemTemp.createTemp('round12_d_xhtml_');
      addTearDown(() => temp.delete(recursive: true));
      const prefixedSource =
          '<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:head>'
          '<x:title>Book</x:title></x:head><x:body><x:table><x:tr>'
          '<x:td id="cell" colspan="2">Hello table</x:td>'
          '</x:tr></x:table></x:body></x:html>';
      const plainSource =
          '<html><head><title>Book</title></head><body>'
          '<p id="plain">Hello paragraph</p></body></html>';
      const plainExpected =
          '<html lang="fr" xml:lang="fr"><head><title>Book</title></head>'
          '<body><p id="plain" lang="fr" xml:lang="fr">'
          'Bonjour paragraphe</p></body></html>';
      final prefixed = _inspect('OPS/prefixed.xhtml', prefixedSource);
      final plain = _inspect('OPS/plain.xhtml', plainSource);
      expect(prefixed.blocks.single.id, 'td-1');
      final translated = [
        prefixed.copyWith(
          blocks: [
            prefixed.blocks.single.copyWith(
              translatedHtml: prefixed.blocks.single.sourceHtml.replaceAll(
                'Hello table',
                'Bonjour table',
              ),
            ),
          ],
        ),
        plain.copyWith(
          blocks: [
            plain.blocks.single.copyWith(
              translatedHtml: '<p id="plain">Bonjour paragraphe</p>',
            ),
          ],
        ),
      ];
      final repacker = EpubRepacker();
      expect(
        repacker.renderTranslatedChapter(
          chapter: translated[1],
          bilingual: false,
          targetLanguage: 'French',
        ),
        plainExpected,
      );
      for (final chapter in [
        translated[0],
        prefixed.copyWith(
          blocks: [
            prefixed.blocks.single.copyWith(
              translatedHtml: prefixed.blocks.single.sourceHtml,
            ),
          ],
        ),
      ]) {
        final rendered = repacker.renderTranslatedChapter(
          chapter: chapter,
          bilingual: false,
          targetLanguage: 'French',
        );
        final root = XmlDocument.parse(rendered).rootElement;
        expect(root.name.qualified, 'x:html');
        expect(root.namespaceUri, _xhtmlNamespace);
        expect(root.getAttribute('xmlns:x'), _xhtmlNamespace);
        expect(root.getAttribute('lang'), 'fr');
        expect(
          root.descendants.whereType<XmlElement>().map(
            (node) => node.name.local,
          ),
          isNot(contains('html')),
        );
        final cell = root.descendants.whereType<XmlElement>().singleWhere(
          (node) => node.name.local == 'td',
        );
        expect(cell.namespaceUri, _xhtmlNamespace);
        expect(cell.getAttribute('id'), 'cell');
        expect(cell.getAttribute('colspan'), '2');
        expect(
          cell.innerText,
          chapter == translated[0] ? 'Bonjour table' : 'Hello table',
        );
      }

      final archive = Archive()
        ..add(ArchiveFile.string('mimetype', 'application/epub+zip'))
        ..add(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<container><rootfiles><rootfile full-path="OPS/book.opf"/>'
                '</rootfiles></container>',
          ),
        )
        ..add(
          ArchiveFile.string(
            'OPS/book.opf',
            '<package xmlns="http://www.idpf.org/2007/opf" '
                'xmlns:dc="http://purl.org/dc/elements/1.1/">'
                '<metadata><dc:language>en</dc:language></metadata><manifest>'
                '<item id="prefixed" href="prefixed.xhtml" '
                'media-type="application/xhtml+xml"/>'
                '<item id="plain" href="plain.xhtml" '
                'media-type="application/xhtml+xml"/></manifest><spine>'
                '<itemref idref="prefixed"/><itemref idref="plain"/>'
                '</spine></package>',
          ),
        )
        ..add(ArchiveFile.string(prefixed.path, prefixedSource))
        ..add(ArchiveFile.string(plain.path, plainSource));
      final input = File('${temp.path}/input.epub');
      await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final output = File('${temp.path}/output.epub');
      await repacker.writeTranslatedEpub(
        inputPath: input.path,
        outputFilePath: output.path,
        config: TranslationConfig.defaults().copyWith(targetLanguage: 'French'),
        chapters: translated,
      );
      final exported = ZipDecoder().decodeBytes(await output.readAsBytes());
      final exportedRoot = XmlDocument.parse(
        utf8.decode(exported.find(prefixed.path)!.content),
      ).rootElement;
      expect(exportedRoot.name.qualified, 'x:html');
      expect(exportedRoot.namespaceUri, _xhtmlNamespace);
      expect(
        exportedRoot.descendants
            .whereType<XmlElement>()
            .singleWhere((node) => node.name.local == 'td')
            .innerText,
        'Bonjour table',
      );
      expect(utf8.decode(exported.find(plain.path)!.content), plainExpected);
    },
  );

  test(
    'P2-09 corrupt history honors a newer tombstone before merging',
    () async {
      final temp = await Directory.systemTemp.createTemp('round12_d_history_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/job-history.json');
      final store = JobHistoryStore(historyFileProvider: () async => file);
      await store.save([_job('stale')], clearedAtEpochMs: 1000);
      final staleView = await store.loadWithTombstone();
      expect(staleView.clearedAt, 1000);
      expect(staleView.jobs.single.id, 'stale');
      const truncated = '{"clearedAt":2000,"jobs":[';
      await file.writeAsString(truncated);
      var mergeCalled = false;

      final result = await store.saveMerged(
        merge: (jobs, clearedAt) {
          mergeCalled = true;
          return staleView.jobs;
        },
        clearedAtEpochMs: staleView.clearedAt,
      );

      expect(mergeCalled, isFalse);
      expect(result.written, isFalse);
      expect(result.fileClearedAt, 2000);
      expect(await file.exists(), isTrue);
      expect(jsonDecode(await file.readAsString()), {
        'version': 2,
        'clearedAt': 2000,
        'jobs': <dynamic>[],
      });
      final backups = temp
          .listSync()
          .whereType<File>()
          .where((entry) => entry.path.contains('job-history.json.bad-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), truncated);
      final reloaded = await JobHistoryStore(
        historyFileProvider: () async => file,
      ).loadWithTombstone();
      expect(reloaded.clearedAt, 2000);
      expect(reloaded.jobs, isEmpty);
    },
  );

  test('P3-01 navigation labels retain baseline text order and hierarchy', () {
    final chapters = [_navigationChapter('one'), _navigationChapter('two')];
    final repacker = EpubRepacker();
    // 固化优化前的输出，逐项验证数量、文本和插入顺序。
    expect(
      repacker
          .debugNavigationLabels(chapters)
          .entries
          .map((entry) => [entry.key, entry.value])
          .toList(),
      [
        ['OPS/one.xhtml', '1. Chapitre un'],
        ['OPS/one.xhtml#one-h1', '1'],
        ['OPS/one.xhtml#one-inline', '1'],
        ['OPS/one.xhtml#part-one', '1'],
        ['OPS/one.xhtml#before-one', '1'],
        ['OPS/one.xhtml#one-h2', 'Chapitre un'],
        ['OPS/one.xhtml#one-h3', 'Section un'],
        ['OPS/one.xhtml#one-h4', 'Sous-section un'],
        ['OPS/one.xhtml#one-h5', 'Détail un'],
        ['OPS/one.xhtml#one-h6', 'Note un'],
        ['OPS/two.xhtml', 'Deuxième chapitre: Section deux'],
        ['OPS/two.xhtml#two-h1', 'Deuxième chapitre'],
        ['OPS/two.xhtml#two-inline', 'Deuxième chapitre'],
        ['OPS/two.xhtml#part-two', 'Deuxième chapitre'],
        ['OPS/two.xhtml#before-two', 'Deuxième chapitre'],
        ['OPS/two.xhtml#two-h2', 'Section deux'],
        ['OPS/two.xhtml#two-h3', 'Partie deux'],
        ['OPS/two.xhtml#two-h4', 'Sous-section deux'],
        ['OPS/two.xhtml#two-h5', 'Détail deux'],
        ['OPS/two.xhtml#two-h6', 'Note deux'],
      ],
    );
    final metadata = repacker.renderNavigationMetadataForTest(
      archiveFiles: _navigationFiles(),
      chapters: chapters,
      targetLanguage: 'French',
    );
    final ncx = XmlDocument.parse(metadata['OPS/toc.ncx']!);
    expect(
      ncx.descendants
          .whereType<XmlElement>()
          .where((node) => node.name.local == 'navPoint')
          .map(
            (point) => [
              point.getAttribute('id'),
              point.ancestors
                  .whereType<XmlElement>()
                  .where((node) => node.name.local == 'navPoint')
                  .length,
              point.childElements
                  .singleWhere((node) => node.name.local == 'navLabel')
                  .innerText,
              point.childElements
                  .singleWhere((node) => node.name.local == 'content')
                  .getAttribute('src'),
            ],
          )
          .toList(),
      [
        ['one-chapter', 0, '1. Chapitre un', 'one.xhtml'],
        ['one-h1', 1, '1', 'one.xhtml#one-h1'],
        ['one-h2', 2, 'Chapitre un', 'one.xhtml#one-h2'],
        ['one-h3', 3, 'Section un', 'one.xhtml#one-h3'],
        ['one-h4', 4, 'Sous-section un', 'one.xhtml#one-h4'],
        ['one-h5', 5, 'Détail un', 'one.xhtml#one-h5'],
        ['one-h6', 6, 'Note un', 'one.xhtml#one-h6'],
        ['two-chapter', 0, 'Deuxième chapitre: Section deux', 'two.xhtml'],
        ['two-h1', 1, 'Deuxième chapitre', 'two.xhtml#two-h1'],
        ['two-h2', 2, 'Section deux', 'two.xhtml#two-h2'],
        ['two-h3', 3, 'Partie deux', 'two.xhtml#two-h3'],
        ['two-h4', 4, 'Sous-section deux', 'two.xhtml#two-h4'],
        ['two-h5', 5, 'Détail deux', 'two.xhtml#two-h5'],
        ['two-h6', 6, 'Note deux', 'two.xhtml#two-h6'],
      ],
    );
  });
}

InspectedChapter _navigationChapter(String name) {
  final source = StringBuffer(
    '<html><head><title>Book $name</title></head><body>'
    '<section id="part-$name"><a id="before-$name"></a>\n<!-- gap -->',
  );
  for (var level = 1; level <= 6; level++) {
    final tag = level.isOdd ? 'H$level' : 'h$level';
    source.write(
      '<$tag id="$name-h$level" class="level-$level" data-level="$level">',
    );
    if (level == 1) source.write('<span id="$name-inline">');
    source.write('Source $name h$level');
    if (level == 1) source.write('</span>');
    source.write('</$tag>');
    for (var i = 0; i < 85; i++) {
      source.write('<p>Ordinary $name paragraph $level-$i</p>');
    }
  }
  source.write('</section></body></html>');
  final chapter = _inspect('OPS/$name.xhtml', source.toString());
  const translations = <String, String>{
    'Source one h1': '1',
    'Source one h2': 'Chapitre un',
    'Source one h3': 'Section un',
    'Source one h4': 'Sous-section un',
    'Source one h5': 'Détail un',
    'Source one h6': 'Note un',
    'Source two h1': 'Deuxième chapitre',
    'Source two h2': 'Section deux',
    'Source two h3': 'Partie deux',
    'Source two h4': 'Sous-section deux',
    'Source two h5': 'Détail deux',
    'Source two h6': 'Note deux',
  };
  return chapter.copyWith(
    blocks: [
      for (final block in chapter.blocks)
        block.copyWith(
          // 模拟缓存释放 sourceHtml，导航仍从章节原文恢复标题边界。
          sourceHtml: '',
          translatedHtml: block.sourceHtml
              .replaceAll(
                block.sourceText,
                translations[block.sourceText] ?? 'Paragraphe traduit',
              )
              .replaceAll('<h', '<H')
              .replaceAll('</h', '</H'),
        ),
    ],
  );
}

Map<String, List<int>> _navigationFiles() {
  final ncx = StringBuffer(
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>',
  );
  for (final name in ['one', 'two']) {
    ncx.write(
      '<navPoint id="$name-chapter"><navLabel><text>Original chapter</text>'
      '</navLabel><content src="$name.xhtml"/>',
    );
    for (var level = 1; level <= 6; level++) {
      ncx.write(
        '<navPoint id="$name-h$level"><navLabel><text>Original heading</text>'
        '</navLabel><content src="$name.xhtml#$name-h$level"/>',
      );
    }
    ncx.write('</navPoint>' * 7);
  }
  ncx.write('</navMap></ncx>');
  return {
    'META-INF/container.xml': utf8.encode(
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/>'
      '</rootfiles></container>',
    ),
    'OPS/book.opf': utf8.encode(
      '<package xmlns="http://www.idpf.org/2007/opf" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<metadata><dc:language>en</dc:language></metadata><manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '</manifest><spine toc="ncx"/></package>',
    ),
    'OPS/toc.ncx': utf8.encode(ncx.toString()),
  };
}
