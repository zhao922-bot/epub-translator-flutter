import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';

void main() {
  test(
    'inspect sampling only',
    () async {
      final apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY'] ?? '';
      final epubPath = Platform.environment['LIVE_TRANSLATION_EPUB_PATH'] ?? '';
      expect(apiKey, isNotEmpty);
      expect(File(epubPath).existsSync(), isTrue);

      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: apiKey,
        model: 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
      );
      final repo = EpubTranslationRepository();
      final sw = Stopwatch()..start();
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      // ignore: avoid_print
      print('INSPECT_MS=${sw.elapsedMilliseconds}');
      final chapters = inspection.chapters;
      final selected = chapters.where((c) => c.includeInTranslation).toList();
      // ignore: avoid_print
      print('CHAPTERS=${chapters.length} SELECTED=${selected.length}');
      for (final c in selected.take(8)) {
        final nonEmpty = c.blocks
            .where((b) => b.sourceText.trim().isNotEmpty)
            .length;
        final sampleText = c.blocks
            .map((b) => b.sourceText)
            .where((t) => t.trim().isNotEmpty)
            .take(12)
            .join('\n')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        // ignore: avoid_print
        print(
          'CH path=${c.path} cat=${c.category.name} blocks=${c.blocks.length} '
          'nonEmpty=$nonEmpty sampleLen=${sampleText.length} title="${c.title}"',
        );
      }

      // Mirror _styleProfileSourceChapters selection logic roughly.
      final eligible = selected.where((c) => c.blocks.isNotEmpty).toList();
      final picked = <InspectedChapter>[];
      void add(InspectedChapter c) {
        if (picked.any((x) => x.path == c.path)) return;
        picked.add(c);
      }

      for (final c
          in eligible
              .where((c) => c.category == ChapterCategory.frontMatter)
              .take(2)) {
        add(c);
      }
      final content =
          eligible.where((c) => c.category == ChapterCategory.content).toList()
            ..sort((a, b) => b.blocks.length.compareTo(a.blocks.length));
      for (final c in content.take(3)) {
        add(c);
      }
      if (picked.length < 2) {
        for (final c in eligible) {
          add(c);
          if (picked.length >= 4) break;
        }
      }
      final source = picked
          .map((c) {
            final text = c.blocks
                .map((b) => b.sourceText)
                .where((t) => t.trim().isNotEmpty)
                .take(12)
                .join('\n')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            return {
              'title': c.title,
              'category': c.category.name,
              'textLen': '${text.length}',
            };
          })
          .where((m) => int.parse(m['textLen']!) > 0)
          .toList();
      // ignore: avoid_print
      print('SOURCE_COUNT=${source.length}');
      // ignore: avoid_print
      print('SOURCE=$source');
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: liveTestSkipReason(),
  );
}
