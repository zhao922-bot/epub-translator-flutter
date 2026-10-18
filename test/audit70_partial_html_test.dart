import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';

class _PartialReply implements HttpClientAdapter {
  _PartialReply(this.kind);
  final String kind;
  int batches = 0;
  final fallbackSources = <String>[];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data as Map;
    final messages = data['messages'] as List;
    final user = (messages.last as Map)['content'] as String;
    Object reply;
    if (user.trimLeft().startsWith('{')) {
      batches++;
      final blocks = (jsonDecode(user) as Map)['blocks'] as List;
      reply = {
        'blocks': [
          {'id': (blocks[0] as Map)['id'], 'html': '<p>第一段译文。</p>'},
          {
            'id': (blocks[1] as Map)['id'],
            if (kind != 'missing') 'html': kind == 'null' ? null : '',
          },
        ],
      };
    } else {
      fallbackSources.add(user);
      reply = user.contains('First paragraph')
          ? '<p>第一段译文。</p>'
          : '<p>第二段译文。</p>';
    }
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {'content': reply is String ? reply : jsonEncode(reply)},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  for (final kind in ['empty', 'null', 'missing']) {
    test(
      'a $kind html on one block does not retranslate a healthy sibling',
      () async {
        final adapter = _PartialReply(kind);
        final dio = Dio(BaseOptions(baseUrl: 'https://offline.invalid/v1'))
          ..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        final result = await EpubChapterTranslator().translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            residualQualityCheck: false,
            maxConcurrent: 1,
          ),
          blocks: const [
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>First paragraph.</p>',
              sourceText: 'First paragraph.',
            ),
            ExtractedBlock(
              id: 'p-2',
              tagName: 'p',
              sourceHtml: '<p>Second paragraph.</p>',
              sourceText: 'Second paragraph.',
            ),
          ],
        );
        final healthyRepeated = adapter.fallbackSources
            .where((s) => s.contains('First paragraph'))
            .length;
        debugPrint(
          'AUDIT partial $kind html: batches=${adapter.batches}, individualRequests=${adapter.fallbackSources.length}, healthyRepeated=$healthyRepeated',
        );
        expect(result, ['<p>第一段译文。</p>', '<p>第二段译文。</p>']);
        expect(adapter.batches, 1);
        expect(
          healthyRepeated,
          0,
          reason:
              'The valid p-1 reply must remain reusable when only p-2 lacks HTML',
        );
        expect(adapter.fallbackSources, hasLength(1));
      },
    );
  }
}
