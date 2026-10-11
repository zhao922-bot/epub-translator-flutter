import 'dart:io';

import 'package:epub_translator_flutter/shared/io/output_file_lock.dart';

Future<void> main(List<String> args) async {
  final output = File(args[0]);
  await OutputFileLock.run(output, () async {
    final backup = await output.rename('${output.path}.bak.process');
    stdout.writeln('backup-moved');
    await stdin.first;
    await output.writeAsString('A_COMMITTED');
    await backup.delete();
  });
}
