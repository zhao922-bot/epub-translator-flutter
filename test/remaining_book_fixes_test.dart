import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/review_text_patch.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/review_evidence_validator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_artifact_cache.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/book_source_index.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

void main() {
  test(
    'compact unchanged and patch responses complete without repeating HTML',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.reviewItemsOverride = (items) => [
        {'id': items.first['id'], 'unchanged': true},
        {
          ...items.last,
          'html': null,
          'edits': [
            {'before': '喜极而泣', 'after': '伤心落泪'},
          ],
          'sourceQuote': null,
          'sourceQuotes': ['alas'],
        },
      ];
      final result = await helpers.run(f);
      expect(result.job.unreviewedBlockCount, 0);
      expect(result.job.reviewSuggestionCount, 1);
      final again = await helpers.run(f);
      expect(again.apiUsage['requests'], 0);
      expect(again.job.reviewSuggestionCount, 1);
      expect(
        helpers.story(result.job.outputPath),
        contains('喜极而泣'),
        reason: 'Proposals never silently edit the draft.',
      );
    },
  );

  test('minimal edits preserve inline tags and escape replacement text', () {
    final result = ReviewTextPatch.apply(
      '<p id="x">一段<em>错误</em><sup>1</sup></p>',
      [
        {'before': '错误', 'after': '正确<script>普通文字</script>'},
      ],
    );
    expect(result, contains('<em>正确&lt;script&gt;'));
    expect(result, contains('<sup>1</sup>'));
    for (final edit in [
      {'before': '1', 'after': '2'}, // protected superscript
      {'before': 'x', 'after': 'y'}, // attribute, never a text node
      {'before': 'missing', 'after': 'new'},
    ]) {
      expect(
        () => ReviewTextPatch.apply('<p id="x">正文<sup>1</sup></p>', [edit]),
        throwsFormatException,
      );
    }
    expect(
      () => ReviewTextPatch.apply('<p>一一</p>', [
        {'before': '一', 'after': '二'},
      ]),
      throwsFormatException,
    );
    expect(
      () => ReviewTextPatch.apply('<p>abc</p>', [
        {'before': 'ab', 'after': 'd'},
        {'before': 'bc', 'after': 'e'},
      ]),
      throwsFormatException,
    );
  });

  test('outer quote delimiters do not change verbatim evidence requirements', () {
    const source =
        'She said, "the younger children will return on Thursday, and we can rest."';
    const excerpt = 'the younger children will return on Thursday';
    for (final pair in [
      ['"', '"'],
      ["'", "'"],
      ['“', '”'],
      ['‘', '’'],
      ['「', '」'],
      ['『', '』'],
    ]) {
      expect(
        ReviewEvidenceValidator.supports(
          '${pair[0]}$excerpt${pair[1]}',
          source,
        ),
        isTrue,
      );
      expect(
        ReviewEvidenceValidator.supports(
          '${pair[0]}${excerpt.replaceFirst('younger', 'older')}${pair[1]}',
          source,
        ),
        isFalse,
      );
    }
    for (final fabricated in [
      '"$excerpt”',
      '"the younger children will return on Friday"',
      '"the younger children; will return on Thursday"',
      '" "',
      '""',
      '“the younger children will return ... she bought seven tickets”',
    ]) {
      expect(ReviewEvidenceValidator.supports(fabricated, source), isFalse);
    }
    expect(
      ReviewEvidenceValidator.supports(
        '“the younger children ... and we can rest.”',
        source,
      ),
      isTrue,
    );
    expect(
      ReviewEvidenceValidator.supports(
        '“and we can rest. ... the younger children”',
        source,
      ),
      isFalse,
    );
  });

  test('omitted quote fragments must all exist in source order', () {
    const source =
        'The bell rang for tea. After a long passage, they ate dinner. There are only six lines.';
    expect(
      ReviewEvidenceValidator.supports(
        'The bell rang for tea ... There are only six lines.',
        source,
      ),
      isTrue,
    );
    expect(
      ReviewEvidenceValidator.supports([
        'The bell rang for tea',
        'they ate dinner',
      ], source),
      isTrue,
    );
    expect(
      ReviewEvidenceValidator.supports(
        'The bell rang for tea ... There are only seven lines.',
        source,
      ),
      isFalse,
    );
    expect(
      ReviewEvidenceValidator.supports(
        'There are only six lines. ... The bell rang for tea',
        source,
      ),
      isFalse,
    );
    expect(ReviewEvidenceValidator.supports('The ... tea', source), isFalse);
    expect(
      ReviewEvidenceValidator.supports(['invented quote'], source),
      isFalse,
    );
  });

  test(
    'retrieval excludes the current paragraph and reaches the following explanation',
    () {
      final index = ReviewEvidenceIndex();
      for (var i = 0; i < 12; i++) {
        index.add('They sat in the library reading different books number $i.');
      }
      const next =
          '"Oh, often," cried the little girl, looking up; "I know it quite well. It is painted in curious black letters, and is difficult to read. There are only six lines:';
      index.add(
        'Have you ever read the old prophecy on the library window?',
        after: next,
      );
      const query =
          'They finally engraved the verse from the library window on the monument.';
      index.add(query);
      final retrieved = index.retrieve(query).join();
      expect(retrieved, contains('There are only six lines'));
      expect(retrieved, isNot(contains(query)));
    },
  );

  test('query text in neighbours cannot crowd out relevant source evidence', () {
    final index = ReviewEvidenceIndex();
    const query =
        'The Duchess walked across the churchyard after the wedding. '
        'The family engraved the verse from the library window on the monument. '
        'She placed flowers on the grave and spoke with her husband.';
    for (var i = 0; i < 8; i++) {
      index.add(
        'The family attended another gathering number $i.',
        after: query,
      );
    }
    index.add(
      'Have you read the prophecy on the library window?',
      after: 'There are only six lines, written in black letters.',
    );
    index.add(query);
    expect(index.retrieve(query).join(), contains('There are only six lines'));
  });

  test('single-word recurring brands survive the whole-book source index', () {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'story.xhtml',
      bytes: utf8.encode(
        '<html><body><p>Pinkerton cleans the floor.</p><p>I trust Pinkerton.</p><p>He bought Pinkerton.</p></body></html>',
      ),
    );
    expect(
      (BookSourceIndex.build([chapter])['recurringNames'] as List)
          .cast<Map>()
          .map((e) => e['source']),
      contains('Pinkerton'),
    );
  });

  test('frequent sentence capitals do not crowd out recurring names', () {
    final openingWords = [
      for (var i = 0; i < 40; i++)
        'Opening${String.fromCharCode(97 + i ~/ 26)}${String.fromCharCode(97 + i % 26)}',
    ];
    final paragraphs = [
      for (final word in openingWords)
        for (var n = 0; n < 4; n++) '<p>$word the scene begins.</p>',
      '<p>We bought Asterford’s cleaner.</p>',
      '<p>They tried Asterford.</p>',
      '<p>I trust Asterford’s soap.</p>',
    ];
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'story.xhtml',
      bytes: utf8.encode('<html><body>${paragraphs.join()}</body></html>'),
    );
    final names = (BookSourceIndex.build([chapter])['recurringNames'] as List)
        .cast<Map>();
    expect(names.length, lessThanOrEqualTo(32));
    expect(names.map((e) => e['source']), contains('Asterford'));
  });

  test('legacy cached findings are recomputed without a paid review', () async {
    final f = fixture.Fixture();
    await f.init(sourcePrefix: 'No one waited. ');
    addTearDown(f.dispose);
    f.reviewUnchanged = true;
    final original = await helpers.run(f);
    final before = await const TranslationReviewStore().load(
      original.qualityReportPath!,
    );
    final cache = TranslationArtifactCache(f.repo.cacheStore);
    var changed = 0;
    final files = await Directory('${f.dir.path}/cache/blocks')
        .list(recursive: true)
        .where((e) => e is File && e.path.endsWith('.html'))
        .toList();
    for (final file in files) {
      final key = path.basenameWithoutExtension(file.path);
      final entry = await cache.read(key);
      if (entry?['status'] != 'reviewed') continue;
      entry!.remove('checksVersion');
      entry.remove('knownTerms');
      entry['findings'] = [
        {'code': 'number', 'detail': 'Old false positive for no one.'},
      ];
      await cache.write(key, entry);
      changed++;
    }
    expect(changed, 2);
    final result = await helpers.run(f);
    expect(result.apiUsage['requests'], 0);
    final report = await const TranslationReviewStore().load(
      result.qualityReportPath!,
    );
    expect(report['findings'], before['findings']);
    expect(
      jsonEncode(report['findings']),
      isNot(contains('Old false positive')),
    );
  });

  test(
    'manual corrections cover model omissions, preserve provenance, and undo exactly',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.reviewUnchanged = true;
      final result = await helpers.run(f);
      const store = TranslationReviewStore();
      final report = await store.load(result.qualityReportPath!);
      final blocks = await store.manualBlocks(report);
      final block = blocks.first, key = block['key']!;
      final edited = TranslationReviewStore.editText(
        block['beforeHtml']!,
        '她先欢喜，随后伤心落泪。',
      );
      final calls = f.requests.length;
      final output = await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {},
        manualEdits: {key: edited},
        manuallyReviewed: {key},
      );
      expect(helpers.story(output), contains('随后伤心落泪'));
      final saved = await store.load(result.qualityReportPath!);
      expect(saved['manuallyReviewed'], [key]);
      expect((saved['manualEdits'] as Map)[key], edited);
      expect(
        saved['reviewedBlocks'],
        report['reviewedBlocks'],
        reason: 'Human editing must not fabricate model coverage.',
      );
      final undo = await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {},
      );
      expect(helpers.story(undo), helpers.story(result.job.outputPath));
      expect(f.requests.length, calls);
      await expectLater(
        store.export(
          reportPath: result.qualityReportPath!,
          baseOutputPath: result.job.outputPath,
          accepted: {},
          manualEdits: {'missing': edited},
        ),
        throwsFormatException,
      );
      await expectLater(
        store.export(
          reportPath: result.qualityReportPath!,
          baseOutputPath: result.job.outputPath,
          accepted: {},
          manualEdits: {key: '<p><script>alert(1)</script></p>'},
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'manual review closes unresolved items without changing model failure evidence',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.malformedReview = true;
      final result = await helpers.run(f);
      const store = TranslationReviewStore();
      final report = await store.load(result.qualityReportPath!);
      final blocks = await store.manualBlocks(report);
      await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {},
        manuallyReviewed: blocks.map((b) => b['key']!).toSet(),
      );
      final saved = await store.load(result.qualityReportPath!);
      expect(saved['unreviewed'], report['unreviewed']);
      expect(saved['unreviewedReasons'], report['unreviewedReasons']);
      expect(saved['unresolvedAfterManualReview'], isEmpty);
      expect(saved['reviewedBlocks'], 0);
    },
  );
}
