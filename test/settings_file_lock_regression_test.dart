import 'dart:io';

import 'package:epub_translator_flutter/shared/io/settings_file_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_lock_');
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'P1-#2: the sidecar lock file is never deleted (inode identity)',
    () async {
      final file = File('${dir.path}/settings.json');
      final lockFile = File('${file.path}.lock');

      final result = await withSettingsFileLock(file, () async => 'done');
      expect(result, 'done');
      expect(
        await lockFile.exists(),
        isTrue,
        reason:
            'deleting the sidecar splits the lock identity: another process '
            'can create a new file at the same path and lock a different '
            'inode, breaking cross-process mutual exclusion',
      );

      // A second acquisition must reuse the same file, not recreate it.
      await withSettingsFileLock(file, () async {});
      expect(await lockFile.exists(), isTrue);
    },
  );

  test(
    'P1-#2: lock serializes concurrent writers in this isolate',
    () async {
      final file = File('${dir.path}/settings.json');
      final order = <int>[];
      await Future.wait([
        withSettingsFileLock(file, () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          order.add(1);
        }),
        withSettingsFileLock(file, () async {
          order.add(2);
        }),
      ]);
      expect(order, orderedEquals([1, 2]));
    },
  );
}
