import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/io/atomic_file_writer.dart';
import '../../../shared/platform/platform_utils.dart';

/// Remembers the last EPUB input path and output directory across sessions.
class SessionPathStore {
  SessionPathStore({this.fileProvider});

  final Future<File> Function()? fileProvider;

  Future<({String inputPath, String outputDirectory})> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return (inputPath: '', outputDirectory: '');
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return (inputPath: '', outputDirectory: '');
      }
      return (
        inputPath: (decoded['inputPath'] as String?)?.trim() ?? '',
        outputDirectory: (decoded['outputDirectory'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      return (inputPath: '', outputDirectory: '');
    }
  }

  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await writeFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(<String, String>{
        'inputPath': inputPath,
        'outputDirectory': outputDirectory,
      }),
    );
  }

  Future<File> _file() async {
    final Future<File> Function()? provider = fileProvider;
    if (provider != null) {
      return provider();
    }
    final String root = await PlatformUtils.appDocumentsDirectory();
    return File(path.join(root, 'session_paths.json'));
  }
}
