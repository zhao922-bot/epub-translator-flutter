import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实 API 完整章节端到端验收（opt-in，默认 skip）。
///
/// 验证生产路径 [EpubTranslationRepository.translateChapters]：
/// inspect → 按模式选中完整 content 章节（不裁剪 blocks）→ 真实 API 翻译 →
/// 回写打包 EPUB → 对输出重新 inspect 并做按 block id 的质量断言。
///
/// 与 [live_translation_e2e_test] 互补：旧测试只覆盖最多三块的批处理质量，
/// 本文件覆盖完整章节 API + 回写打包，不重复批处理入口。
///
/// Required environment variables when enabled:
/// - `LIVE_TRANSLATION_E2E=1`
/// - `LIVE_TRANSLATION_API_KEY`
/// - `LIVE_TRANSLATION_EPUB_PATH`
///
/// Optional overrides:
/// - `LIVE_TRANSLATION_API_BASE_URL` (default: https://api.deepseek.com)
/// - `LIVE_TRANSLATION_MODEL` (default: deepseek-chat)
/// - `LIVE_TRANSLATION_CHAPTER_MODE` (default: `smallest`)
///   - `smallest`: content chapter with the fewest text blocks (ties: first wins)
///   - `median`: content chapters sorted by block count ascending; pick the
///     median-index chapter (full blocks, never trimmed)
///
/// Example (PowerShell):
/// ```
/// $env:LIVE_TRANSLATION_E2E = '1'
/// $env:LIVE_TRANSLATION_API_KEY = '<your-key>'
/// $env:LIVE_TRANSLATION_EPUB_PATH = 'D:\books\sample.epub'
/// $env:LIVE_TRANSLATION_CHAPTER_MODE = 'median'  # optional; default smallest
/// flutter test test/live_full_chapter_translation_e2e_test.dart --reporter expanded
/// ```
///
/// Never logs, asserts on, or embeds API secret values, chapter titles/paths,
/// original book body text, or full translations. Failure reasons may only
/// include block ids, counts, or lengths. Invalid chapter mode fails with the
/// mode name only.
void main() {
  final bool liveEnabled = Platform.environment['LIVE_TRANSLATION_E2E'] == '1';

  test(
    '真实 API 完整章节：translateChapters 回写后 re-inspect 块数与中文质量通过',
    () async {
      final String apiKey = _requiredEnv('LIVE_TRANSLATION_API_KEY');
      final String epubPath = _requiredEnv('LIVE_TRANSLATION_EPUB_PATH');
      final String apiBaseUrl =
          _optionalEnv('LIVE_TRANSLATION_API_BASE_URL') ??
          'https://api.deepseek.com';
      final String model =
          _optionalEnv('LIVE_TRANSLATION_MODEL') ?? 'deepseek-chat';
      final String chapterMode = _resolveChapterMode();

      final File inputEpub = File(epubPath);
      expect(
        await inputEpub.exists(),
        isTrue,
        reason: 'LIVE_TRANSLATION_EPUB_PATH must point to an existing file.',
      );
      final int inputLengthBefore = await inputEpub.length();
      expect(inputLengthBefore, greaterThan(0));

      final Directory tempDir = await Directory.systemTemp.createTemp(
        'live_full_chapter_translation_e2e_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: apiBaseUrl,
        apiKey: apiKey,
        model: model,
        targetLanguage: 'Chinese',
      );

      final EpubTranslationRepository repository = EpubTranslationRepository();
      final Stopwatch stopwatch = Stopwatch()..start();

      final inspection = await repository.startJob(
        inputPath: inputEpub.path,
        outputDirectory: tempDir.path,
        config: config,
      );

      expect(
        inspection.chapters,
        isNotEmpty,
        reason: 'Input EPUB has no chapters.',
      );
      expect(await inputEpub.exists(), isTrue);
      expect(await inputEpub.length(), inputLengthBefore);

      final InspectedChapter selectedChapter = _selectContentChapter(
        inspection.chapters,
        chapterMode,
      );
      final int selectedBlockCount = selectedChapter.blocks.length;
      expect(
        selectedBlockCount,
        greaterThan(0),
        reason: 'Selected content chapter has no text blocks.',
      );

      // Full chapter only — never trim or sample blocks for this path.
      final List<InspectedChapter> chaptersForTranslation = <InspectedChapter>[
        selectedChapter.copyWith(includeInTranslation: true),
      ];
      expect(
        chaptersForTranslation.single.blocks.length,
        selectedBlockCount,
        reason:
            'Chapter blocks must not be truncated before translateChapters.',
      );

      final TranslationRunResult run = await repository.translateChapters(
        inputPath: inputEpub.path,
        outputDirectory: tempDir.path,
        config: config,
        chapters: chaptersForTranslation,
      );

      expect(await inputEpub.exists(), isTrue);
      expect(
        await inputEpub.length(),
        inputLengthBefore,
        reason: 'Input EPUB length must remain unchanged after translation.',
      );

      final File outputEpub = File(run.job.outputPath);
      expect(
        await outputEpub.exists(),
        isTrue,
        reason: 'Translated output EPUB must exist.',
      );
      final int outputLength = await outputEpub.length();
      expect(
        outputLength,
        greaterThan(0),
        reason: 'Translated output EPUB must be non-empty (len=$outputLength).',
      );

      final outputInspection = await repository.startJob(
        inputPath: outputEpub.path,
        outputDirectory: tempDir.path,
        config: config,
      );

      final String selectedPath = selectedChapter.path;
      final List<InspectedChapter> matchingOutputChapters = outputInspection
          .chapters
          .where((InspectedChapter chapter) => chapter.path == selectedPath)
          .toList(growable: false);
      expect(
        matchingOutputChapters.length,
        1,
        reason:
            'Output inspection must retain the original chapter path '
            '(matchCount=${matchingOutputChapters.length}).',
      );

      final InspectedChapter outputChapter = matchingOutputChapters.single;
      expect(
        outputChapter.blocks.length,
        selectedBlockCount,
        reason:
            'Output chapter block count must match full input chapter '
            '(in=$selectedBlockCount, out=${outputChapter.blocks.length}).',
      );

      final Map<String, ExtractedBlock> outputBlocksById =
          <String, ExtractedBlock>{
            for (final ExtractedBlock block in outputChapter.blocks)
              block.id: block,
          };

      final List<ExtractedBlock> qualitySourceBlocks = selectedChapter.blocks
          .where(
            (ExtractedBlock block) => _englishWordCount(block.sourceText) >= 6,
          )
          .toList(growable: false);
      expect(
        qualitySourceBlocks,
        isNotEmpty,
        reason:
            'Selected chapter has no blocks with at least 6 English words '
            '(blockCount=$selectedBlockCount).',
      );

      int checkedBlockCount = 0;
      for (final ExtractedBlock source in qualitySourceBlocks) {
        final ExtractedBlock? translated = outputBlocksById[source.id];
        expect(
          translated,
          isNotNull,
          reason:
              'Missing output block id=${source.id} '
              '(outBlockCount=${outputChapter.blocks.length}).',
        );

        final String normalizedOriginal = _normalizeText(source.sourceText);
        final String normalizedTranslated = _normalizeText(
          translated!.sourceText,
        );

        expect(
          normalizedTranslated.isNotEmpty,
          isTrue,
          reason:
              'Block id=${source.id}: empty translation '
              '(len=${translated.sourceText.length}).',
        );
        expect(
          normalizedTranslated != normalizedOriginal,
          isTrue,
          reason:
              'Block id=${source.id}: translation matches normalized source '
              '(srcLen=${normalizedOriginal.length}, '
              'outLen=${normalizedTranslated.length}).',
        );
        expect(
          RegExp(r'[\u3400-\u9FFF]').hasMatch(translated.sourceText),
          isTrue,
          reason:
              'Block id=${source.id}: no Han character '
              '(len=${translated.sourceText.length}).',
        );
        expect(
          TranslationQuality.hasSuspiciousSourceResidual(
            sourceText: source.sourceText,
            translatedText: translated.sourceText,
            targetLanguage: 'Chinese',
          ),
          isFalse,
          reason:
              'Block id=${source.id}: suspicious English residual '
              '(len=${translated.sourceText.length}).',
        );
        checkedBlockCount += 1;
      }

      stopwatch.stop();

      // Safe summary only: mode, counts and duration — never titles, paths,
      // body, translations, or secrets.
      // ignore: avoid_print
      print(
        'live_full_chapter_translation_e2e: '
        'mode=$chapterMode '
        'selectedBlocks=$selectedBlockCount '
        'checkedBlocks=$checkedBlockCount '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    },
    skip: liveEnabled
        ? false
        : 'Set LIVE_TRANSLATION_E2E=1 (plus API key and EPUB path) to run.',
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

/// Resolves `LIVE_TRANSLATION_CHAPTER_MODE` (`smallest` default).
///
/// Invalid values [fail] with a message that contains only the mode name.
String _resolveChapterMode() {
  final String mode =
      _optionalEnv('LIVE_TRANSLATION_CHAPTER_MODE') ?? 'smallest';
  if (mode == 'smallest' || mode == 'median') {
    return mode;
  }
  fail(mode);
}

/// Selects a full content chapter by [mode] (never trims blocks).
InspectedChapter _selectContentChapter(
  List<InspectedChapter> chapters,
  String mode,
) {
  switch (mode) {
    case 'smallest':
      return _selectShortestContentChapterWithBlocks(chapters);
    case 'median':
      return _selectMedianContentChapterWithBlocks(chapters);
    default:
      fail(mode);
  }
}

/// Content chapter with the fewest text blocks (stable on ties: first wins).
InspectedChapter _selectShortestContentChapterWithBlocks(
  List<InspectedChapter> chapters,
) {
  InspectedChapter? selected;
  for (final InspectedChapter chapter in chapters) {
    if (chapter.category != ChapterCategory.content) {
      continue;
    }
    if (chapter.blocks.isEmpty) {
      continue;
    }
    if (selected == null || chapter.blocks.length < selected.blocks.length) {
      selected = chapter;
    }
  }

  if (selected == null) {
    fail(
      'No ChapterCategory.content chapter with text blocks was found '
      '(chapterCount=${chapters.length}).',
    );
  }
  return selected;
}

/// Content chapters sorted by block count ascending; median-index chapter.
///
/// Full chapter is returned (no block trimming). Ties keep relative order from
/// the sorted list built from the original sequence (stable sort).
InspectedChapter _selectMedianContentChapterWithBlocks(
  List<InspectedChapter> chapters,
) {
  final List<InspectedChapter> contentWithBlocks = chapters
      .where(
        (InspectedChapter chapter) =>
            chapter.category == ChapterCategory.content &&
            chapter.blocks.isNotEmpty,
      )
      .toList(growable: false);

  if (contentWithBlocks.isEmpty) {
    fail(
      'No ChapterCategory.content chapter with text blocks was found '
      '(chapterCount=${chapters.length}).',
    );
  }

  final List<InspectedChapter> sorted =
      List<InspectedChapter>.of(contentWithBlocks)..sort(
        (InspectedChapter a, InspectedChapter b) =>
            a.blocks.length.compareTo(b.blocks.length),
      );

  return sorted[sorted.length ~/ 2];
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
