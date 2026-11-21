import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_source_guard.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;

const _book = <List<String>>[
  ['The field sheltered early spring flowers.'],
  ['The black kettle warmed on the kitchen stove.'],
  ['The orchard path led towards a wooden bridge.'],
];
const _editedText = 'The copper kettle warmed on the kitchen stove.';
const _translations = {
  'The field sheltered early spring flowers.': '田野庇护着早春的花朵。',
  'The black kettle warmed on the kitchen stove.': '黑色水壶在厨房炉灶上加热。',
  'The orchard path led towards a wooden bridge.': '果园小路通往一座木桥。',
  _editedText: '铜水壶在厨房炉灶上加热。',
};

void main() {
  for (final identifier in [true, false]) {
    test(
      'metadata repack reuses paid bodies (package ID: $identifier)',
      () async {
        final fixture = await _Fixture.create();
        await fixture.writeBook(includeIdentifier: identifier);
        final first = await fixture.run();
        expect(fixture.adapter.sourceTexts, _book.expand((chapter) => chapter));
        final originalBytes = await fixture.source.readAsBytes();
        final firstChapters = _exportedChapters(first);

        await fixture.writeBook(
          includeIdentifier: identifier,
          revision: 2,
          repack: true,
        );
        expect(await fixture.source.readAsBytes(), isNot(originalBytes));
        final second = await fixture.run();
        expect(fixture.adapter.sourceTexts, isEmpty);
        expect(second.job.cachedBlocks, 3);
        expect(_exportedChapters(second), firstChapters);
      },
    );
  }

  test('an HTML repair has no equivalent ordinary request proof', () async {
    final fixture = await _Fixture.create();
    await fixture.writeBook();
    fixture.adapter.omitOnce = _book[1].single;
    final first = await fixture.run();
    expect(fixture.adapter.sourceTexts, [
      _book[0].single,
      _book[1].single,
      _book[1].single,
      _book[2].single,
    ]);
    expect(first.job.apiDegradedBlocks, 0);

    await fixture.writeBook(revision: 2, repack: true);
    final next = await fixture.run();
    expect(fixture.adapter.sourceTexts, _book[1]);
    expect(next.job.cachedBlocks, 2);
    expect(_exportedChapters(next), _exportedChapters(first));
  });

  test('one chapter revision repays only its affected source group', () async {
    final fixture = await _Fixture.create();
    await fixture.writeBook();
    await fixture.run();

    await fixture.writeBook(
      chapters: [
        _book.first,
        [_editedText],
        _book.last,
      ],
    );
    final next = await fixture.run();
    expect(fixture.adapter.sourceTexts, [_editedText]);
    expect(next.job.cachedBlocks, 2);
    expect(_exportedChapters(next)['OPS/chapter-1.xhtml'], contains('铜水壶'));
    expect(_exportedChapters(next)['OPS/chapter-0.xhtml'], contains('早春的花朵'));
  });

  test('an unchanged paragraph next to an edit is requested again', () async {
    final fixture = await _Fixture.create(chunkSize: 65);
    final paragraphs = _book.expand((chapter) => chapter).toList();
    await fixture.writeBook(chapters: [paragraphs]);
    await fixture.run();
    expect(fixture.adapter.bodyRequests, hasLength(3));

    await fixture.writeBook(
      chapters: [
        [_editedText, ...paragraphs.skip(1)],
      ],
    );
    final next = await fixture.run();
    expect(fixture.adapter.sourceTexts, [_editedText, paragraphs[1]]);
    expect(next.job.cachedBlocks, 1);
  });

  test(
    'confirmed style and changed glossary require fresh paid requests',
    () async {
      final fixture = await _Fixture.create();
      await fixture.writeBook();
      const originalStyle = TranslationStyleProfile(
        tone: 'Measured documentary prose',
      );
      await fixture.run(style: originalStyle);
      final withChangedTerm = fixture.config.copyWith(
        lockedGlossary: 'black kettle => 黑水壶',
      );
      await fixture.run(config: withChangedTerm, style: originalStyle);
      expect(fixture.adapter.sourceTexts, _book.expand((chapter) => chapter));
      const updatedStyle = TranslationStyleProfile(
        tone: 'Warm intimate narration',
      );
      final withChangedStyle = await fixture.run(
        config: withChangedTerm,
        style: updatedStyle,
      );
      expect(fixture.adapter.sourceTexts, _book.expand((chapter) => chapter));
      expect(withChangedStyle.job.cachedBlocks, 0);
    },
  );

  test(
    'proof rejects an ordinary cache row overwritten with valid HTML',
    () async {
      final fixture = await _Fixture.create();
      await fixture.writeBook();
      await fixture.run();
      final old = fixture.cache.writes.entries.singleWhere(
        (entry) => entry.value == '<p>${_translations[_book[1].single]}</p>',
      );
      await fixture.cache.putBlockTranslation(old.key, '<p>这里有另一段译文。</p>');
      await fixture.writeBook(revision: 2, repack: true);

      final next = await fixture.run();
      expect(fixture.adapter.sourceTexts, _book[1]);
      expect(next.job.cachedBlocks, 2);
      expect(_exportedChapters(next)['OPS/chapter-1.xhtml'], contains('黑色水壶'));
    },
  );

  test(
    'repacking behind an existing inspection still fails the exact guard',
    () async {
      final fixture = await _Fixture.create();
      await fixture.writeBook();
      await fixture.run();
      final staleChapters = await fixture.inspect(fixture.config);
      await fixture.writeBook(revision: 2, repack: true);

      await expectLater(
        fixture.run(chapters: staleChapters),
        throwsA(isA<EpubSourceChangedException>()),
      );
      expect(fixture.adapter.sourceTexts, isEmpty);
    },
  );
}

