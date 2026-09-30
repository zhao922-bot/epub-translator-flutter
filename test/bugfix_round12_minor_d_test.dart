import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('A: transient IO errors must not rename history aside', () {
    test(
      'FileSystemException during load returns empty, renames nothing',
      () async {
        final Directory temp = await Directory.systemTemp.createTemp(
          'history_io_error_',
        );
        addTearDown(() => temp.delete(recursive: true));
        // Simulates an antivirus/indexer lock on Windows: the file cannot be
        // read right now, but it is not corrupt.
        final JobHistoryStore store = JobHistoryStore(
          historyFileProvider: () async => throw FileSystemException(
            'simulated transient lock',
            path.join(temp.path, 'job-history.json'),
          ),
        );

        final loaded = await store.loadWithTombstone();

        expect(loaded.jobs, isEmpty);
        expect(loaded.clearedAt, 0);
        // No .bad-* backup may have been created.
        expect(temp.listSync(), isEmpty);
      },
    );

    test('genuinely corrupt files are still renamed aside', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'history_corrupt_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File historyFile = File(path.join(temp.path, 'job-history.json'));
      await historyFile.writeAsString('{not-json');
      final JobHistoryStore store = JobHistoryStore(
        historyFileProvider: () async => historyFile,
      );

      final loaded = await store.loadWithTombstone();

      expect(loaded.jobs, isEmpty);
      expect(await historyFile.exists(), isFalse);
      final List<File> badFiles = temp
          .listSync()
          .whereType<File>()
          .where((File f) => path.basename(f.path).contains('.bad-'))
          .toList();
      expect(badFiles, hasLength(1));
    });
  });

  group('B: bounded retention of history sidecars', () {
    test('corrupt backups are pruned to the newest five', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'history_prune_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File historyFile = File(path.join(temp.path, 'job-history.json'));
      // Seven stale backups with old (year-2001) microsecond timestamps.
      for (int i = 0; i < 7; i++) {
        await File(
          path.join(temp.path, 'job-history.json.bad-100000000000000$i'),
        ).writeAsString('stale');
      }
      await historyFile.writeAsString('{not-json');
      final JobHistoryStore store = JobHistoryStore(
        historyFileProvider: () async => historyFile,
      );

      await store.loadWithTombstone(); // triggers backup + prune

      final List<String> remaining =
          temp
              .listSync()
              .whereType<File>()
              .map((File f) => path.basename(f.path))
              .where((String name) => name.startsWith('job-history.json.bad-'))
              .toList()
            ..sort();
      // 7 stale + 1 fresh backup = 8, pruned down to the 5 newest.
      expect(remaining, hasLength(5));
      expect(
        remaining.any((String n) => n.endsWith('1000000000000000')),
        isFalse,
      );
      expect(
        remaining.any((String n) => n.endsWith('1000000000000001')),
        isFalse,
      );
      expect(
        remaining.any((String n) => n.endsWith('1000000000000006')),
        isTrue,
      );
    });

    test('saveMerged removes the lock sidecar on success', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'history_lock_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File historyFile = File(path.join(temp.path, 'job-history.json'));
      final JobHistoryStore store = JobHistoryStore(
        historyFileProvider: () async => historyFile,
      );

      final ({bool written, int fileClearedAt}) result = await store.saveMerged(
        clearedAtEpochMs: 0,
        merge: (List<TranslationJob> fileJobs, int fileClearedAt) => fileJobs,
      );

      expect(result.written, isTrue);
      expect(await File('${historyFile.path}.lock').exists(), isFalse);
      // The payload itself was still written.
      expect(await historyFile.exists(), isTrue);
    });
  });

  group('D: backoff and jitter on retry delays', () {
    test('non-rate-limit retries back off exponentially with jitter', () async {
      final TranslationConfig config = TranslationConfig.defaults();
      final List<Duration> delays = <Duration>[
        for (int attempt = 1; attempt <= 5; attempt++)
          TranslationApiClient.retryDelayForError(
            config,
            Exception('transient 500'),
            attempt,
            random: Random(7),
          ),
      ];
      // Default base is 5s, doubling per attempt (5,10,20,40,80) with ±25%
      // jitter; 0.75*2x > 1.25*x guarantees monotonicity across the
      // doubling steps even in the worst jitter case.
      const List<int> baseSeconds = <int>[5, 10, 20, 40, 80];
      for (int i = 0; i < delays.length; i++) {
        expect(
          delays[i].inMilliseconds,
          greaterThanOrEqualTo(baseSeconds[i] * 750),
        );
        expect(
          delays[i].inMilliseconds,
          lessThanOrEqualTo(baseSeconds[i] * 1250),
        );
        if (i > 0) {
          expect(delays[i] >= delays[i - 1], isTrue);
        }
      }
    });

    test('non-rate-limit backoff is capped', () {
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        retryDelaySeconds: 3600,
      );
      final Duration delay = TranslationApiClient.retryDelayForError(
        config,
        Exception('boom'),
        10,
        random: Random(3),
      );
      // 90s cap, then at most ±25% jitter on top.
      expect(delay.inMilliseconds, greaterThanOrEqualTo(90 * 750));
      expect(delay.inMilliseconds, lessThanOrEqualTo(90 * 1250));
    });

    test('addPositiveJitter never shortens the base', () {
      final Random random = Random(42);
      for (int i = 0; i < 50; i++) {
        final Duration jittered = TranslationApiClient.addPositiveJitter(
          const Duration(seconds: 300),
          random,
        );
        expect(jittered.inMilliseconds, greaterThanOrEqualTo(300000));
        expect(jittered.inMilliseconds, lessThanOrEqualTo(375000));
      }
      expect(
        TranslationApiClient.addPositiveJitter(Duration.zero, Random(1)),
        Duration.zero,
      );
    });

    test('retry-after jitter desynchronizes herd wakeups', () {
      DioException rateLimit(String retryAfter) {
        final RequestOptions options = RequestOptions(path: '/v1');
        return DioException(
          requestOptions: options,
          response: Response<dynamic>(
            requestOptions: options,
            statusCode: 429,
            headers: Headers.fromMap(<String, List<String>>{
              'retry-after': <String>[retryAfter],
            }),
          ),
        );
      }

      final TranslationConfig config = TranslationConfig.defaults();
      final Set<int> seen = <int>{};
      for (int seed = 0; seed < 8; seed++) {
        final Duration delay = TranslationApiClient.retryDelayForError(
          config,
          rateLimit('120'),
          1,
          random: Random(seed),
        );
        // Server said 120s: hard minimum honored, at most +25% on top.
        expect(delay.inSeconds, greaterThanOrEqualTo(120));
        expect(delay.inSeconds, lessThanOrEqualTo(150));
        seen.add(delay.inMilliseconds);
      }
      // Distinct seeds must not all collapse to one wakeup instant.
      expect(seen.length, greaterThan(1));
    });
  });
}
