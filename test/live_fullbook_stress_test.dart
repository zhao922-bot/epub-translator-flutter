import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/live_test_gate.dart';

/// Full-book stress: long-run stability + cancel/resume + cache hit.
///
/// Required env:
/// - LIVE_TRANSLATION_E2E=1
/// - LIVE_TRANSLATION_API_KEY
/// - LIVE_TRANSLATION_EPUB_PATH
///
/// Optional:
/// - LIVE_STRESS_CANCEL_AFTER_BLOCKS (default 45)
/// - LIVE_STRESS_MAX_CHAPTERS (default 0 = all selected content chapters)
void main() {
  test(
    'full-book stress: cancel/resume/cache/long-run',
    () async {
      final File report = File(
        r'F:\vibe coding\epub-translator-flutter-clean\work\live_fullbook_stress_report.txt',
      );
      final File progress = File(
        r'F:\vibe coding\epub-translator-flutter-clean\work\live_fullbook_stress_progress.txt',
      );
      final StringBuffer out = StringBuffer();
      Future<void> log(String msg) async {
        final String line = '${DateTime.now().toIso8601String()} $msg';
        out.writeln(line);
        // ignore: avoid_print
        print(msg);
        await report.writeAsString(out.toString(), encoding: utf8);
        await progress.writeAsString(
          '$line\n',
          mode: FileMode.append,
          encoding: utf8,
        );
      }

      await progress.writeAsString('', encoding: utf8);
      await report.writeAsString('', encoding: utf8);

      final String apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final String epubPath =
          Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final int cancelAfter =
          int.tryParse(
            Platform.environment['LIVE_STRESS_CANCEL_AFTER_BLOCKS'] ?? '',
          ) ??
          45;
      final int maxChapters =
          int.tryParse(
            Platform.environment['LIVE_STRESS_MAX_CHAPTERS'] ?? '',
          ) ??
          0;

      final Directory tempDir = await Directory.systemTemp.createTemp(
        'live_fullbook_stress_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl:
            Platform.environment['LIVE_TRANSLATION_API_BASE_URL'] ??
            'https://api.deepseek.com',
        apiKey: apiKey,
        model:
            Platform.environment['LIVE_TRANSLATION_MODEL'] ?? 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
        residualQualityCheck: true,
        timeoutSeconds: 180,
        maxRetries: 3,
        chunkSize: 3000,
        maxConcurrent: 2,
        outputSuffix: '_stress_fullbook',
      );

      final TranslationCacheStore cacheStore = TranslationCacheStore();
      final EpubTranslationRepository repo = EpubTranslationRepository(
        cacheStore: cacheStore,
      );
      final Stopwatch sw = Stopwatch()..start();

      await log('STEP inspect');
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
      );

      // Full-book content path: include real content chapters, exclude giant index.
      List<InspectedChapter> selected = inspection.chapters
          .where((InspectedChapter c) => c.includeInTranslation)
          .where((InspectedChapter c) => c.blocks.isNotEmpty)
          .where((InspectedChapter c) {
            final String path = c.path.toLowerCase();
            if (path.contains('ind_')) return false; // 500+ index entries
            if (path.contains('toc_')) return false;
            if (path.contains('ata_')) return false;
            return true;
          })
          .map((InspectedChapter c) => c.copyWith(includeInTranslation: true))
          .toList(growable: false);

      if (maxChapters > 0 && selected.length > maxChapters) {
        selected = selected.take(maxChapters).toList(growable: false);
      }

      final int totalBlocks = selected.fold<int>(
        0,
        (int sum, InspectedChapter c) => sum + c.blocks.length,
      );
      expect(selected, isNotEmpty);
      expect(totalBlocks, greaterThan(100));
      await log(
        'INSPECT_MS=${sw.elapsedMilliseconds} chapters=${inspection.chapters.length} '
        'selected=${selected.length} totalBlocks=$totalBlocks',
      );
      await log(
        'SELECTED=${selected.map((c) => '${p.basename(c.path)}:${c.blocks.length}').toList()}',
      );

      await log('STEP style_profile');
      final TranslationStyleProfile profile = await repo.generateStyleProfile(
        config: config,
        chapters: inspection.chapters,
      );
      expect(profile.isEmpty, isFalse);
      await log(
        'STYLE genre="${profile.primaryGenre}" conf=${profile.confidence.name} '
        'rules=${profile.translationConstraints.length} avoid=${profile.avoid.length} '
        'ms=${sw.elapsedMilliseconds}',
      );
      await log('STYLE_JSON=${jsonEncode(profile.toJson())}');

      // -------- Phase 1: run until cancel threshold --------
      await log('STEP phase1_cancel_after_$cancelAfter');
      bool cancelRequested = false;
      int phase1MaxCompleted = 0;
      String phase1LastLog = '';
      TranslationJob? phase1LastJob;

      try {
        await repo.translateChapters(
          inputPath: epubPath,
          outputDirectory: tempDir.path,
          config: config,
          chapters: selected,
          confirmedStyleProfile: profile,
          isCancelled: () => cancelRequested,
          onProgress: (TranslationJob job, String logLine) {
            phase1LastJob = job;
            phase1LastLog = logLine;
            if (job.completedBlocks > phase1MaxCompleted) {
              phase1MaxCompleted = job.completedBlocks;
            }
            if (!cancelRequested && job.completedBlocks >= cancelAfter) {
              cancelRequested = true;
              // Also cancel active token for faster abort.
              // ignore: discarded_futures
              repo.cancelJob(job.id);
            }
            // Lightweight progress file for operator visibility.
            // ignore: discarded_futures
            progress.writeAsString(
              '${DateTime.now().toIso8601String()} P1 completed=${job.completedBlocks}/${job.totalBlocks} '
              'files=${job.completedFiles}/${job.totalFiles} cached=${job.cachedBlocks} '
              'resumed=${job.resumedBlocks} chapter=${job.currentChapter ?? ""} | $logLine\n',
              mode: FileMode.append,
              encoding: utf8,
            );
          },
        );
        await log(
          'PHASE1_UNEXPECTED_COMPLETE completed=${phase1LastJob?.completedBlocks} '
          'total=${phase1LastJob?.totalBlocks}',
        );
        fail('Phase1 should have been cancelled before full completion.');
      } catch (error) {
        final bool cancelled =
            error is TranslationCancelledException ||
            error.toString().contains('cancelled') ||
            error.toString().contains('Cancel');
        await log(
          'PHASE1_ERROR type=${error.runtimeType} cancelled=$cancelled '
          'maxCompleted=$phase1MaxCompleted lastCompleted=${phase1LastJob?.completedBlocks} '
          'cached=${phase1LastJob?.cachedBlocks} resumed=${phase1LastJob?.resumedBlocks} '
          'ms=${sw.elapsedMilliseconds}',
        );
        await log('PHASE1_LAST_LOG=$phase1LastLog');
        expect(
          cancelled,
          isTrue,
          reason: 'Phase1 should abort via cancellation, got: $error',
        );
      }

      expect(phase1MaxCompleted, greaterThanOrEqualTo(cancelAfter));
      expect(phase1MaxCompleted, lessThan(totalBlocks));
      await log(
        'PHASE1_OK cancelled_after maxCompleted=$phase1MaxCompleted / $totalBlocks',
      );

      // -------- Phase 2: resume remaining (cache + long run) --------
      await log('STEP phase2_resume_to_completion');
      int phase2MaxCompleted = 0;
      int phase2CachedSeen = 0;
      int phase2ResumedSeen = 0;
      final List<String> phase2Milestones = <String>[];
      final TranslationRunResult phase2 = await repo.translateChapters(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
        chapters: selected,
        confirmedStyleProfile: profile,
        onProgress: (TranslationJob job, String logLine) {
          if (job.completedBlocks > phase2MaxCompleted) {
            phase2MaxCompleted = job.completedBlocks;
          }
          if (job.cachedBlocks > phase2CachedSeen) {
            phase2CachedSeen = job.cachedBlocks;
          }
          if (job.resumedBlocks > phase2ResumedSeen) {
            phase2ResumedSeen = job.resumedBlocks;
          }
          if (logLine.contains('Reused') ||
              logLine.contains('checkpoint') ||
              logLine.contains('Completed chapter') ||
              logLine.contains('Repacking')) {
            phase2Milestones.add(
              'c=${job.completedBlocks}/${job.totalBlocks} cache=${job.cachedBlocks} resume=${job.resumedBlocks} | $logLine',
            );
          }
          // ignore: discarded_futures
          progress.writeAsString(
            '${DateTime.now().toIso8601String()} P2 completed=${job.completedBlocks}/${job.totalBlocks} '
            'files=${job.completedFiles}/${job.totalFiles} cached=${job.cachedBlocks} '
            'resumed=${job.resumedBlocks} chapter=${job.currentChapter ?? ""} | $logLine\n',
            mode: FileMode.append,
            encoding: utf8,
          );
        },
      );

      await log(
        'PHASE2_DONE status=${phase2.job.status.name} completed=${phase2.job.completedBlocks}/${phase2.job.totalBlocks} '
        'cached=${phase2.job.cachedBlocks} resumed=${phase2.job.resumedBlocks} '
        'files=${phase2.job.completedFiles}/${phase2.job.totalFiles} ms=${sw.elapsedMilliseconds}',
      );
      await log('PHASE2_OUTPUT=${phase2.job.outputPath}');
      await log('PHASE2_MILESTONES=${phase2Milestones.length}');
      for (final String m in phase2Milestones.take(40)) {
        await log('P2_MILESTONE $m');
      }

      expect(phase2.job.status, TranslationJobStatus.completed);
      expect(phase2.job.completedBlocks, totalBlocks);
      expect(phase2.job.totalBlocks, totalBlocks);
      expect(
        phase2.job.cachedBlocks,
        greaterThanOrEqualTo(cancelAfter),
        reason:
            'Resume run should reuse at least the blocks translated before cancel.',
      );
      expect(
        phase2.job.resumedBlocks,
        greaterThan(0),
        reason:
            'Resume run should count resumed cache hits when checkpoint exists.',
      );
      expect(File(phase2.job.outputPath).existsSync(), isTrue);
      expect(File(phase2.job.outputPath).lengthSync(), greaterThan(0));

      // -------- Phase 3: full cache hit rerun --------
      await log('STEP phase3_full_cache_rerun');
      final Stopwatch phase3Sw = Stopwatch()..start();
      int phase3CachedSeen = 0;
      final TranslationRunResult phase3 = await repo.translateChapters(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
        chapters: selected,
        confirmedStyleProfile: profile,
        onProgress: (TranslationJob job, String logLine) {
          if (job.cachedBlocks > phase3CachedSeen) {
            phase3CachedSeen = job.cachedBlocks;
          }
          // ignore: discarded_futures
          progress.writeAsString(
            '${DateTime.now().toIso8601String()} P3 completed=${job.completedBlocks}/${job.totalBlocks} '
            'cached=${job.cachedBlocks} resumed=${job.resumedBlocks} | $logLine\n',
            mode: FileMode.append,
            encoding: utf8,
          );
        },
      );
      phase3Sw.stop();
      await log(
        'PHASE3_DONE status=${phase3.job.status.name} completed=${phase3.job.completedBlocks}/${phase3.job.totalBlocks} '
        'cached=${phase3.job.cachedBlocks} resumed=${phase3.job.resumedBlocks} '
        'elapsedMs=${phase3Sw.elapsedMilliseconds} ms=${sw.elapsedMilliseconds}',
      );

      expect(phase3.job.status, TranslationJobStatus.completed);
      expect(phase3.job.completedBlocks, totalBlocks);
      expect(
        phase3.job.cachedBlocks,
        greaterThanOrEqualTo((totalBlocks * 0.95).floor()),
        reason:
            'Third run should be almost fully served from block cache '
            '(cached=${phase3.job.cachedBlocks}, total=$totalBlocks).',
      );
      // Full cache rerun should be much faster than multi-minute API long run.
      expect(
        phase3Sw.elapsedMilliseconds,
        lessThan(120000),
        reason: 'Full-cache rerun should finish under 2 minutes.',
      );

      // -------- Quality sample on output --------
      await log('STEP quality_sample_on_output');
      final outputInspection = await repo.startJob(
        inputPath: phase2.job.outputPath,
        outputDirectory: tempDir.path,
        config: config,
      );
      final Map<String, InspectedChapter> outByPath =
          <String, InspectedChapter>{
            for (final InspectedChapter c in outputInspection.chapters)
              c.path: c,
          };

      int sampleChapters = 0;
      int checked = 0;
      int residualFail = 0;
      int emptyFail = 0;
      int noHanFail = 0;
      int unchangedFail = 0;
      final List<Map<String, String>> samples = <Map<String, String>>[];

      for (final InspectedChapter sourceChapter in selected) {
        // Skip tiny front-matter-like files for quality sampling.
        if (sourceChapter.blocks.length < 15) continue;
        final InspectedChapter? outChapter = outByPath[sourceChapter.path];
        if (outChapter == null) {
          emptyFail += 1;
          continue;
        }
        sampleChapters += 1;
        final Map<String, ExtractedBlock> outBlocks = <String, ExtractedBlock>{
          for (final ExtractedBlock b in outChapter.blocks) b.id: b,
        };
        int chapterChecked = 0;
        for (final ExtractedBlock source in sourceChapter.blocks) {
          final int englishWords = RegExp(
            r"[A-Za-z][A-Za-z'-]*",
          ).allMatches(source.sourceText).length;
          if (englishWords < 8) continue;
          final ExtractedBlock? translated = outBlocks[source.id];
          if (translated == null || translated.sourceText.trim().isEmpty) {
            emptyFail += 1;
            continue;
          }
          final String src = source.sourceText.trim();
          final String dst = translated.sourceText.trim();
          checked += 1;
          chapterChecked += 1;
          final String normSrc = src.replaceAll(RegExp(r'\s+'), ' ');
          final String normDst = dst.replaceAll(RegExp(r'\s+'), ' ');
          if (normSrc == normDst) unchangedFail += 1;
          if (!RegExp(r'[\u3400-\u9FFF]').hasMatch(dst)) noHanFail += 1;
          if (TranslationQuality.hasSuspiciousSourceResidual(
            sourceText: src,
            translatedText: dst,
            targetLanguage: 'Chinese',
          )) {
            residualFail += 1;
          }
          if (samples.length < 6 && src.length >= 120) {
            samples.add(<String, String>{
              'chapter': p.basename(sourceChapter.path),
              'id': source.id,
              'src': _clip(src, 280),
              'dst': _clip(dst, 280),
            });
          }
          if (chapterChecked >= 4) break; // light sample per chapter
        }
        if (sampleChapters >= 6) break;
      }

      await log(
        'QUALITY sampleChapters=$sampleChapters checked=$checked emptyFail=$emptyFail '
        'unchangedFail=$unchangedFail noHanFail=$noHanFail residualFail=$residualFail',
      );
      for (int i = 0; i < samples.length; i += 1) {
        final Map<String, String> s = samples[i];
        await log('--- SAMPLE ${i + 1} ${s['chapter']} id=${s['id']} ---');
        await log('EN: ${s['src']}');
        await log('ZH: ${s['dst']}');
      }

      expect(checked, greaterThan(0));
      expect(emptyFail, 0);
      expect(unchangedFail, 0);
      expect(noHanFail, 0);
      expect(residualFail, 0);

      await log(
        'SUMMARY phase1_cancel_at=$phase1MaxCompleted phase2_cached=${phase2.job.cachedBlocks} '
        'phase2_resumed=${phase2.job.resumedBlocks} phase3_cached=${phase3.job.cachedBlocks} '
        'phase3_ms=${phase3Sw.elapsedMilliseconds} total_ms=${sw.elapsedMilliseconds} '
        'selected_chapters=${selected.length} total_blocks=$totalBlocks',
      );
      await log('DONE');
    },
    timeout: const Timeout(Duration(hours: 2)),
    skip: liveTestSkipReason(),
  );
}

String _clip(String value, int max) {
  final String compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= max) return compact;
  return '${compact.substring(0, max - 3)}...';
}
