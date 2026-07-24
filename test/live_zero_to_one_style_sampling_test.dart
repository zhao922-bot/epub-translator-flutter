import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'Zero to One style samples exclude index and span the book',
    () async {
      final String epubPath =
          Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final inspection = await EpubTranslationRepository().startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: TranslationConfig.defaults(),
      );
      final List<Map<String, String>> samples =
          EpubChapterTranslator.styleProfileSourceChaptersForTest(
            inspection.chapters,
          );
      final List<String> basenames = samples
          .map((Map<String, String> item) => path.basename(item['path']!))
          .toList(growable: false);

      // ignore: avoid_print
      print('ZERO_STYLE_SAMPLES=$basenames');
      for (final Map<String, String> sample in samples) {
        // ignore: avoid_print
        print(
          'ZERO_STYLE_SAMPLE role=${sample['role']} '
          'path=${path.basename(sample['path']!)} '
          'chars=${sample['text']!.length}',
        );
      }

      expect(basenames, hasLength(4));
      expect(basenames[0], contains('_prf_'));
      expect(basenames[1], contains('_c01_'));
      expect(basenames[2], contains('_c08_'));
      expect(basenames[3], contains('_bm1_'));
      expect(basenames.any((String value) => value.contains('_ind_')), isFalse);
      expect(basenames.any((String value) => value.contains('_toc_')), isFalse);
      expect(basenames.any((String value) => value.contains('_cop_')), isFalse);
    },
    skip: liveTestSkipReason(requireApiKey: false),
  );
}