class _Fixture {
  _Fixture(this.root, this.config)
    : source = File(p.join(root.path, 'orchard.epub')),
      cache = _RecordingCache(Directory(p.join(root.path, 'cache')));

  final Directory root;
  final TranslationConfig config;
  final File source;
  final _RecordingCache cache;
  final adapter = _FixtureTransport();
  late final repository = EpubTranslationRepository(
    cacheStore: cache,
    translator: EpubChapterTranslator(
      cacheStore: cache,
      apiClient: _FixtureClient(adapter),
    ),
  );

  static Future<_Fixture> create({int chunkSize = 1000}) async {
    final root = await Directory.systemTemp.createTemp(
      'epub_incremental_fixture_',
    );
    final result = _Fixture(
      root,
      TranslationConfig.defaults().copyWith(
        apiKey: 'offline-cache-fixture',
        tokenSavingMode: true,
        useStreamingApi: false,
        chunkSize: chunkSize,
        maxConcurrent: 1,
        maxRetries: 1,
        retryDelaySeconds: 0,
        styleProfileEnabled: true,
        semanticQualityCheck: false,
        autoApplyVerifiedCorrections: false,
      ),
    );
    addTearDown(() async {
      await result.cache.waitForMaintenanceForTest();
      for (var attempt = 0; ; attempt++) {
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException catch (error) {
          if (!Platform.isWindows ||
              error.osError?.errorCode != 32 ||
              attempt == 3) {
            rethrow;
          }
          // Windows may briefly keep an archive or output lock open after
          // the completed worker has acknowledged shutdown.
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });
    return result;
  }

  Future<List<InspectedChapter>> inspect(
    TranslationConfig currentConfig,
  ) async {
    final inspected = await repository.startJob(
      inputPath: source.path,
      outputDirectory: root.path,
      config: currentConfig,
    );
    return [
      for (final chapter in inspected.chapters)
        chapter.copyWith(includeInTranslation: true),
    ];
  }

  Future<TranslationRunResult> run({
    TranslationConfig? config,
    List<InspectedChapter>? chapters,
    TranslationStyleProfile? style,
  }) async {
    final currentConfig = config ?? this.config;
    adapter.bodyRequests.clear();
    final result = await repository.translateChapters(
      inputPath: source.path,
      outputDirectory: root.path,
      config: currentConfig,
      chapters: chapters ?? await inspect(currentConfig),
      confirmedStyleProfile: style,
    );
    expect(
      result.job.status,
      TranslationJobStatus.completed,
      reason: result.job.errorMessage,
    );
    expect(result.job.apiDegradedBlocks, 0);
    return result;
  }

  Future<void> writeBook({
    List<List<String>> chapters = _book,
    int revision = 1,
    bool includeIdentifier = true,
    bool repack = false,
  }) async {
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
          '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
              '<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/>'
              '</rootfiles></container>',
        ),
      );
    final entries = <ArchiveFile>[];
    final manifest = StringBuffer();
    final spine = StringBuffer();
    for (final (index, paragraphs) in chapters.indexed) {
      manifest.write(
        '<item id="c$index" href="chapter-$index.xhtml" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="c$index"/>');
      final body = paragraphs.map((text) => '<p>$text</p>').join();
      entries.add(
        ArchiveFile.string(
          'OPS/chapter-$index.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Orchard $index</title>'
              '</head><body>$body</body></html>',
        ),
      );
    }
    final identifier = includeIdentifier
        ? '<dc:identifier id="id">urn:uuid:b80c2df0-f9f6-47a9-8d64-a89287455319</dc:identifier>'
        : '<dc:identifier id="nonmatching-id">unbound-publication</dc:identifier>';
    entries.add(
      ArchiveFile.string(
        'OPS/book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">$identifier'
            '<dc:title>The Orchard Record</dc:title><dc:language>en</dc:language>'
            '<meta property="dcterms:modified">2026-11-0${revision}T00:00:00Z</meta></metadata>'
            '<manifest>$manifest</manifest><spine>$spine</spine></package>',
      ),
    );
    for (final entry in repack ? entries.reversed : entries) {
      archive.addFile(entry);
    }
    await source.writeAsBytes(ZipEncoder().encodeBytes(archive));
  }
}

