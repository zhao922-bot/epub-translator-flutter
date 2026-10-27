import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'additional_audit_regression_test.dart' as audit;
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

Map<String, String> navigation(String source) {
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: 'chapter.xhtml',
    bytes: utf8.encode(source),
  );
  return EpubRepacker().debugNavigationLabels([
    chapter.copyWith(
      includeInTranslation: true,
      blocks: [
        for (final b in chapter.blocks)
          b.copyWith(
            translatedHtml: b.sourceHtml
                .replaceAll('Main', '主标题')
                .replaceAll('(Subtitle)', '（副标题）')
                .replaceAll('Subtitle', '副标题')
                .replaceAll('Other', '独立小节'),
          ),
      ],
    ),
  ]);
}

void main() {
  for (final container in ['section', 'article', 'hgroup']) {
    test(
      'title group cannot absorb a subtitle from a new container: $container',
      () {
        final result = navigation(
          '<html><body><$container><h1 id="main">Main</h1>'
          '<h2>(Subtitle)</h2></$container><$container><h2 id="other">(Other)</h2>'
          '<p>Body.</p></$container></body></html>',
        );
        expect(result['chapter.xhtml#main'], '主标题（副标题）');
        expect(result['chapter.xhtml#other'], '(独立小节)');
      },
    );
  }
  test(
    'multiple explicit subtitles remain grouped before an independent heading',
    () {
      final result = navigation(
        '<html><body><h1 id="main">Main</h1>'
        '<h2>(Subtitle)</h2><h3 class="subtitle">Second subtitle</h3>'
        '<h3 id="other">Other</h3><p>Body.</p></body></html>',
      );
      expect(result['chapter.xhtml#main'], '主标题（副标题）: Second subtitle');
      expect(result['chapter.xhtml#other'], '独立小节');
    },
  );
  for (final tail in [
    '<h2 id="other">Other</h2>',
    '<h3 id="other">Other</h3>',
    '</div><div><h2 id="other">Other</h2>',
  ]) {
    test(
      'subtitle group excludes immediately following independent heading: $tail',
      () {
        final result = navigation(
          '<html><body><div><h1 id="main">Main</h1>'
          '<h2 id="sub">(Subtitle)</h2>$tail<p>Body.</p></div></body></html>',
        );
        expect(result['chapter.xhtml#main'], '主标题（副标题）');
        expect(result['chapter.xhtml'], '主标题（副标题）');
        expect(result['chapter.xhtml#other'], '独立小节');
        expect(result['chapter.xhtml#sub'], '（副标题）');
      },
    );
  }

  for (final semantic in [
    (
      declaration: 'xmlns:e="http://www.idpf.org/2007/ops"',
      attribute: 'e:type="subtitle"',
      grouped: true,
    ),
    (
      declaration: 'xmlns:epub="urn:foreign"',
      attribute: 'epub:type="subtitle"',
      grouped: false,
    ),
  ]) {
    test(
      'subtitle semantics respect namespace binding: ${semantic.declaration}',
      () {
        final result = navigation(
          '<html ${semantic.declaration}><body>'
          '<h1 id="main">Main</h1><h2 ${semantic.attribute}>Subtitle</h2><p>Body.</p></body></html>',
        );
        expect(
          result['chapter.xhtml#main'],
          semantic.grouped ? '主标题: 副标题' : '主标题',
        );
      },
    );
  }

  for (final stage in ['semanticEquivalence', 'semanticReviewRepair']) {
    for (final failure in ['http', 'truncated']) {
      test(
        'failed review stage stays bounded and recovers only on retry: $stage/$failure',
        () async {
          final f = fixture.Fixture();
          await f.init();
          addTearDown(f.dispose);
          f.reviewUnchanged = true;
          if (stage == 'semanticReviewRepair') {
            f.equivalenceItemsOverride = (items) => [
              for (final item in items) {...item, 'sourceImpliesDraft': false},
            ];
          }
          if (failure == 'http') {
            f.failureStatusByKind[stage] = HttpStatus.serviceUnavailable;
          } else {
            f.truncatedKinds.add(stage);
            // A truncated equivalence answer may get one bounded repair, which
            // must also fail if it cannot supply a supported correction.
            f.repairItemsOverride = (_) => [];
          }
          final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
          final first = await helpers.run(f, config: config);
          expect(first.job.unreviewedBlockCount, 2);
          final reason = failure == 'http'
              ? 'requestFailed'
              : 'invalidResponse';
          expect(
            (audit.report(first)['unreviewedReasons'] as Map).values,
            everyElement(reason),
          );
          expect(
            audit
                .semanticRequests(f)
                .where((r) => audit.payload(r)!['kind'] == stage),
            hasLength(1),
            reason:
                'Semantic transport must not silently retry outside its reservation.',
          );
          expect(audit.report(first)['automaticCorrections'], isEmpty);
          final baseline = helpers.story(first.job.outputPath);
          audit.restart(f);
          final warm = await helpers.run(f, config: config);
          expect(warm.apiUsage['requests'], 0);
          expect(warm.job.unreviewedBlockCount, 2);
          expect(helpers.story(warm.job.outputPath), baseline);
          f.failureStatusByKind.clear();
          f.truncatedKinds.clear();
          f.repairItemsOverride = null;
          f.reviewUnchanged = false;
          final retry = await helpers.run(
            f,
            config: config.copyWith(retryIncompleteReviews: true),
          );
          expect(retry.job.unreviewedBlockCount, 0);
          await audit.checkReportBinding(retry);
        },
      );
    }
  }

  for (final cap in [512, 32768]) {
    for (final reasoning in [false, true]) {
      test(
        'transport cap and reservation agree at extreme output limits: $cap/$reasoning',
        () async {
          final f = fixture.Fixture();
          await f.init();
          addTearDown(f.dispose);
          final config = f.config.copyWith(
            model: 'fixture-model',
            maxOutputTokens: cap,
            reasoningEffort: reasoning
                ? ModelReasoningEffort.high
                : ModelReasoningEffort.automatic,
          );
          const api = TranslationApiClient();
          final dio = api.buildDio(config);
          addTearDown(() => dio.close(force: true));
          for (final requested in [1, 2048, 50000]) {
            await api.postChatCompletions(
              dio: dio,
              data: {
                'model': config.model,
                'max_tokens': requested,
                'messages': [
                  {
                    'role': 'user',
                    'content': jsonEncode({
                      'kind': 'semanticEquivalence',
                      'blocks': [],
                    }),
                  },
                ],
              },
            );
            expect(
              f.requests.last['max_tokens'],
              TranslationApiClient.outputTokensFor(config, requested),
            );
            expect(f.requests.last['max_tokens'], lessThanOrEqualTo(cap));
          }
        },
      );
    }
  }

  test(
    'cancelled package export does not publish hashes; committed hashes match EPUB2 bytes',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final file = File('${f.dir.path}/out.epub');
      await file.writeAsString('previous output');
      final hashes = <String, String>{'old': 'keep'};
      final markup =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Story</title></head>'
          '<body><p data-translation="true" class="existing" xml:lang="fr">Bonjour.</p></body></html>';
      final denied = await EpubIsolateWorker.writeTranslatedEpub(
        inputPath: f.book.path,
        outputFilePath: file.path,
        translatedHtmlByPath: {'story.xhtml': markup},
        outputHtmlHashes: hashes,
        shouldCommit: () => false,
      );
      expect(denied, isFalse);
      expect(await file.readAsString(), 'previous output');
      expect(hashes, {'old': 'keep'});
      final committed = await EpubIsolateWorker.writeTranslatedEpub(
        inputPath: f.book.path,
        outputFilePath: file.path,
        translatedHtmlByPath: {'story.xhtml': markup},
        outputHtmlHashes: hashes,
      );
      expect(committed, isTrue);
      final bytes =
          ZipDecoder()
                  .decodeBytes(await file.readAsBytes())
                  .findFile('story.xhtml')!
                  .content
              as List<int>;
      final text = utf8.decode(bytes);
      expect(text, contains('class="existing epub-translator-translation"'));
      expect(text, contains('xml:lang="fr"'));
      expect(text, isNot(contains('data-translation=')));
      expect(hashes['story.xhtml'], sha256.convert(bytes).toString());
    },
  );
}
