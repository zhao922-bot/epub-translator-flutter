import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

import 'bug_audit_round3_regression_test.dart' as fixture;

void main() {
  test('only missing phases use legacy block-count inference', () {
    final legacy = {'id': 'legacy', 'status': 'failed', 'totalBlocks': 5};
    expect(
      TranslationJob.fromJson(legacy).phase,
      TranslationJobPhase.translation,
    );
    final inspection = TranslationJob.fromJson({
      ...legacy,
      'phase': 'inspection',
    });
    expect(inspection.phase, TranslationJobPhase.inspection);
    expect(
      TranslationJob.fromJson(inspection.toJson()).phase,
      TranslationJobPhase.inspection,
    );
    expect(
      TranslationJob.fromJson({...legacy, 'status': 'inspected'}).phase,
      TranslationJobPhase.inspection,
    );
  });
  for (final enableStyle in [false, true]) {
    for (final scenario in [
      (status: TranslationJobStatus.failed, blocks: 0),
      (status: TranslationJobStatus.failed, blocks: 5),
      (status: TranslationJobStatus.cancelled, blocks: 5),
    ]) {
      test(
        'inspection retry preserves selection: ${scenario.status.name}, ${scenario.blocks} blocks, style=$enableStyle',
        () async {
          TestWidgetsFlutterBinding.ensureInitialized();
          final repository = fixture.RetryProbeRepository();
          final job = TranslationJob(
            id: 'inspection-retry',
            inputPath: 'C:/audit/book.epub',
            outputPath: 'C:/audit/output',
            status: scenario.status,
            phase: TranslationJobPhase.inspection,
            progress: 0.3,
            totalBlocks: scenario.blocks,
          );
          final controller = TranslationDashboardController(
            repository: repository,
            historyStore: fixture.SeedHistory(job),
            windowsPathObserverOverride: (_) async {},
          );
          addTearDown(controller.dispose);
          controller.syncSettings(
            TranslationConfig.defaults().copyWith(
              styleProfileEnabled: enableStyle,
            ),
          );
          await Future<void>.delayed(Duration.zero);
          await controller.retryJob(job.id);
          expect(controller.state.job!.status, TranslationJobStatus.inspected);
          expect(repository.styleRequests, enableStyle ? 1 : 0);
          expect(
            repository.selections,
            isEmpty,
            reason: 'Inspection retry should not start a translation.',
          );
          expect(
            controller.state.inspectedChapters
                .where((c) => c.includeInTranslation)
                .length,
            2,
            reason:
                'An interrupted inspection never had a translation selection to restore.',
          );
        },
      );
    }
  }

  for (final tag in ['p', 'td', 'th']) {
    test(
      'source attributes survive real batch translation and render for $tag',
      () async {
        final isCell = tag != 'p';
        final fragment =
            '<$tag id="cell" class="metric"${isCell ? ' colspan="2"' : ''}>Total revenue</$tag>';
        final chapter = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: 'OPS/chapter.xhtml',
          bytes: utf8.encode(
            '<html><body>${isCell ? '<table><tr>$fragment</tr></table>' : fragment}</body></html>',
          ),
        );
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://audit.invalid/v1',
          apiKey: 'audit-placeholder',
          maxRetries: 1,
          residualQualityCheck: true,
        );
        final dio = const TranslationApiClient().buildDio(config);
        addTearDown(() => dio.close(force: true));
        var requests = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              final payload =
                  jsonDecode(
                        ((options.data as Map)['messages'] as List)
                                .last['content']
                            as String,
                      )
                      as Map;
              final response = {
                'blocks': [
                  for (final item in payload['blocks'] as List)
                    {'id': (item as Map)['id'], 'html': '<$tag>总收入</$tag>'},
                ],
              };
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'choices': [
                      {
                        'message': {'content': jsonEncode(response)},
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
        final translated = await EpubTranslationRepository()
            .translateBlockBatchForTest(
              dio: dio,
              config: config,
              blocks: chapter.blocks,
            );
        expect(requests, 1);
        final rendered = EpubRepacker().renderTranslatedChapter(
          chapter: chapter.copyWith(
            blocks: [
              chapter.blocks.single.copyWith(translatedHtml: translated.single),
            ],
          ),
          bilingual: false,
        );
        final element = html.parse(rendered).querySelector(tag)!;
        expect(element.text, '总收入');
        expect(element.attributes['id'], 'cell');
        expect(element.attributes['class'], 'metric');
        if (isCell) expect(element.attributes['colspan'], '2');
      },
    );
  }

  for (final tag in ['td', 'th']) {
    for (final bilingual in [false, true]) {
      test(
        'export keeps source $tag attributes despite altered model attributes: bilingual=$bilingual',
        () {
          final chapter = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'OPS/chapter.xhtml',
            bytes: utf8.encode(
              '<html><body><table><tr><$tag id="cell" class="metric" colspan="2" rowspan="2" headers="heading" scope="row">Total</$tag></tr></table></body></html>',
            ),
          );
          final result = EpubRepacker().renderTranslatedChapter(
            chapter: chapter.copyWith(
              blocks: [
                chapter.blocks.single.copyWith(
                  translatedHtml:
                      '<$tag id="wrong" class="wrong" colspan="99">总计</$tag>',
                ),
              ],
            ),
            bilingual: bilingual,
          );
          final document = html.parse(result);
          final cell = document.querySelector(tag)!;
          expect(cell.attributes['id'], 'cell');
          expect(cell.attributes['class'], 'metric');
          expect(cell.attributes['colspan'], '2');
          expect(cell.attributes['rowspan'], '2');
          expect(cell.attributes['headers'], 'heading');
          expect(cell.attributes['scope'], 'row');
          expect(cell.text, contains('总计'));
          expect(document.querySelectorAll('#cell'), hasLength(1));
          expect(document.querySelector('#wrong'), isNull);
        },
      );
    }
    test(
      'protected footnote translation keeps the $tag shell and link',
      () async {
        final chapter = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: 'OPS/chapter.xhtml',
          bytes: utf8.encode(
            '<html><body><table><tr><$tag id="cell" colspan="2">Total<a role="doc-noteref" id="ref1" href="notes.xhtml#one">1</a> revenue</$tag></tr></table></body></html>',
          ),
        );
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://audit.invalid/v1',
          apiKey: 'audit-placeholder',
          maxRetries: 1,
        );
        final dio = const TranslationApiClient().buildDio(config);
        addTearDown(() => dio.close(force: true));
        var requests = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              final payload =
                  jsonDecode(
                        ((options.data as Map)['messages'] as List)
                                .last['content']
                            as String,
                      )
                      as Map;
              final blocks = payload['blocks'] as List;
              final response = {
                'blocks': [
                  for (final block in blocks)
                    {
                      'id': block['id'],
                      'slots': [
                        for (final slot in block['slots'] as List)
                          {'id': slot['id'], 'text': '译文'},
                      ],
                    },
                ],
              };
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'choices': [
                      {
                        'message': {'content': jsonEncode(response)},
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
        final translated = await EpubTranslationRepository()
            .translateBlockBatchForTest(
              dio: dio,
              config: config,
              blocks: chapter.blocks,
            );
        expect(requests, 1);
        final result = EpubRepacker().renderTranslatedChapter(
          chapter: chapter.copyWith(
            blocks: [
              chapter.blocks.single.copyWith(translatedHtml: translated.single),
            ],
          ),
          bilingual: false,
        );
        final cell = html.parse(result).querySelector(tag)!;
        expect(cell.attributes['id'], 'cell');
        expect(cell.attributes['colspan'], '2');
        expect(cell.querySelector('a')!.attributes['href'], 'notes.xhtml#one');
        expect(cell.querySelector('a')!.attributes['id'], 'ref1');
        expect(cell.querySelector('a')!.text, '1');
        expect(cell.text, contains('译文'));
      },
    );
  }

  test('both proxy port boundaries work for all supported forms', () {
    for (final port in [1, 65535]) {
      for (final prefix in ['', 'http://', 'https://']) {
        for (final host in ['proxy.example', '[::1]']) {
          final value = '$prefix$host:$port';
          expect(TranslationApiClient.validateProxySetting(value), isNull);
          expect(TranslationApiClient.proxyHostPort(value), endsWith(':$port'));
        }
      }
    }
  });

  test('control: supported HTTP proxy is accepted', () {
    expect(
      TranslationApiClient.validateProxySetting('http://proxy.example:8080'),
      isNull,
    );
    expect(
      TranslationApiClient.proxyHostPort('http://proxy.example:8080'),
      'proxy.example:8080',
    );
  });

  for (final port in [0, 65536]) {
    test('URL-form proxy rejects invalid port $port just like bare form', () {
      expect(
        TranslationApiClient.validateProxySetting('proxy.example:$port'),
        ProxySettingError.invalidFormat,
      );
      expect(TranslationApiClient.proxyHostPort('proxy.example:$port'), isNull);
      for (final scheme in ['http', 'https']) {
        final url = '$scheme://proxy.example:$port';
        expect(
          TranslationApiClient.validateProxySetting(url),
          ProxySettingError.invalidFormat,
        );
        expect(TranslationApiClient.proxyHostPort(url), isNull);
      }
    });
  }
}
