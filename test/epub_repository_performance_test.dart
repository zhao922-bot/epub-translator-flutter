import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, isEmpty);
    },
  );

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
      final firstRun = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(
        server.totalRequests,
        1,
        reason: 'A pure footnote run must not request initial book memory.',
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
    'rejects malformed multi-footnote ids without single-request fallback',
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
          'OPS/Text/01-fn.xhtml': '<p>Footnote one.</p>',
          'OPS/Text/02-fn.xhtml': '<p>Footnote two.</p>',
          'OPS/Text/03-fn.xhtml': '<p>Footnote three.</p>',
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

      Future<void> expectMalformedBatchFailure() async {
        await expectLater(
          repository.translateChapters(
            inputPath: epubFile.path,
            outputDirectory: temp.path,
            config: config,
            chapters: inspection.chapters,
          ),
          throwsA(isA<FormatException>()),
        );
      }

      await expectMalformedBatchFailure();
      expect(server.blockRequestIds, <List<String>>[
        <String>['f0:p-1', 'f1:p-1', 'f2:p-1'],
      ]);

      server.resetRequests();
      await expectMalformedBatchFailure();
      expect(
        server.blockRequestIds,
        <List<String>>[
          <String>['f0:p-1', 'f1:p-1', 'f2:p-1'],
        ],
        reason: 'The failed response must not create reusable block caches.',
      );
    },
  );

  test('413 fallback keeps every global footnote request id unique', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_repository_footnote_413_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final _FootnoteFakeServer server = await _FootnoteFakeServer.start(
      rejectMultiBlockWith413: true,
    );
    addTearDown(server.close);

    final File epubFile = File('${temp.path}/footnotes_413.epub');
    await _writeTestEpub(
      epubFile,
      chapters: const <String, String>{
        'OPS/Text/01-fn.xhtml': '<p>Footnote one.</p>',
        'OPS/Text/02-fn.xhtml': '<p>Footnote two.</p>',
        'OPS/Text/03-fn.xhtml': '<p>Footnote three.</p>',
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

    expect(server.blockRequestIds.map((List<String> ids) => ids.length), <int>[
      3,
      1,
      1,
      1,
    ]);
    expect(
      server.blockRequestIds.skip(1).expand((List<String> ids) => ids),
      <String>['f0:p-1', 'f1:p-1', 'f2:p-1'],
    );
  });
}

class _FootnoteFakeServer {
  _FootnoteFakeServer._(
    this._server, {
    required this.reverseResponses,
    required this.rejectMultiBlockWith413,
    required this.duplicateMultiResponseId,
  });

  final HttpServer _server;
  final bool reverseResponses;
  final bool rejectMultiBlockWith413;
  final bool duplicateMultiResponseId;
  final List<List<String>> blockRequestIds = <List<String>>[];
  int totalRequests = 0;

  int get port => _server.port;

  static Future<_FootnoteFakeServer> start({
    bool reverseResponses = false,
    bool rejectMultiBlockWith413 = false,
    bool duplicateMultiResponseId = false,
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
    );
    httpServer.listen(server._handle);
    return server;
  }

  Future<void> close() => _server.close(force: true);

  void resetRequests() {
    totalRequests = 0;
    blockRequestIds.clear();
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
    final List<String> ids = blocks
        .map((Map<String, dynamic> block) => block['id'] as String)
        .toList();
    blockRequestIds.add(ids);
    if (rejectMultiBlockWith413 && blocks.length > 1) {
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
              (Map<String, dynamic> block) => <String, Object?>{
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
        return <String, Object?>{'id': id, 'html': _translatedFootnoteHtml(id)};
      }).toList(),
    });
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
