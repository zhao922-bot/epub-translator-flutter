import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'real_book_fix_regression_test.dart' as fixture;

Future<TranslationRunResult> run(
  fixture.Fixture f, {
  TranslationConfig? config,
  void Function(TranslationJob, String)? onProgress,
}) async {
  final c = config ?? f.config;
  final inspection = await f.repo.startJob(
    inputPath: f.book.path,
    outputDirectory: f.dir.path,
    config: c,
  );
  return f.repo.translateChapters(
    inputPath: f.book.path,
    outputDirectory: f.dir.path,
    config: c,
    chapters: inspection.chapters.where((c) => c.includeInTranslation).toList(),
    onProgress: onProgress,
  );
}

String story(String file) => utf8.decode(
  ZipDecoder()
          .decodeBytes(File(file).readAsBytesSync())
          .findFile('story.xhtml')!
          .content
      as List<int>,
);

void main() {
  test(
    'book-memory name checks survive numeric checks and warm-cache restoration',
    () async {
      final f = fixture.Fixture();
      await f.init(sourcePrefix: 'Della paid 20 dollars. ');
      addTearDown(f.dispose);
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await run(f);
        final report = await const TranslationReviewStore().load(
          result.qualityReportPath!,
        );
        final findings = (report['findings'] as List).cast<Map>();
        expect(findings, isNotEmpty);
        for (final finding in findings) {
          expect(
            (finding['checks'] as List).cast<Map>().map((c) => c['code']),
            containsAll(['number', 'currency', 'glossary']),
          );
        }
        if (attempt == 1) expect(result.apiUsage['requests'], 0);
      }
    },
  );
  const checker = TranslationConsistencyChecker();
  test(
    'deterministic checks recognize Chinese numbers, preserve currencies and protect footnotes',
    () {
      final config = TranslationConfig.defaults().copyWith(
        lockedGlossary: 'Della => 德拉',
      );
      List<Map<String, String>> check(String source, String target) => checker
          .check(sourceHtml: source, translatedHtml: target, config: config);
      expect(
        check(
          '<p>Della paid 20 dollars and 60 cents.</p>',
          '<p>德拉支付了二十美元和六十美分。</p>',
        ),
        isEmpty,
      );
      final bad = check(
        '<p>Della paid 20 dollars and 60 cents.</p>',
        '<p>她支付了三十元和六毛。</p>',
      );
      expect(
        bad.map((f) => f['code']),
        containsAll(['number', 'currency', 'glossary']),
      );
      expect(
        check(
          '<p>It cost 1.87 dollars.<sup>99</sup></p>',
          '<p>花了一点八七美元。<sup>注</sup></p>',
        ),
        isEmpty,
      );
      expect(check('<p>1200 pages</p>', '<p>一千二百页</p>'), isEmpty);
      expect(check('<p>Copyright 2026</p>', '<p>版权所有二〇二六</p>'), isEmpty);
      expect(
        checker.riskScore('<p>He never returned, but she waited.</p>', []),
        greaterThan(0),
      );
      expect(checker.riskScore('<p>The sky was blue.</p>', []), 0);
    },
  );

  test(
    'bounded evidence retrieves an established gold watch without sending the full book',
    () {
      final evidence = ReviewEvidenceIndex()
        ..add('Jim owned a gold watch inherited from his father.');
      for (var i = 0; i < 20000; i++) {
        evidence.add(
          'Another unrelated sentence about morning sunlight number $i.',
        );
      }
      final found = evidence.retrieve(
        'She thought about the watch and its fine chain.',
      );
      expect(found.join(), contains('gold watch'));
      expect(found.length, lessThanOrEqualTo(3));
      expect(found.join().length, lessThanOrEqualTo(1440));
    },
  );

  for (final bilingual in [false, true]) {
    test(
      'suggestions require acceptance, export/undo preserves EPUB and warm cache report (bilingual=$bilingual)',
      () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        final config = f.config.copyWith(bilingual: bilingual);
        final result = await run(f, config: config);
        final originalBytes = await File(result.job.outputPath).readAsBytes();
        const store = TranslationReviewStore();
        final report = await store.load(result.qualityReportPath!);
        expect(report['corrections'], hasLength(2));
        expect(result.job.reviewSuggestionCount, 2);
        expect(result.job.apiUsage, result.apiUsage);
        expect(
          result.apiUsage['usageReportedRequests'],
          result.apiUsage['requests'],
        );
        final first = (report['corrections'] as List).first as Map;
        final selected = {TranslationReviewStore.suggestionKey(first)};
        final exported = await store.export(
          reportPath: result.qualityReportPath!,
          baseOutputPath: result.job.outputPath,
          accepted: selected,
        );
        final rendered = story(exported);
        expect('伤心地哭喊'.allMatches(rendered), hasLength(1));
        expect('喜极而泣'.allMatches(rendered), hasLength(1));
        expect(XmlDocument.parse(rendered).rootElement.name.local, 'html');
        if (bilingual) {
          expect('First she screamed'.allMatches(rendered), hasLength(2));
        }
        expect(await File(result.job.outputPath).readAsBytes(), originalBytes);
        final undone = await store.export(
          reportPath: result.qualityReportPath!,
          baseOutputPath: result.job.outputPath,
          accepted: {},
        );
        expect(story(undone), story(result.job.outputPath));
        final paid = f.requests.length;
        final warm = await run(f, config: config);
        expect(f.requests.length, paid);
        expect(warm.job.cachedBlocks, 2);
        final warmReport = await store.load(warm.qualityReportPath!);
        expect(warmReport['corrections'], hasLength(2));
        expect(warmReport['reviewedBlocks'], 2);
        expect(warm.apiUsage['requests'], 0);
      },
    );
  }

  for (final mode in ['style', 'uncertain', 'inventedQuote']) {
    test('reviewer cannot silently apply $mode rewrites', () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      if (mode == 'style') f.reviewCategory = 'style';
      if (mode == 'uncertain') f.reviewConfidence = 'uncertain';
      if (mode == 'inventedQuote') {
        f.reviewQuoteOverride = 'He explicitly said this was not a gold watch.';
      }
      final result = await run(f);
      final report = await const TranslationReviewStore().load(
        result.qualityReportPath!,
      );
      expect(report['corrections'], isEmpty);
      expect(report['unreviewed'], hasLength(2));
      expect(story(result.job.outputPath), contains('喜极而泣'));
    });
  }

  test(
    'token reservation stops parallel reviews even if the provider omits usage',
    () async {
      final f = fixture.Fixture();
      await f.init(blocks: 24, chunkSize: 1000, reviewLimit: 64);
      addTearDown(f.dispose);
      f.omitUsage = true;
      final result = await run(
        f,
        config: f.config.copyWith(
          maxSemanticReviewTokens: 8000,
          maxConcurrent: 8,
        ),
      );
      final report = await const TranslationReviewStore().load(
        result.qualityReportPath!,
      );
      expect(report['reservedTokens'] as int, lessThanOrEqualTo(8000));
      expect(report['requests'] as int, lessThanOrEqualTo(1));
      expect(report['unreviewed'], isNotEmpty);
      expect(result.apiUsage['usageReportedRequests'], 0);
      expect(result.job.degradedBlockCount, 0);
    },
  );

  test(
    'history persists usage, review paths and counters across a fresh store',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final result = await run(f);
      final file = File('${f.dir.path}/history.json');
      await JobHistoryStore(
        historyFileProvider: () async => file,
      ).save([result.job]);
      final restored = (await JobHistoryStore(
        historyFileProvider: () async => file,
      ).load()).single;
      expect(restored.apiUsage, result.apiUsage);
      expect(restored.qualityReportPath, result.qualityReportPath);
      expect(restored.reviewSuggestionCount, 2);
      expect(restored.elapsedMilliseconds, greaterThan(0));
      final legacy = TranslationJob.fromJson({'id': 'legacy'});
      expect(legacy.apiUsage, isEmpty);
      expect(legacy.qualityReportPath, isNull);
    },
  );

  test(
    'changed baseline is refused before exporting any user-selected corrections',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final result = await run(f);
      const store = TranslationReviewStore();
      final report = await store.load(result.qualityReportPath!);
      final archive = ZipDecoder().decodeBytes(
        await File(result.job.outputPath).readAsBytes(),
      );
      archive.addFile(
        ArchiveFile.string(
          'story.xhtml',
          '<html><body><p>Different edition</p></body></html>',
        ),
      );
      await File(
        result.job.outputPath,
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      await expectLater(
        store.export(
          reportPath: result.qualityReportPath!,
          baseOutputPath: result.job.outputPath,
          accepted: {
            TranslationReviewStore.suggestionKey(
              (report['corrections'] as List).first as Map,
            ),
          },
        ),
        throwsFormatException,
      );
    },
  );
}
