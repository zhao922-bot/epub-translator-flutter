import 'dart:io';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

/// 真实 API 译文质量冒烟（opt-in，默认 skip）。
///
/// 只验证生产批处理公开入口 [EpubTranslationRepository.translateBlockBatchForTest]
/// 对真实正文块的译文质量：非空、相对原文有变化、含汉字、无可疑长英文残留，
/// 以及返回条数与顺序。输入 EPUB 仅用于 inspect / 提取正文，**绝不修改**，
/// 也不做 EPUB repack 或回写断言。
///
/// 完整 EPUB 的 inspect/repack 由 `epub_real_path_stress_test` 覆盖；
/// 完整章节经 API 回写需另设可控预算的集成测试，本文件不声称覆盖该路径。
///
/// Required environment variables when enabled:
/// - `LIVE_TRANSLATION_E2E=1`
/// - `LIVE_TRANSLATION_API_KEY`
/// - `LIVE_TRANSLATION_EPUB_PATH`
///
/// Optional overrides:
/// - `LIVE_TRANSLATION_API_BASE_URL` (default: https://api.deepseek.com)
/// - `LIVE_TRANSLATION_MODEL` (default: deepseek-chat)
///
/// Example (PowerShell):
/// ```
/// $env:LIVE_TRANSLATION_E2E = '1'
/// $env:LIVE_TRANSLATION_API_KEY = '<your-key>'
/// $env:LIVE_TRANSLATION_EPUB_PATH = 'D:\books\sample.epub'
/// flutter test test/live_translation_e2e_test.dart --reporter expanded
/// ```
///
/// Never logs, asserts on, or embeds API secret values, full translations, or
/// original book body text.
void main() {
  final bool liveEnabled = Platform.environment['LIVE_TRANSLATION_E2E'] == '1';

  test(
    '真实 API 译文质量冒烟：批处理返回中文译文且无可疑英文残留',
    () async {
      final String apiKey = _requiredEnv('LIVE_TRANSLATION_API_KEY');
      final String epubPath = _requiredEnv('LIVE_TRANSLATION_EPUB_PATH');
      final String apiBaseUrl =
          _optionalEnv('LIVE_TRANSLATION_API_BASE_URL') ??
          'https://api.deepseek.com';
      final String model =
          _optionalEnv('LIVE_TRANSLATION_MODEL') ?? 'deepseek-chat';

      final File inputEpub = File(epubPath);
      expect(
        await inputEpub.exists(),
        isTrue,
        reason: 'LIVE_TRANSLATION_EPUB_PATH must point to an existing file.',
      );
      final int inputLengthBefore = await inputEpub.length();
      expect(inputLengthBefore, greaterThan(0));

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: apiBaseUrl,
        apiKey: apiKey,
        model: model,
        targetLanguage: 'Chinese',
      );

      final EpubTranslationRepository repository = EpubTranslationRepository();

      // inspect only: outputDirectory is required by the API but unused for writes here.
      final inspection = await repository.startJob(
        inputPath: inputEpub.path,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );

      expect(
        inspection.chapters,
        isNotEmpty,
        reason: 'Input EPUB has no chapters.',
      );

      final List<ExtractedBlock> sampleBlocks =
          _selectContentBlocksForQualityCheck(inspection.chapters);
      expect(
        sampleBlocks,
        isNotEmpty,
        reason:
            'No content-chapter blocks with at least 6 English words were found.',
      );
      expect(sampleBlocks.length, lessThanOrEqualTo(3));

      // Input must remain untouched after inspect.
      expect(await inputEpub.exists(), isTrue);
      expect(await inputEpub.length(), inputLengthBefore);

      final Dio dio = const TranslationApiClient().buildDio(config);
      final List<String> translatedHtmls = await repository
          .translateBlockBatchForTest(
            dio: dio,
            config: config,
            blocks: sampleBlocks,
          );

      expect(
        translatedHtmls.length,
        sampleBlocks.length,
        reason: 'Batch must return one HTML fragment per input block.',
      );

      for (int i = 0; i < sampleBlocks.length; i++) {
        final ExtractedBlock source = sampleBlocks[i];
        final String translatedHtml = translatedHtmls[i];
        final String translatedText = _plainTextFromHtmlFragment(
          translatedHtml,
        );
        final String normalizedOriginal = _normalizeText(source.sourceText);
        final String normalizedTranslated = _normalizeText(translatedText);

        expect(
          normalizedTranslated.isNotEmpty,
          isTrue,
          reason:
              'Block index $i id=${source.id}: empty translation '
              '(htmlLen=${translatedHtml.length}).',
        );
        expect(
          normalizedTranslated != normalizedOriginal,
          isTrue,
          reason:
              'Block index $i id=${source.id}: translation matches normalized '
              'source (srcLen=${normalizedOriginal.length}, '
              'outLen=${normalizedTranslated.length}).',
        );
        expect(
          RegExp(r'[\u3400-\u9FFF]').hasMatch(translatedText),
          isTrue,
          reason:
              'Block index $i id=${source.id}: no Han character '
              '(len=${translatedText.length}).',
        );
        expect(
          TranslationQuality.hasSuspiciousSourceResidual(
            sourceText: source.sourceText,
            translatedText: translatedText,
            targetLanguage: 'Chinese',
          ),
          isFalse,
          reason:
              'Block index $i id=${source.id}: suspicious English residual '
              '(len=${translatedText.length}).',
        );
      }

      // Input still untouched after API batch (no repack/write path).
      expect(await inputEpub.exists(), isTrue);
      expect(await inputEpub.length(), inputLengthBefore);
    },
    skip: liveEnabled
        ? false
        : 'Set LIVE_TRANSLATION_E2E=1 (plus API key and EPUB path) to run.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Up to 3 content blocks (≥6 English words), walking chapters in order.
///
/// Returns full [ExtractedBlock]s for the batch API only — never constructs
/// partial chapters for [EpubTranslationRepository.translateChapters].
List<ExtractedBlock> _selectContentBlocksForQualityCheck(
  List<InspectedChapter> chapters,
) {
  const int maxBlocks = 3;
  final List<ExtractedBlock> selected = <ExtractedBlock>[];

  for (final InspectedChapter chapter in chapters) {
    if (chapter.category != ChapterCategory.content) {
      continue;
    }

    final int remaining = maxBlocks - selected.length;
    if (remaining <= 0) {
      break;
    }

    final List<ExtractedBlock> eligible = chapter.blocks
        .where(
          (ExtractedBlock block) => _englishWordCount(block.sourceText) >= 6,
        )
        .take(remaining)
        .toList(growable: false);
    selected.addAll(eligible);
  }

  return selected;
}

String _plainTextFromHtmlFragment(String value) {
  return html_parser.parseFragment(value).text ?? '';
}

int _englishWordCount(String text) {
  return RegExp(r"[A-Za-z][A-Za-z'-]*").allMatches(text).length;
}

String _normalizeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _requiredEnv(String name) {
  final String? value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    fail('$name is required when LIVE_TRANSLATION_E2E=1.');
  }
  return value;
}

String? _optionalEnv(String name) {
  final String? value = Platform.environment[name]?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}
