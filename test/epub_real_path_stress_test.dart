import 'dart:io';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// Optional integration stress test against a real local EPUB.
///
/// Set one of:
/// - `EPUB_STRESS_PATH`
/// - `EPUB_TRANSLATOR_STRESS_EPUB`
///
/// Example (PowerShell):
/// ```
/// $env:EPUB_STRESS_PATH = 'D:\books\big.epub'
/// flutter test test/epub_real_path_stress_test.dart --reporter expanded
/// ```
///
/// When unset, the test is skipped so CI stays hermetic.
void main() {
  final String? epubPath = _resolveRealEpubPath();

  test(
    'optional real EPUB: isolate open + inspect + repack',
    () async {
      if (epubPath == null) {
        // ignore: avoid_print
        print(
          'SKIP real EPUB stress: set EPUB_STRESS_PATH or '
          'EPUB_TRANSLATOR_STRESS_EPUB to a local .epub file.',
        );
        return;
      }

      final File epubFile = File(epubPath);
      expect(
        await epubFile.exists(),
        isTrue,
        reason: 'Missing file: $epubPath',
      );
      expect(path.extension(epubPath).toLowerCase(), '.epub');

      final int epubBytes = await epubFile.length();
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_real_stress_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final Stopwatch openWatch = Stopwatch()..start();
      final Map<String, List<int>> files = await EpubInspector.openArchiveFiles(
        epubFile.path,
      );
      openWatch.stop();
      expect(files, isNotEmpty);
      expect(files.containsKey('META-INF/container.xml'), isTrue);

      final Stopwatch inspectWatch = Stopwatch()..start();
      final inspection = await EpubInspector().inspect(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      inspectWatch.stop();
      expect(inspection.chapters, isNotEmpty);

      final int totalBlocks = inspection.chapters.fold<int>(
        0,
        (int sum, InspectedChapter c) => sum + c.blocks.length,
      );

      // Only rewrite chapters that already have extractable blocks, and only
      // a capped subset so huge books still finish in CI-like timeouts.
      final List<InspectedChapter> toRewrite = inspection.chapters
          .where((InspectedChapter c) => c.blocks.isNotEmpty)
          .take(12)
          .map((InspectedChapter chapter) {
            final List<ExtractedBlock> blocks = chapter.blocks
                .take(8)
                .map(
                  (ExtractedBlock block) => block.copyWith(
                    translatedHtml:
                        '<${block.tagName}>[stress] ${block.sourceText}</${block.tagName}>',
                  ),
                )
                .toList(growable: false);
            // Keep remaining blocks without translation so render is a partial rewrite.
            final List<ExtractedBlock> merged = <ExtractedBlock>[
              ...blocks,
              ...chapter.blocks.skip(blocks.length),
            ];
            return chapter.copyWith(includeInTranslation: true, blocks: merged);
          })
          .toList(growable: false);

      expect(toRewrite, isNotEmpty);

      final String outputPath = path.join(
        temp.path,
        '${path.basenameWithoutExtension(epubPath)}_stress_out.epub',
      );
      final Stopwatch repackWatch = Stopwatch()..start();
      await EpubRepacker().writeTranslatedEpub(
        inputPath: epubFile.path,
        outputFilePath: outputPath,
        config: TranslationConfig.defaults(),
        chapters: toRewrite,
      );
      repackWatch.stop();

      final File outFile = File(outputPath);
      expect(await outFile.exists(), isTrue);
      expect(await outFile.length(), greaterThan(1024));

      final Map<String, dynamic> outFiles =
          await EpubIsolateWorker.loadArchiveFiles(outputPath);
      expect(outFiles.length, greaterThanOrEqualTo(files.length ~/ 2));

      // Soft budgets for real books (generous).
      expect(openWatch.elapsed, lessThan(const Duration(minutes: 2)));
      expect(inspectWatch.elapsed, lessThan(const Duration(minutes: 5)));
      expect(repackWatch.elapsed, lessThan(const Duration(minutes: 3)));

      // ignore: avoid_print
      print(
        'real EPUB stress: path=$epubPath size=${epubBytes ~/ 1024}KB '
        'chapters=${inspection.chapters.length} blocks=$totalBlocks '
        'rewrittenChapters=${toRewrite.length} '
        'open=${openWatch.elapsedMilliseconds}ms '
        'inspect=${inspectWatch.elapsedMilliseconds}ms '
        'repack=${repackWatch.elapsedMilliseconds}ms '
        'out=${await outFile.length() ~/ 1024}KB',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

String? _resolveRealEpubPath() {
  for (final String key in const <String>[
    'EPUB_STRESS_PATH',
    'EPUB_TRANSLATOR_STRESS_EPUB',
  ]) {
    final String? value = Platform.environment[key]?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}
