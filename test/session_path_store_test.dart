import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/session_path_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
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

    expect(paths.inputPath, r'C:\Books\demo.epub');
    expect(paths.outputDirectory, r'C:\Out');
  });
}
