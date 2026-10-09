import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/io/atomic_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('cleanStaleAtomicTempFiles', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('atomic_temp_cleanup_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'keeps fresh temp files, deletes ones older than 30 minutes',
      () async {
        final File fresh = File(path.join(tempDir.path, 'a.html.tmp.1'));
        final File old = File(path.join(tempDir.path, 'b.html.tmp.2'));
        final File regular = File(path.join(tempDir.path, 'c.html'));
        await fresh.writeAsString('fresh');
        await old.writeAsString('old');
        await regular.writeAsString('regular');
        // Simulate an orphan from a process killed 31 minutes ago.
        old.setLastModifiedSync(
          DateTime.now().subtract(const Duration(minutes: 31)),
        );

        await cleanStaleAtomicTempFiles(tempDir);

        expect(
          await fresh.exists(),
          isTrue,
          reason: 'a temp file owned by a possibly live write must survive',
        );
        expect(
          await old.exists(),
          isFalse,
          reason: 'a 31-minute-old orphan must be garbage-collected',
        );
        expect(await regular.exists(), isTrue);
      },
    );

    test('keeps a temp file just under the 30-minute threshold', () async {
      final File almostStale = File(path.join(tempDir.path, 'd.html.tmp.3'));
      await almostStale.writeAsString('almost');
      almostStale.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 29)),
      );

      await cleanStaleAtomicTempFiles(tempDir);

      expect(await almostStale.exists(), isTrue);
    });

    test('tolerates a missing directory', () async {
      await cleanStaleAtomicTempFiles(
        Directory(path.join(tempDir.path, 'does-not-exist')),
      );
    });
  });

  group('tempPathForAtomicWrite', () {
    test('generates unique names across rapid successive calls', () {
      final File target = File(path.join('some', 'dir', 'target.html'));
      final Set<String> names = <String>{
        for (int i = 0; i < 2000; i++) tempPathForAtomicWrite(target),
      };
      expect(names, hasLength(2000));
      for (final String name in names) {
        expect(name, contains('.tmp.'));
        expect(name, startsWith('${target.path}.tmp.'));
      }
    });
  });

  group('writeFileAtomically', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('atomic_race_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('concurrent same-target writes never produce torn content', () async {
      final File target = File(path.join(tempDir.path, 'target.html'));
      final List<String> payloads = List<String>.generate(
        100,
        (int i) => 'PAYLOAD_${i}_' * 64,
      );

      await Future.wait(<Future<void>>[
        for (final String payload in payloads)
          writeFileAtomically(target, payload),
      ]);

      // Every rename promotes a complete file, so the winner must be one
      // of the full payloads, never an interleaved mix.
      expect(payloads, contains(await target.readAsString()));
      final List<FileSystemEntity> leftovers = tempDir
          .listSync()
          .where((FileSystemEntity e) => e.path.contains('.tmp.'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('still commits content and cleans temp on the happy path', () async {
      final File target = File(path.join(tempDir.path, 'ok.html'));
      await writeFileAtomically(target, 'hello');
      expect(await target.readAsString(), 'hello');
      expect(
        tempDir.listSync().where((e) => e.path.contains('.tmp.')),
        isEmpty,
      );
    });
  });

  group('TranslationCacheStore.pruneCacheDirectoryForTest', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cache_prune_');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> writeBlock(String name, int ageMinutes) async {
      final File file = File(path.join(root.path, 'blocks', 'ab', name));
      await file.parent.create(recursive: true);
      await file.writeAsString('x' * 10);
      file.setLastModifiedSync(
        DateTime.now().subtract(Duration(minutes: ageMinutes)),
      );
      return file;
    }

    Future<File> writeCheckpoint(String name, int ageMinutes) async {
      final File file = File(path.join(root.path, 'jobs', name));
      await file.parent.create(recursive: true);
      await file.writeAsString('{"checkpoint":true}');
      file.setLastModifiedSync(
        DateTime.now().subtract(Duration(minutes: ageMinutes)),
      );
      return file;
    }

    test(
      'never evicts jobs/ checkpoints, even when they are the oldest',
      () async {
        final File oldestBlock = await writeBlock('oldest.html', 120);
        final File midBlock = await writeBlock('mid.html', 60);
        final File newBlock = await writeBlock('new.html', 10);
        final File checkpoint = await writeCheckpoint('job1.json', 180);

        // 3 blocks x 10 bytes = 30 > 25 cap; target is 22, so only the oldest
        // block must go. The checkpoint is the oldest file overall but lives
        // under jobs/ and must survive.
        await TranslationCacheStore().pruneCacheDirectoryForTest(
          root,
          maxBytes: 25,
        );

        expect(await oldestBlock.exists(), isFalse);
        expect(await midBlock.exists(), isTrue);
        expect(await newBlock.exists(), isTrue);
        expect(
          await checkpoint.exists(),
          isTrue,
          reason: 'a resume checkpoint must never be evicted',
        );
      },
    );

    test('jobs/ bytes do not count toward the size cap', () async {
      final File block = await writeBlock('only.html', 5);
      final File checkpoint = await writeCheckpoint('job1.json', 120);
      await checkpoint.writeAsString('y' * 1000);

      // blocks total = 10 bytes < 20 cap; the 1000-byte checkpoint must not
      // trigger any eviction.
      await TranslationCacheStore().pruneCacheDirectoryForTest(
        root,
        maxBytes: 20,
      );

      expect(await block.exists(), isTrue);
      expect(await checkpoint.exists(), isTrue);
    });

    test(
      'sweeps orphan temps across unused shards before evicting blocks',
      () async {
        final block = await writeBlock('valid.html', 120);
        final stale = File(path.join(root.path, 'blocks', 'unused', 'x.tmp.1'));
        await stale.parent.create(recursive: true);
        await stale.writeAsString('x' * 1000);
        await stale.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 31)),
        );
        final fresh = await writeBlock('fresh.html.tmp.2', 0);
        final jobTemp = await writeCheckpoint('job.json.tmp.3', 31);
        final store = TranslationCacheStore();
        await store.pruneCacheDirectoryForTest(root, maxBytes: 25);
        expect(await stale.exists(), isFalse);
        expect(await jobTemp.exists(), isFalse);
        expect(await block.exists(), isTrue);
        expect(await fresh.exists(), isTrue);
        // A later maintenance pass must sweep again, even without shard writes.
        await fresh.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 31)),
        );
        await store.pruneCacheDirectoryForTest(root, maxBytes: 25);
        expect(await fresh.exists(), isFalse);
        expect(await block.exists(), isTrue);
      },
    );

    test('does nothing when blocks/ are under the cap', () async {
      final File block = await writeBlock('small.html', 5);
      final File checkpoint = await writeCheckpoint('job1.json', 5);

      await TranslationCacheStore().pruneCacheDirectoryForTest(
        root,
        maxBytes: 1024,
      );

      expect(await block.exists(), isTrue);
      expect(await checkpoint.exists(), isTrue);
    });
  });
  group('TranslationCacheStore.pruneJobCheckpointsForTest', () {
    late Directory root;
    late Directory jobsDir;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('job_checkpoints_');
      jobsDir = Directory(path.join(root.path, 'jobs'));
      await jobsDir.create(recursive: true);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<File> writeCheckpoint(String name, int ageMinutes) async {
      final File file = File(path.join(jobsDir.path, name));
      await file.writeAsString('{"job":"$name"}');
      file.setLastModifiedSync(
        DateTime.now().subtract(Duration(minutes: ageMinutes)),
      );
      return file;
    }

    test('prunes the oldest checkpoints beyond the cap', () async {
      final List<File> files = <File>[];
      for (int i = 0; i < 25; i++) {
        files.add(await writeCheckpoint('job$i.json', 25 - i));
      }

      await TranslationCacheStore().pruneJobCheckpointsForTest(
        jobsDir,
        maxCheckpoints: 20,
      );

      for (int i = 0; i < 5; i++) {
        expect(
          await files[i].exists(),
          isFalse,
          reason: 'the oldest checkpoints must be pruned',
        );
      }
      for (int i = 5; i < 25; i++) {
        expect(
          await files[i].exists(),
          isTrue,
          reason: 'the newest checkpoints must be kept',
        );
      }
    });

    test('does nothing when under the cap', () async {
      final File checkpoint = await writeCheckpoint('a.json', 10);

      await TranslationCacheStore().pruneJobCheckpointsForTest(
        jobsDir,
        maxCheckpoints: 20,
      );

      expect(await checkpoint.exists(), isTrue);
    });

    test('leaves non-json temp files alone', () async {
      final File temp = File(path.join(jobsDir.path, 'x.json.tmp.1'));
      await temp.writeAsString('tmp');
      temp.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      for (int i = 0; i < 21; i++) {
        await writeCheckpoint('job$i.json', 30 - i);
      }

      await TranslationCacheStore().pruneJobCheckpointsForTest(
        jobsDir,
        maxCheckpoints: 20,
      );

      expect(
        await temp.exists(),
        isTrue,
        reason: 'atomic temp files are reclaimed by the temp sweeper, not here',
      );
    });

    test('tolerates a missing directory', () async {
      await TranslationCacheStore().pruneJobCheckpointsForTest(
        Directory(path.join(jobsDir.path, 'does-not-exist')),
      );
    });
  });
}
