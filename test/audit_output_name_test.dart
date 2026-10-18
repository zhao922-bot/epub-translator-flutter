import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:epub_translator_flutter/shared/io/atomic_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

void main() {
  for (final title in ['a' * 193, 'a' * 224, '中' * 224]) {
    test(
      'long ${title.startsWith('中') ? 'Unicode' : 'ASCII'} source name ${title.length} keeps report and reviewed EPUB writable',
      () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        // A 224-CJK filename itself exceeds POSIX's UTF-8 component limit.
        final inputTitle = !Platform.isWindows && title.startsWith('中')
            ? '中' * 75
            : title;
        f.book = await f.book.rename('${f.dir.path}/$inputTitle.epub');
        final result = await helpers.run(
          f,
          config: f.config.copyWith(styleProfileEnabled: false),
        );
        expect(await File(result.job.outputPath).exists(), isTrue);
        expect(result.job.reviewSuggestionCount, greaterThan(0));
        expect(await File(result.qualityReportPath!).exists(), isTrue);
        final exported = await const TranslationReviewStore().export(
          reportPath: result.qualityReportPath!,
          baseOutputPath: result.job.outputPath,
          accepted: {},
        );
        expect(await File(exported).exists(), isTrue);
        expect(exported, isNot(result.job.outputPath));
        final archive = ZipDecoder().decodeBytes(
          await File(exported).readAsBytes(),
        );
        expect(archive.findFile('story.xhtml'), isNotNull);
      },
    );
  }

  for (final windows in [true, false]) {
    test(
      'all report and atomic temporary components fit (windows=$windows)',
      () {
        int size(String value) =>
            windows ? value.length : utf8.encode(value).length;
        for (final title in ['a' * 400, '中' * 250, '😀' * 200]) {
          final name = EpubChapterTranslator.outputFileName(
            title,
            '_translated',
            windows: windows,
          );
          expect(name.runes, isNot(contains(0xfffd)));
          for (final suffix in ['', '.quality.json', '.diagnostics.json']) {
            final target = File(path.join('output', '$name$suffix'));
            expect(size(path.basename(target.path)), lessThanOrEqualTo(255));
            expect(
              size(path.basename(tempPathForAtomicWrite(target))),
              lessThanOrEqualTo(255),
            );
          }
          final reviewed = EpubChapterTranslator.outputFileName(
            path.basenameWithoutExtension(name),
            '_reviewed_1234567890123456',
            windows: windows,
          );
          expect(
            size('$reviewed.recovery.1234567890123456'),
            lessThanOrEqualTo(255),
          );
          expect(
            size('$reviewed.tmp.1234567890123456'),
            lessThanOrEqualTo(255),
          );
        }
      },
    );
  }
}
