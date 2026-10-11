import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../shared/io/atomic_file_writer.dart';
import '../../../shared/platform/platform_utils.dart';

enum SessionPathStatus { missing, corrupt, unreadable, ok }

class SessionPathResult {
  const SessionPathResult({
    this.status = SessionPathStatus.ok,
    this.inputPath = '',
    this.outputDirectory = '',
  });

  final SessionPathStatus status;
  final String inputPath;
  final String outputDirectory;
}

/// Remembers the last EPUB input path and output directory across sessions.
class SessionPathStore {
  SessionPathStore({this.fileProvider});

  final Future<File> Function()? fileProvider;

  Future<SessionPathResult> load() async {
    final String contents;
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return const SessionPathResult(status: SessionPathStatus.missing);
      }
      contents = await file.readAsString();
    } catch (error) {
      debugPrint('SessionPathStore unreadable: $error');
      return const SessionPathResult(status: SessionPathStatus.unreadable);
    }
    try {
      final Object? decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic> ||
          (decoded['inputPath'] != null && decoded['inputPath'] is! String) ||
          (decoded['outputDirectory'] != null &&
              decoded['outputDirectory'] is! String)) {
        throw const FormatException(
          'Expected an object with string path fields',
        );
      }
      return SessionPathResult(
        inputPath: (decoded['inputPath'] as String?)?.trim() ?? '',
        outputDirectory: (decoded['outputDirectory'] as String?)?.trim() ?? '',
      );
    } on FormatException catch (error) {
      debugPrint('SessionPathStore corrupt: $error');
      return const SessionPathResult(status: SessionPathStatus.corrupt);
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
