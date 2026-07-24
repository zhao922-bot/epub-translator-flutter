import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/repair_epub_xhtml.dart <input.epub> <output.epub>',
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
  final Map<String, String> replacements = <String, String>{};
  for (final MapEntry<String, List<int>> entry in files.entries) {
    final String extension = path.extension(entry.key).toLowerCase();
    if (extension != '.htm' && extension != '.html' && extension != '.xhtml') {
      continue;
    }
    final String source = utf8.decode(entry.value, allowMalformed: true);
    final String repaired = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
      source,
    );
    if (repaired != source) {
      replacements[entry.key] = repaired;
    }
  }

  await EpubIsolateWorker.writeTranslatedEpub(
    inputPath: inputPath,
    outputFilePath: outputPath,
    translatedHtmlByPath: replacements,
  );
  stdout.writeln('Repaired ${replacements.length} XHTML files: $outputPath');
}
