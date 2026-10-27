import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/semantic_source_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

import 'additional_audit_regression_test.dart' as audit;
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

List<Map<String, dynamic>> requestsSince(fixture.Fixture f, int at) =>
    f.requests.skip(at).toList();

void expectVerificationOnly(fixture.Fixture f, int at, {int blocks = 2}) {
  final requests = requestsSince(f, at);
  expect(requests.map((r) => audit.payload(r)?['kind']), [
    'semanticVerification',
  ]);
  expect(audit.payload(requests.single)!['blocks'], hasLength(blocks));
}

void replaceStory(fixture.Fixture f, String paragraphs) {
  final archive = ZipDecoder().decodeBytes(f.book.readAsBytesSync());
  archive.removeFile(archive.findFile('story.xhtml')!);
  archive.addFile(
    ArchiveFile.string(
      'story.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Story</title></head>'
          '<body>$paragraphs</body></html>',
    ),
  );
  f.book.writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

void main() {
  for (final failure in [
    'budget',
    'http',
    'truncated',
    'missing',
    'duplicate',
    'invalidDecision',
    'missingConfidence',
    'invalidConfidence',
    'missingReason',
    'unsupportedEvidence',
  ]) {
    test(
      'pending verification resumes alone after restart: $failure',
      () async {
        final f = fixture.Fixture();
        await f.init(reviewLimit: failure == 'budget' ? 3 : 8);
        addTearDown(f.dispose);
        if (failure == 'http') {
          f.failureStatusByKind['semanticVerification'] = 503;
        }
        if (failure == 'truncated') {
          f.truncatedKinds.add('semanticVerification');
        }
        f.verificationItemsOverride = (items) => switch (failure) {
          'missing' => [],
          'duplicate' => [...items, ...items],
          'invalidDecision' => [
            for (final i in items) {...i, 'approve': 'true'},
          ],
          'missingConfidence' => [
            for (final i in items) {...i, 'confidence': null},
          ],
          'invalidConfidence' => [
            for (final i in items) {...i, 'confidence': 42},
          ],
          'missingReason' => [
            for (final i in items) {...i, 'reason': ''},
          ],
          'unsupportedEvidence' => [
            for (final i in items)
              {
                ...i,
                'sourceQuotes': ['invented claim'],
              },
          ],
          _ => items,
        };
        final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
        final first = await helpers.run(f, config: config);
        expect(first.job.unreviewedBlockCount, 2);
        expect(audit.report(first)['reviewedBlocks'], 0);
        expect(audit.report(first)['complete'], isFalse);
        expect(audit.report(first)['corrections'], hasLength(2));
        expect(audit.report(first)['automaticCorrections'], isEmpty);
        final reason = failure == 'budget'
            ? 'budgetLimit'
            : failure == 'http'
            ? 'requestFailed'
            : 'invalidResponse';
        expect(
          (audit.report(first)['unreviewedReasons'] as Map).values,
          everyElement(reason),
        );
        final original = helpers.story(first.job.outputPath);

        f.failureStatusByKind.clear();
        f.truncatedKinds.clear();
        f.verificationItemsOverride = null;
        audit.restart(f);
        final warm = await helpers.run(f, config: config);
        expect(warm.apiUsage['requests'], 0);
        expect(warm.job.unreviewedBlockCount, 2);
        expect(helpers.story(warm.job.outputPath), original);
        await audit.checkReportBinding(warm);

        audit.restart(f);
        final at = f.requests.length;
        final retry = await helpers.run(
          f,
          config: config.copyWith(
            maxSemanticReviewRequests: 8,
            retryIncompleteReviews: true,
          ),
        );
        expectVerificationOnly(f, at);
        expect(retry.job.unreviewedBlockCount, 0);
        expect(audit.report(retry)['reviewedBlocks'], 2);
        expect(audit.report(retry)['complete'], isTrue);
        expect(audit.report(retry)['corrections'], isEmpty);
        final applied = (audit.report(retry)['automaticCorrections'] as List)
            .cast<Map>();
        expect(applied, hasLength(2));
        expect(
          applied.every(
            (s) =>
                !s.containsKey('verificationFailure') &&
                !s.containsKey('verificationFailureReason'),
          ),
          isTrue,
        );
        await audit.checkReportBinding(retry);

        audit.restart(f);
        final completed = await helpers.run(
          f,
          config: config.copyWith(retryIncompleteReviews: true),
        );
        expect(completed.apiUsage['requests'], 0);
        expect(completed.job.unreviewedBlockCount, 0);
        expect(audit.report(completed)['automaticCorrections'], hasLength(2));
      },
    );
  }

  test(
    'retry remains pending when verification budget is still insufficient',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 3);
      addTearDown(f.dispose);
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      await helpers.run(f, config: config);
      audit.restart(f);
      final at = f.requests.length;
      final limited = await helpers.run(
        f,
        config: config.copyWith(
          retryIncompleteReviews: true,
          maxSemanticReviewTokens: 4000,
        ),
      );
      expect(f.requests.length, at);
      expect(limited.job.unreviewedBlockCount, 2);
      expect(
        (audit.report(limited)['unreviewedReasons'] as Map).values,
        everyElement('budgetLimit'),
      );
      expect(audit.report(limited)['corrections'], hasLength(2));
      audit.restart(f);
      final retry = await helpers.run(
        f,
        config: config.copyWith(retryIncompleteReviews: true),
      );
      expectVerificationOnly(f, at);
      expect(retry.job.unreviewedBlockCount, 0);
    },
  );

  for (final decision in ['reject', 'uncertain', 'newConsistencyRisk']) {
    test(
      'terminal verifier decisions are not repeatedly retried: $decision',
      () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        f.verificationItemsOverride = (items) => [
          for (final i in items)
            {
              ...i,
              if (decision == 'reject') 'approve': false,
              if (decision == 'uncertain') 'confidence': 'low',
            },
        ];
        if (decision == 'newConsistencyRisk') {
          f.reviewItemsOverride = (items) => [
            for (final i in items) {...i, 'html': '<p>她先欢喜，接着伤心地哭了 987 次。</p>'},
          ];
        }
        final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
        final first = await helpers.run(f, config: config);
        expect(audit.report(first)['automaticCorrections'], isEmpty);
        expect(audit.report(first)['corrections'], hasLength(2));
        expect(first.job.unreviewedBlockCount, 0);
        f.verificationItemsOverride = null;
        audit.restart(f);
        final retry = await helpers.run(
          f,
          config: config.copyWith(retryIncompleteReviews: true),
        );
        expect(retry.apiUsage['requests'], 0);
        expect(audit.report(retry)['automaticCorrections'], isEmpty);
      },
    );
  }

  test('mixed verifier results retry only the missing block', () async {
    final f = fixture.Fixture();
    await f.init(blocks: 3);
    addTearDown(f.dispose);
    String? pendingId;
    f.verificationItemsOverride = (items) {
      expect(items, hasLength(3));
      pendingId = items[2]['id'] as String;
      return [
        items[0],
        {...items[1], 'approve': false},
      ];
    };
    final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
    final first = await helpers.run(f, config: config);
    expect(first.job.unreviewedBlockCount, 1);
    expect(audit.report(first)['automaticCorrections'], hasLength(1));
    expect(audit.report(first)['corrections'], hasLength(2));
    f.verificationItemsOverride = null;
    audit.restart(f);
    final at = f.requests.length;
    final retry = await helpers.run(
      f,
      config: config.copyWith(retryIncompleteReviews: true),
    );
    expectVerificationOnly(f, at, blocks: 1);
    expect(
      (audit.payload(f.requests.last)!['blocks'] as List).single['id'],
      pendingId,
    );
    expect(retry.job.unreviewedBlockCount, 0);
    expect(audit.report(retry)['automaticCorrections'], hasLength(2));
    expect(audit.report(retry)['corrections'], hasLength(1));
    await audit.checkReportBinding(retry);
  });

  test(
    'cancellation during verification commit preserves completed and pending work',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      var cancelled = false;
      f.verificationItemsOverride = (items) {
        cancelled = true;
        return items;
      };
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      final inspection = await f.repo.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
      );
      await expectLater(
        f.repo.translateChapters(
          inputPath: f.book.path,
          outputDirectory: f.dir.path,
          config: config,
          chapters: inspection.chapters
              .where((c) => c.includeInTranslation)
              .toList(),
          isCancelled: () => cancelled,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      cancelled = false;
      f.verificationItemsOverride = null;
      audit.restart(f);
      final at = f.requests.length;
      final warm = await helpers.run(f, config: config);
      expect(
        requestsSince(f, at).where(
          (r) =>
              audit.payload(r)?['kind']?.toString().startsWith('semantic') ==
              true,
        ),
        isEmpty,
      );
      final pending = (audit.report(warm)['corrections'] as List).cast<Map>();
      final completed = audit.report(warm)['automaticCorrections'] as List;
      expect(pending, isNotEmpty);
      expect(pending.length + completed.length, 2);
      expect(warm.job.unreviewedBlockCount, pending.length);
      audit.restart(f);
      final retryAt = f.requests.length;
      final retry = await helpers.run(
        f,
        config: config.copyWith(retryIncompleteReviews: true),
      );
      expectVerificationOnly(f, retryAt, blocks: pending.length);
      expect(
        (audit.payload(f.requests.last)!['blocks'] as List).map((b) => b['id']),
        unorderedEquals(pending.map((b) => b['id'])),
      );
      expect(retry.job.unreviewedBlockCount, 0);
      expect(audit.report(retry)['automaticCorrections'], hasLength(2));
    },
  );

  const riskExamples = [
    'The rescue barely succeeded.',
    'The rescue almost succeeded.',
    'The rescue nearly succeeded.',
    'The gate was always open.',
    'None arrived.',
    'Any route will work.',
    'All routes were closed.',
    'The judge sat in court.',
    'The pitch changed.',
    '“Keep moving” was the advice.',
    'They returned.',
  ];
  for (final text in riskExamples) {
    test('known meaning risk is selected: $text', () {
      expect(SemanticSourceAnalysis.focus(text), isNotEmpty);
      expect(
        const TranslationConsistencyChecker().riskScore('<p>$text</p>', []),
        greaterThan(0),
      );
    });
  }
  test('ordinary prose and word substrings stay low risk', () {
    for (final text in [
      'The sky was blue.',
      'The hallway shimmered.',
      'The tall tree stood beside the wall.',
    ]) {
      expect(
        const TranslationConsistencyChecker().riskScore('<p>$text</p>', []),
        0,
      );
    }
  });
  for (final source in riskExamples.take(4)) {
    test('risk-only pipeline reviews a short risk sentence: $source', () async {
      final f = fixture.Fixture();
      await f.init(blocks: 1);
      addTearDown(f.dispose);
      replaceStory(f, '<p>$source</p>');
      final result = await helpers.run(
        f,
        config: f.config.copyWith(
          autoApplyVerifiedCorrections: true,
          maxSemanticReviewRequests: 1,
        ),
      );
      expect(audit.semanticRequests(f).map((r) => audit.payload(r)!['kind']), [
        'semanticSourceAnalysis',
      ]);
      expect(audit.report(result)['skippedLowRiskBlocks'], 0);
      expect(result.job.unreviewedBlockCount, 1);
      expect(
        (audit.report(result)['unreviewedReasons'] as Map).values,
        everyElement('budgetLimit'),
      );
    });
  }
}
