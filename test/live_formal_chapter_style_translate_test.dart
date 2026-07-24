import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';

void main() {
  test(
    'formal chapter translation with confirmed style profile',
    () async {
      final File report = File(
        r'F:\vibe coding\epub-translator-flutter-clean\work\live_formal_translate_report.txt',
      );
      final StringBuffer out = StringBuffer();
      void log(String msg) {
        out.writeln(msg);
        // ignore: avoid_print
        print(msg);
      }

      final String apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final String epubPath =
          Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final String mode =
          Platform.environment['LIVE_TRANSLATION_CHAPTER_MODE'] ?? 'target';
      // target: prefer preface/c01-like medium content chapter (~20-50 blocks)
      // smallest / median also supported via env.

      final Directory tempDir = await Directory.systemTemp.createTemp(
        'live_formal_translate_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: apiKey,
        model: 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
        residualQualityCheck: true,
        timeoutSeconds: 120,
        maxRetries: 3,
        chunkSize: 3000,
        maxConcurrent: 2,
      );

      final EpubTranslationRepository repo = EpubTranslationRepository();
      final Stopwatch sw = Stopwatch()..start();

      log('STEP inspect');
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
      );
      final List<InspectedChapter> content = inspection.chapters
          .where(
            (InspectedChapter c) =>
                c.category == ChapterCategory.content && c.blocks.isNotEmpty,
          )
          .toList(growable: false);
      expect(content, isNotEmpty);
      log(
        'INSPECT_MS=${sw.elapsedMilliseconds} chapters=${inspection.chapters.length} content=${content.length}',
      );

      log('STEP style_profile');
      final TranslationStyleProfile profile = await repo.generateStyleProfile(
        config: config,
        chapters: inspection.chapters,
      );
      expect(profile.isEmpty, isFalse);
      log(
        'STYLE genre="${profile.primaryGenre}" conf=${profile.confidence.name} '
        'tone="${profile.tone}" sentence="${profile.sentenceStyle}" '
        'rules=${profile.translationConstraints.length} avoid=${profile.avoid.length} '
        'ms=${sw.elapsedMilliseconds}',
      );
      log('STYLE_JSON=${jsonEncode(profile.toJson())}');

      final InspectedChapter selected = _selectChapter(content, mode);
      log(
        'SELECTED path=${selected.path} title="${selected.title}" '
        'blocks=${selected.blocks.length} mode=$mode',
      );

      // Translate only the selected chapter, but inject confirmed style profile.
      final List<InspectedChapter> chaptersForTranslation = <InspectedChapter>[
        selected.copyWith(includeInTranslation: true),
      ];

      log('STEP translate_chapters');
      final TranslationRunResult run = await repo.translateChapters(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
        chapters: chaptersForTranslation,
        confirmedStyleProfile: profile,
      );
      log(
        'TRANSLATE_MS=${sw.elapsedMilliseconds} status=${run.job.status.name} '
        'completedBlocks=${run.job.completedBlocks}/${run.job.totalBlocks} '
        'output=${run.job.outputPath}',
      );
      expect(File(run.job.outputPath).existsSync(), isTrue);

      log('STEP reinspect_output');
      final outputInspection = await repo.startJob(
        inputPath: run.job.outputPath,
        outputDirectory: tempDir.path,
        config: config,
      );
      final InspectedChapter outputChapter = outputInspection.chapters
          .firstWhere((InspectedChapter c) => c.path == selected.path);
      expect(outputChapter.blocks.length, selected.blocks.length);

      final Map<String, ExtractedBlock> outById = <String, ExtractedBlock>{
        for (final ExtractedBlock b in outputChapter.blocks) b.id: b,
      };

      int checked = 0;
      int residualFail = 0;
      int emptyFail = 0;
      int noHanFail = 0;
      int unchangedFail = 0;
      final List<Map<String, String>> samples = <Map<String, String>>[];

      for (final ExtractedBlock source in selected.blocks) {
        final ExtractedBlock? translated = outById[source.id];
        if (translated == null) {
          emptyFail += 1;
          continue;
        }
        final String src = source.sourceText.trim();
        final String dst = translated.sourceText.trim();
        if (dst.isEmpty) {
          emptyFail += 1;
          continue;
        }
        final bool hasEnoughEnglish =
            RegExp(r"[A-Za-z][A-Za-z'-]*").allMatches(src).length >= 6;
        if (!hasEnoughEnglish) {
          continue;
        }
        checked += 1;
        final String normSrc = src.replaceAll(RegExp(r'\s+'), ' ').trim();
        final String normDst = dst.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (normSrc == normDst) {
          unchangedFail += 1;
        }
        if (!RegExp(r'[\u3400-\u9FFF]').hasMatch(dst)) {
          noHanFail += 1;
        }
        if (TranslationQuality.hasSuspiciousSourceResidual(
          sourceText: src,
          translatedText: dst,
          targetLanguage: 'Chinese',
        )) {
          residualFail += 1;
        }

        if (samples.length < 6 && src.length >= 40) {
          samples.add(<String, String>{
            'id': source.id,
            'src': _clip(src, 220),
            'dst': _clip(dst, 220),
          });
        }
      }

      log(
        'QUALITY checked=$checked emptyFail=$emptyFail unchangedFail=$unchangedFail '
        'noHanFail=$noHanFail residualFail=$residualFail totalBlocks=${selected.blocks.length}',
      );
      log('SAMPLES=${samples.length}');
      for (int i = 0; i < samples.length; i += 1) {
        final Map<String, String> s = samples[i];
        log('--- SAMPLE ${i + 1} id=${s['id']} ---');
        log('EN: ${s['src']}');
        log('ZH: ${s['dst']}');
      }

      // Hard quality gates for this formal run.
      expect(checked, greaterThan(0));
      expect(emptyFail, 0);
      expect(unchangedFail, 0);
      expect(noHanFail, 0);
      expect(residualFail, 0);

      log('DONE totalMs=${sw.elapsedMilliseconds}');
      await report.writeAsString(out.toString());
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: liveTestSkipReason(),
  );
}

InspectedChapter _selectChapter(List<InspectedChapter> content, String mode) {
  final List<InspectedChapter> sorted = List<InspectedChapter>.of(content)
    ..sort(
      (InspectedChapter a, InspectedChapter b) =>
          a.blocks.length.compareTo(b.blocks.length),
    );
  if (mode == 'smallest') {
    return sorted.first;
  }
  if (mode == 'median') {
    return sorted[sorted.length ~/ 2];
  }

  // Prefer a medium content chapter with enough prose (20-60 blocks).
  final List<InspectedChapter> medium = sorted
      .where(
        (InspectedChapter c) => c.blocks.length >= 15 && c.blocks.length <= 60,
      )
      .toList(growable: false);
  if (medium.isNotEmpty) {
    // Prefer path containing prf/c01/c02 if available.
    for (final String key in <String>['prf', 'c01', 'c02', 'c03']) {
      for (final InspectedChapter c in medium) {
        if (c.path.toLowerCase().contains(key)) {
          return c;
        }
      }
    }
    return medium[medium.length ~/ 2];
  }
  return sorted[sorted.length ~/ 2];
}

String _clip(String value, int max) {
  final String compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= max) {
    return compact;
  }
  return '${compact.substring(0, max - 3)}...';
}