Map<String, String> _exportedChapters(TranslationRunResult result) => {
  for (final entry in ZipDecoder().decodeBytes(
    File(result.job.outputPath).readAsBytesSync(),
  ))
    if (entry.name.startsWith('OPS/chapter-'))
      entry.name: utf8.decode(entry.content as List<int>),
};

class _RecordingCache extends TranslationCacheStore {
  _RecordingCache(Directory root) : super(cacheRoot: root);

  final writes = <String, String>{};

  @override
  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    await super.putBlockTranslation(cacheKey, translatedHtml);
    writes[cacheKey] = translatedHtml;
  }
}

class _FixtureClient extends TranslationApiClient {
  const _FixtureClient(this.adapter);

  final _FixtureTransport adapter;

  @override
  Dio buildDio(TranslationConfig config) =>
      super.buildDio(config)..httpClientAdapter = adapter;
}

class _FixtureTransport implements HttpClientAdapter {
  String? omitOnce;
  final bodyRequests = <List<String>>[];
  List<String> get sourceTexts =>
      bodyRequests.expand((group) => group).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final raw = await utf8.decoder.bind(requestStream!).join();
    final request = jsonDecode(raw) as Map;
    final user = (request['messages'] as List).last['content'] as String;
    final payload = user.startsWith('{') ? jsonDecode(user) as Map : const {};
    String content;
    if (payload['blocks'] case final List blocks) {
      final sourceTexts = <String>[];
      final output = <Map<String, Object?>>[];
      for (final row in blocks.cast<Map>()) {
        final text = row['text'] as String?;
        final original =
            text ?? html.parseFragment(row['html'] as String).text!;
        sourceTexts.add(original);
        if (payload['kind'] != 'bodyRepair' && original == omitOnce) {
          omitOnce = null;
          continue;
        }
        final translated = _translations[original]!;
        output.add({
          'id': row['id'],
          if (text != null)
            'text': translated
          else
            'html': '<p>$translated</p>',
        });
      }
      bodyRequests.add(sourceTexts);
      content = jsonEncode({'blocks': output});
    } else if (payload.isNotEmpty) {
      content = jsonEncode({
        'bookSummary': '果园故事',
        'summary': '果园故事',
        'glossary': [],
      });
    } else {
      content = '果园记录';
    }
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 100, 'completion_tokens': 35},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
