import 'dart:async';

import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_work_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('idle worker claims next item before a slow sibling finishes', () async {
    final slow = Completer<void>();
    final thirdStarted = Completer<void>();
    final started = <int>[];
    final result = const TranslationWorkQueue().map<int, int>(
      [0, 1, 2, 3],
      concurrency: 2,
      process: (item, index) async {
        started.add(item);
        if (item == 0) await slow.future;
        if (item == 2) thirdStarted.complete();
        return item * 10;
      },
    );
    await thirdStarted.future.timeout(const Duration(seconds: 1));
    expect(slow.isCompleted, isFalse);
    expect(started, containsAll([0, 1, 2]));
    slow.complete();
    expect(await result, [0, 10, 20, 30]);
  });

  test(
    'fatal error stops new work and drains successful in-flight work',
    () async {
      final release = Completer<void>();
      final failed = Completer<void>();
      final failure = StateError('fatal');
      final started = <int>[];
      bool persisted = false;
      final result = const TranslationWorkQueue().map<int, int>(
        [0, 1, 2, 3],
        concurrency: 2,
        process: (item, index) async {
          started.add(item);
          if (item == 0) {
            await release.future;
            persisted = true;
            return item;
          }
          failed.complete();
          throw failure;
        },
      );
      final expectation = expectLater(result, throwsA(same(failure)));
      await failed.future;
      await Future<void>.delayed(Duration.zero);
      expect(persisted, isFalse);
      release.complete();
      await expectation;
      expect(persisted, isTrue);
      expect(started, [0, 1]);
    },
  );

  test('callback cancellation prevents claiming more work', () async {
    bool cancelled = false;
    final started = <int>[];
    await expectLater(
      const TranslationWorkQueue().map<int, int>(
        [0, 1, 2],
        concurrency: 1,
        throwIfCancelled: () {
          if (cancelled) throw const TranslationCancelledException();
        },
        process: (item, index) async {
          started.add(item);
          cancelled = true;
          return item;
        },
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(started, [0]);
  });

  test(
    'batch and child fallback requests share permits without deadlock',
    () async {
      final budget = TranslationRequestBudget(3);
      int active = 0;
      int peak = 0;
      Future<int> request() => budget.run(() async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return 1;
      });
      final results = await const TranslationWorkQueue()
          .map<int, List<int>>(
            [0, 1, 2, 3, 4],
            concurrency: 3,
            process: (item, index) async {
              await request();
              return const TranslationWorkQueue().map<int, int>(
                [0, 1, 2, 3],
                concurrency: 3,
                process: (_, _) => request(),
              );
            },
          )
          .timeout(const Duration(seconds: 2));
      expect(results, hasLength(5));
      expect(peak, 3);
      expect(active, 0);
    },
  );

  test(
    'failed requests release permits and nonpositive limits still run',
    () async {
      final budget = TranslationRequestBudget(0);
      await expectLater(
        budget.run<void>(() async => throw StateError('failure')),
        throwsStateError,
      );
      expect(await budget.run(() async => 42), 42);
      expect(
        await const TranslationWorkQueue().map<int, int>(
          [1, 2],
          concurrency: 0,
          process: (item, index) async => item,
        ),
        [1, 2],
      );
    },
  );
}
