import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  final bool liveEnabled = Platform.environment['LIVE_TRANSLATION_E2E'] == '1';

  test(
    'diagnose copyright-page p-7 with configured provider',
    () async {
      final String apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final String epubPath =
          Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: Platform.environment['LIVE_TRANSLATION_API_BASE_URL']!,
        apiKey: apiKey,
        model: Platform.environment['LIVE_TRANSLATION_MODEL']!,
        targetLanguage: 'Chinese',
        residualQualityCheck: true,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      final InspectedChapter copyrightChapter = inspection.chapters.firstWhere(
        (InspectedChapter chapter) => chapter.path.contains('_cop_'),
      );
      final ExtractedBlock block = copyrightChapter.blocks.firstWhere(
        (ExtractedBlock value) => value.id == 'p-7',
      );

      final Stopwatch stopwatch = Stopwatch()..start();
      final List<String> translated = await repository
          .translateBlockBatchForTest(
            dio: const TranslationApiClient().buildDio(config),
            config: config,
            blocks: <ExtractedBlock>[block],
          );
      stopwatch.stop();
      expect(translated, hasLength(1));
      final String translatedText =
          html_parser.parseFragment(translated.single).text?.trim() ?? '';
      final bool suspicious = TranslationQuality.hasSuspiciousSourceResidual(
        sourceText: block.sourceText,
        translatedText: translatedText,
        targetLanguage: config.targetLanguage,
      );

      // ignore: avoid_print
      print('EDGEFN_P7_SOURCE=${block.sourceText}');
      // ignore: avoid_print
      print('EDGEFN_P7_TRANSLATED=$translatedText');
      // ignore: avoid_print
      print(
        'EDGEFN_P7 elapsedMs=${stopwatch.elapsedMilliseconds} '
        'sourceLen=${block.sourceText.length} translatedLen=${translatedText.length} '
        'suspicious=$suspicious',
      );
      expect(translatedText, isNotEmpty);
      expect(suspicious, isFalse);
    },
    skip: liveEnabled ? false : 'Set live API and EPUB environment variables.',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
