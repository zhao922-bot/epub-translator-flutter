import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_artifact_cache.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

// All API requests in this file go to Fixture's loopback HTTP server.
Map<String, dynamic> report(TranslationRunResult result) =>
    jsonDecode(File(result.qualityReportPath!).readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic>? payload(Map<String, dynamic> request) {
  final text = (request['messages'] as List).last['content'] as String;
  return text.startsWith('{') ? jsonDecode(text) as Map<String, dynamic> : null;
}

List<Map<String, dynamic>> semanticRequests(fixture.Fixture f) => f.requests
    .where(
      (r) => payload(r)?['kind']?.toString().startsWith('semantic') == true,
    )
    .toList();

void restart(fixture.Fixture f) {
  f.repo = EpubTranslationRepository(
    cacheStore: TranslationCacheStore(
      cacheRoot: Directory('${f.dir.path}/cache'),
    ),
  );
}

void prepareSuccessfulSupplement(fixture.Fixture f, bool approved) {
  f.malformedReview = false;
  f.reviewItemsOverride = null;
  f.reviewUnchanged = approved;
  if (approved) {
    f.draftAnalysisItemsOverride = (items) => [
      for (final item in items)
        {...item, 'meaning': 'She was happy at first, then cried in distress.'},
    ];
  }
}

Future<void> checkReportBinding(TranslationRunResult result) async {
  await const TranslationReviewStore().load(
    result.qualityReportPath!,
    expectedOutputPath: result.job.outputPath,
  );
  final exported = await const TranslationReviewStore().export(
    reportPath: result.qualityReportPath!,
    baseOutputPath: result.job.outputPath,
    accepted: {},
  );
  expect(helpers.story(exported), helpers.story(result.job.outputPath));
}

void main() {
  test(
    'EPUB2 bilingual review remains bound and exportable after marker conversion',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final config = f.config.copyWith(
        bilingual: true,
        autoApplyVerifiedCorrections: true,
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await helpers.run(f, config: config);
        expect(
          helpers.story(result.job.outputPath),
          contains('class="epub-translator-translation"'),
        );
        await checkReportBinding(result);
        if (attempt == 1) expect(result.apiUsage['requests'], 0);
        restart(f);
      }
    },
  );
  for (final limit in [1, 3, 4]) {
    test(
      'budget exhaustion at analysis/equivalence/repair is resumable: $limit',
      () async {
        final f = fixture.Fixture();
        await f.init(reviewLimit: limit);
        addTearDown(f.dispose);
        f.reviewUnchanged = true;
        if (limit == 4) {
          f.equivalenceItemsOverride = (items) => [
            for (final item in items) {...item, 'sourceImpliesDraft': false},
          ];
        }
        final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
        final first = await helpers.run(f, config: config);
        expect(first.job.unreviewedBlockCount, 2);
        expect(
          (report(first)['unreviewedReasons'] as Map).values,
          everyElement('budgetLimit'),
        );
        expect(semanticRequests(f).length, lessThanOrEqualTo(limit));
        f.reviewUnchanged = false;
        final before = f.requests.length;
        restart(f);
        final second = await helpers.run(
          f,
          config: config.copyWith(maxSemanticReviewRequests: 8),
        );
        expect(second.job.unreviewedBlockCount, 0);
        expect(second.apiUsage['requests'], greaterThan(0));
        expect(
          f.requests.skip(before).map((r) => payload(r)?['kind']),
          everyElement(startsWith('semantic')),
        );
        await checkReportBinding(second);
      },
    );
  }

  for (final model in ['ordinary', 'glm', 'explicitReasoning']) {
    for (final cap in [512, 4096, 8192]) {
      test('six review stages reserve outbound caps: $model / $cap', () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        f.reviewUnchanged = true;
        f.equivalenceItemsOverride = (items) => [
          for (final item in items) {...item, 'sourceImpliesDraft': false},
        ];
        f.repairItemsOverride = (items) => [
          for (final item in items)
            {...item, 'html': '<p>她先欢喜，接着却伤心地哭喊起来。</p>', 'coverage': []},
        ];
        final result = await helpers.run(
          f,
          config: f.config.copyWith(
            model: model == 'glm' ? 'zai-org/GLM-5.3-Flash' : 'fixture-model',
            reasoningEffort: model == 'explicitReasoning'
                ? ModelReasoningEffort.high
                : ModelReasoningEffort.automatic,
            maxOutputTokens: cap,
            autoApplyVerifiedCorrections: true,
            maxSemanticReviewTokens: 100000,
          ),
        );
        final requests = semanticRequests(f);
        expect(requests.map((r) => payload(r)!['kind']), [
          'semanticSourceAnalysis',
          'semanticDraftAnalysis',
          'semanticReview',
          'semanticEquivalence',
          'semanticReviewRepair',
          'semanticVerification',
        ]);
        final wire = requests.fold<int>(
          0,
          (n, r) =>
              n +
              utf8.encode(jsonEncode(r['messages'])).length +
              256 +
              (r['max_tokens'] as int),
        );
        expect(report(result)['reservedTokens'], wire);
        expect(wire, lessThanOrEqualTo(100000));
        expect(
          requests.map((r) => r['max_tokens']),
          everyElement(lessThanOrEqualTo(cap)),
        );
        if (model != 'ordinary') {
          expect(
            requests.map((r) => r['max_tokens']),
            everyElement(greaterThanOrEqualTo(cap < 4096 ? cap : 4096)),
          );
        }
      });
    }
  }

  test('tight token limit includes reasoning response allowance', () async {
    final f = fixture.Fixture();
    await f.init();
    addTearDown(f.dispose);
    final result = await helpers.run(
      f,
      config: f.config.copyWith(
        autoApplyVerifiedCorrections: true,
        maxSemanticReviewTokens: 30000,
      ),
    );
    final wire = semanticRequests(f).fold<int>(
      0,
      (n, r) =>
          n +
          utf8.encode(jsonEncode(r['messages'])).length +
          256 +
          (r['max_tokens'] as int),
    );
    expect(report(result)['reservedTokens'], wire);
    expect(wire, lessThanOrEqualTo(30000));
    expect(
      (report(result)['corrections'] as List).cast<Map>().map(
        (r) => r['autoApplication'],
      ),
      everyElement('verificationBudgetLimit'),
    );
  });

  test(
    'equivalence and verification budget failures preserve the peer proposal',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 3);
      addTearDown(f.dispose);
      f.reviewItemsOverride = (items) => [
        {
          ...items.first,
          'unchanged': true,
          'coverage': [
            for (final c in items.first['coverage'] as List)
              {...c as Map, 'verdict': 'equivalent'},
          ],
        },
        items.last,
      ];
      final result = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      // One block still needs equivalence; the intact peer proposal now
      // honestly reports its independently exhausted verification stage too.
      expect(result.job.unreviewedBlockCount, 2);
      expect((report(result)['unreviewedReasons'] as Map).values, [
        'budgetLimit',
        'budgetLimit',
      ]);
      expect(report(result)['corrections'], hasLength(1));
      expect((report(result)['corrections'] as List).single['id'], 'p-2');
      expect(
        (report(result)['corrections'] as List).single['autoApplication'],
        'verificationBudgetLimit',
      );
    },
  );

  for (final approve in [false, true]) {
    for (final failure in ['none', 'budget', 'malformed']) {
      test(
        'partial retry preserves drafts/history across restart: $approve / $failure',
        () async {
          final f = fixture.Fixture();
          await f.init();
          addTearDown(f.dispose);
          f.reviewItemsOverride = (items) => [
            for (final item in items) {...item, 'coverage': []},
          ];
          f.verificationItemsOverride = (items) => [
            for (final item in items) {...item, 'approve': approve},
          ];
          final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
          final first = await helpers.run(f, config: config);
          final firstReport = report(first);
          final draft = helpers.story(first.job.outputPath);
          expect(first.job.unreviewedBlockCount, 2);
          prepareSuccessfulSupplement(f, approve);
          f.malformedReview = failure == 'malformed';
          if (failure == 'budget') f.reviewUnchanged = true;
          final before = f.requests.length;
          restart(f);
          final retry = await helpers.run(
            f,
            config: config.copyWith(
              retryIncompleteReviews: true,
              maxSemanticReviewRequests: failure == 'budget' ? 1 : 8,
            ),
          );
          expect(retry.apiUsage['requests'], greaterThan(0));
          expect(
            f.requests.skip(before).map((r) => payload(r)?['kind']),
            everyElement(startsWith('semantic')),
          );
          expect(retry.job.unreviewedBlockCount, failure == 'none' ? 0 : 2);
          if (failure != 'none') {
            expect(
              (report(retry)['unreviewedReasons'] as Map).values,
              everyElement(
                failure == 'budget' ? 'budgetLimit' : 'invalidResponse',
              ),
            );
          }
          expect(helpers.story(retry.job.outputPath), draft);
          expect(
            report(retry)['automaticCorrections'],
            firstReport['automaticCorrections'],
          );
          expect(report(retry)['corrections'], hasLength(approve ? 0 : 2));
          if (failure != 'none') {
            expect(report(retry)['corrections'], firstReport['corrections']);
          }
          await checkReportBinding(retry);
          final retryReport = report(retry);
          restart(f);
          final warm = await helpers.run(f, config: config);
          expect(warm.apiUsage['requests'], 0);
          expect(warm.job.unreviewedBlockCount, failure == 'none' ? 0 : 2);
          expect(
            report(warm)['automaticCorrections'],
            retryReport['automaticCorrections'],
          );
          expect(report(warm)['corrections'], retryReport['corrections']);
          await checkReportBinding(warm);
          if (failure != 'none') {
            prepareSuccessfulSupplement(f, approve);
            final recovered = await helpers.run(
              f,
              config: config.copyWith(retryIncompleteReviews: true),
            );
            expect(recovered.job.unreviewedBlockCount, 0);
            expect(helpers.story(recovered.job.outputPath), draft);
            await checkReportBinding(recovered);
          }
        },
      );
    }

    test(
      'verification reason is redacted and Unicode safe across restart: $approve',
      () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        f.verificationItemsOverride = (items) => [
          for (final item in items)
            {
              ...item,
              'approve': approve,
              'reason':
                  '${f.config.apiKey} ${'a' * 1188}😀 more ${f.config.apiKey}',
            },
        ];
        final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
        final field = approve ? 'automaticCorrections' : 'corrections';
        for (var attempt = 0; attempt < 2; attempt++) {
          final result = await helpers.run(f, config: config);
          final records = (report(result)[field] as List).cast<Map>();
          expect(records, hasLength(2));
          for (final record in records) {
            final reason = record['verificationReason'] as String;
            expect(reason, isNot(contains(f.config.apiKey)));
            expect(reason, contains('[redacted]'));
            expect(reason.length, lessThanOrEqualTo(1200));
            expect(utf8.decode(utf8.encode(reason)), reason);
          }
          await checkReportBinding(result);
          if (attempt == 1) expect(result.apiUsage['requests'], 0);
          restart(f);
        }
      },
    );

    test('legacy verification reason cache is migrated: $approve', () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.verificationItemsOverride = (items) => [
        for (final item in items) {...item, 'approve': approve},
      ];
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      await helpers.run(f, config: config);
      final artifact = TranslationArtifactCache(f.repo.cacheStore);
      final field = approve ? 'automaticCorrection' : 'suggestion';
      final changed = <String>[];
      for (final file
          in Directory('${f.dir.path}/cache')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.html'))) {
        final key = path.basenameWithoutExtension(file.path);
        final entry = await artifact.read(key);
        if (entry?[field] is! Map) continue;
        (entry![field] as Map)['verificationReason'] =
            'Legacy reason ${f.config.apiKey}.';
        await artifact.write(key, entry);
        changed.add(key);
      }
      expect(changed, hasLength(2));
      restart(f);
      final result = await helpers.run(f, config: config);
      expect(result.apiUsage['requests'], 0);
      expect(jsonEncode(report(result)), isNot(contains(f.config.apiKey)));
      for (final key in changed) {
        expect(
          jsonEncode(
            await TranslationArtifactCache(f.repo.cacheStore).read(key),
          ),
          isNot(contains(f.config.apiKey)),
        );
      }
      await checkReportBinding(result);
    });
  }
}
