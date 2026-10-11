import 'dart:io';
import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/infrastructure/session_path_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  for (final entry in <String, SessionPathStatus>{
    'missing': SessionPathStatus.missing,
    '{bad json': SessionPathStatus.corrupt,
    '{"inputPath":42}': SessionPathStatus.corrupt,
    '{"outputDirectory":[]}': SessionPathStatus.corrupt,
    '[]': SessionPathStatus.corrupt,
  }.entries) {
    test('classifies ${entry.key}', () async {
      final temp = await Directory.systemTemp.createTemp('session_status_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(path.join(temp.path, 'paths.json'));
      if (entry.key != 'missing') await file.writeAsString(entry.key);
      final result = await SessionPathStore(
        fileProvider: () async => file,
      ).load();
      expect(result.status, entry.value);
      expect(result.inputPath, isEmpty);
      expect(result.outputDirectory, isEmpty);
    });
  }
  test('classifies I/O read failure as unreadable', () async {
    final result = await SessionPathStore(
      fileProvider: () async => _UnreadableFile(),
    ).load();
    expect(result.status, SessionPathStatus.unreadable);
    expect(result.inputPath, isEmpty);
    expect(result.outputDirectory, isEmpty);
  });
  test('round trips last input and output paths', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'session_paths_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final File file = File(path.join(temp.path, 'session_paths.json'));
    final SessionPathStore store = SessionPathStore(
      fileProvider: () async => file,
    );

    await store.save(
      inputPath: r'C:\Books\demo.epub',
      outputDirectory: r'C:\Out',
    );
    final paths = await store.load();
    expect(paths.status, SessionPathStatus.ok);

    expect(paths.inputPath, r'C:\Books\demo.epub');
    expect(paths.outputDirectory, r'C:\Out');
  });
}

class _UnreadableFile implements File {
  @override
  Future<bool> exists() async => true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      throw const FileSystemException('Permission denied');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
