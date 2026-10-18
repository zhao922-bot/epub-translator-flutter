import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _FootnoteFakeServer {
  _FootnoteFakeServer._(
    this._server, {
    required this.reverseResponses,
    required this.rejectMultiBlockWith413,
    required this.duplicateMultiResponseId,
    required this.rejectAllBlocksWith413,
  });

  final HttpServer _server;
  final bool reverseResponses;
  final bool rejectMultiBlockWith413;
  final bool duplicateMultiResponseId;
  final bool rejectAllBlocksWith413;
  final List<List<String>> blockRequestIds = <List<String>>[];
  final List<Map<String, dynamic>> blockPayloads = <Map<String, dynamic>>[];
  int totalRequests = 0;

  int get port => _server.port;

  static Future<_FootnoteFakeServer> start({
    bool reverseResponses = false,
    bool rejectMultiBlockWith413 = false,
    bool duplicateMultiResponseId = false,
    bool rejectAllBlocksWith413 = false,
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
      rejectAllBlocksWith413: rejectAllBlocksWith413,
    );
    httpServer.listen(server._handle);
    return server;
  }

  Future<void> close() => _server.close(force: true);

  void resetRequests() {
    totalRequests = 0;
    blockRequestIds.clear();
    blockPayloads.clear();
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
    blockPayloads.add(payload);
    final List<String> ids = blocks
        .map((Map<String, dynamic> block) => block['id'] as String)
        .toList();
    blockRequestIds.add(ids);
    if (rejectAllBlocksWith413 ||
        (rejectMultiBlockWith413 && blocks.length > 1)) {
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
              (Map<String, dynamic> block) => block.containsKey('slots')
                  ? <String, Object?>{
                      'id': duplicateId,
                      'slots': _translatedSlots(block),
                    }
                  : <String, Object?>{
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
        return block.containsKey('slots')
            ? <String, Object?>{'id': id, 'slots': _translatedSlots(block)}
            : <String, Object?>{'id': id, 'html': _translatedFootnoteHtml(id)};
      }).toList(),
    });
  }

  static List<Map<String, String>> _translatedSlots(
    Map<String, dynamic> block,
  ) {
    final String id = block['id'] as String;
    return (block['slots'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((Map<String, dynamic> slot) {
          final String slotId = slot['id'] as String;
          final String text = switch ((id, slotId)) {
            ('f0:p-1', 's0') => '正文甲',
            ('f0:p-1', 's1') => '<script>alert("body")</script>正文乙',
            ('f1:p-1', 's0') => '<script>alert("note")</script>脚注乙',
            ('f2:p-1', 's0') => '脚注丙',
            _ => '脚注译文',
          };
          return <String, String>{'id': slotId, 'text': text};
        })
        .toList(growable: false);
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

List<String> requestIds(RequestOptions options) {
  final data = options.data as Map;
  final messages = data['messages'] as List;
  final payload =
      jsonDecode((messages.last as Map)['content'] as String) as Map;
  return [
    for (final b in (payload['blocks'] as List? ?? []))
      (b as Map)['id'] as String,
  ];
}

class _OrderedNetworkDelayClient extends TranslationApiClient {
  _OrderedNetworkDelayClient(this.reverseLeaves);
  final bool reverseLeaves;
  final f2Response = Completer<void>();
  @override
  Dio buildDio(TranslationConfig config) {
    final dio = super.buildDio(config);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final ids = requestIds(options);
          if (reverseLeaves && ids.length == 1 && ids.single == 'f1:p-1') {
            await f2Response.future.timeout(const Duration(seconds: 5));
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          final ids = requestIds(response.requestOptions);
          if (ids.length == 1 &&
              ids.single == 'f2:p-1' &&
              !f2Response.isCompleted) {
            f2Response.complete();
          }
          handler.next(response);
        },
      ),
    );
    return dio;
  }
}

void main() {
  for (final reverse in [false, true]) {
    test(
      'split IDs and exported footnotes survive valid HTTP ordering reverse=$reverse',
      () async {
        final temp = await Directory.systemTemp.createTemp('audit-r45-order-');
        addTearDown(() => temp.delete(recursive: true));
        final server = await _FootnoteFakeServer.start(
          duplicateMultiResponseId: true,
        );
        addTearDown(server.close);
        final input = File('${temp.path}/source.epub');
        await _writeTestEpub(
          input,
          chapters: {
            for (var i = 1; i <= 3; i++)
              'OPS/Text/0$i-fn.xhtml':
                  '<p>Footnote number $i. <a href="chapter.xhtml#footnote_ref_$i" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
          },
        );
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'sk-test',
          model: 'audit-r45-${temp.path.hashCode}',
          targetLanguage: 'Chinese',
          chunkSize: 5000,
          maxRetries: 1,
          maxConcurrent: reverse ? 3 : 1,
        );
        final repository = EpubTranslationRepository(
          translator: EpubChapterTranslator(
            apiClient: _OrderedNetworkDelayClient(reverse),
          ),
        );
        final inspection = await repository.startJob(
          inputPath: input.path,
          outputDirectory: temp.path,
          config: config,
        );
        final run = await repository.translateChapters(
          inputPath: input.path,
          outputDirectory: temp.path,
          config: config,
          chapters: inspection.chapters,
        );
        final expected = [
          ['f0:p-1', 'f1:p-1', 'f2:p-1'],
          ['f0:p-1'],
          ['f1:p-1', 'f2:p-1'],
          ['f1:p-1'],
          ['f2:p-1'],
        ];
        debugPrint(
          'AUDIT reverse=$reverse status=${run.job.status.name} ids=${jsonEncode(server.blockRequestIds)}',
        );
        expect(run.job.status, TranslationJobStatus.completed);
        expect(server.blockRequestIds, unorderedEquals(expected));
        for (final ids in server.blockRequestIds) {
          expect(ids.toSet().length, ids.length);
        }
        for (var i = 1; i <= 3; i++) {
          final html = await _readXhtml(
            run.job.outputPath,
            'OPS/Text/0$i-fn.xhtml',
          );
          expect(html, contains(['正文甲', '脚注乙', '脚注丙'][i - 1]));
          expect(html, contains('chapter.xhtml#footnote_ref_$i'));
        }
        if (reverse) {
          expect(server.blockRequestIds.sublist(3), [
            ['f2:p-1'],
            ['f1:p-1'],
          ]);
          expect(
            server.blockRequestIds,
            isNot(equals(expected)),
            reason:
                'The original strict order assertion rejects a completed valid run.',
          );
        } else {
          expect(server.blockRequestIds, expected);
        }
        server.resetRequests();
        await repository.translateChapters(
          inputPath: input.path,
          outputDirectory: temp.path,
          config: config,
          chapters: inspection.chapters,
        );
        expect(server.totalRequests, 0);
      },
    );
  }
}
