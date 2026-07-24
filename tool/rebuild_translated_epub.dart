import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/rebuild_translated_epub.dart '
      '<translated-input.epub> <output.epub>',
    );
    exitCode = 64;
    return;
  }
  final String inputPath = path.absolute(arguments[0]);
  final String outputPath = path.absolute(arguments[1]);
  if (path.equals(inputPath, outputPath)) {
    throw ArgumentError('Input and output paths must be different.');
  }
  if (!await File(inputPath).exists()) {
    throw ArgumentError('Input EPUB does not exist: $inputPath');
  }
  if (await File(outputPath).exists()) {
    throw ArgumentError('Refusing to overwrite existing output: $outputPath');
  }

  final Map<String, List<int>> files = await EpubIsolateWorker.loadArchiveFiles(
    inputPath,
  );
  const EpubHtmlExtractor extractor = EpubHtmlExtractor();
  final List<InspectedChapter> chapters = <InspectedChapter>[];
  for (final MapEntry<String, List<int>> entry in files.entries) {
    final String extension = path.extension(entry.key).toLowerCase();
    if (extension != '.htm' && extension != '.html' && extension != '.xhtml') {
      continue;
    }
    final InspectedChapter inspected = extractor.inspectChapterBytes(
      chapterPath: entry.key,
      bytes: entry.value,
    );
    chapters.add(
      inspected.copyWith(
        includeInTranslation: true,
        blocks: inspected.blocks
            .map(
              (ExtractedBlock block) =>
                  block.copyWith(translatedHtml: block.sourceHtml),
            )
            .toList(growable: false),
      ),
    );
  }

  await EpubRepacker().writeTranslatedEpub(
    inputPath: inputPath,
    outputFilePath: outputPath,
    config: TranslationConfig.defaults(),
    chapters: chapters,
  );
  stdout.writeln('Rebuilt ${chapters.length} content documents: $outputPath');
}
