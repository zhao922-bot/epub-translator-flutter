import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/cache_restoration_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'resolver failures escape before disk reads, including format errors',
    () async {
      for (final error in [
        StateError('resolver bug'),
        const FormatException('bad key'),
      ]) {
        int reads = 0;
        await expectLater(
          CacheRestorationScanner(
            readTranslation: (_) async {
              reads++;
              return null;
            },
          ).scan(
            chapters: [_chapterWithTwoBlocks()],
            cacheKeyFor: (_, _) => throw error,
            throwIfCancelled: () {},
          ),
          throwsA(same(error)),
        );
        expect(reads, 0);
      }
    },
  );

  test(
    'permission and encoding failures retain counts and one redacted diagnostic',
    () async {
      final diagnostics = <CacheReadDiagnostic>[];
      final stack = StackTrace.fromString(
        'cache_reader.dart:42 SECRET_KEY http://user:password@proxy:80',
      );
      final result =
          await CacheRestorationScanner(
            configuredApiKey: 'SECRET_KEY',
            onReadError: diagnostics.add,
            readTranslation: (key) async {
              Error.throwWithStackTrace(
                key == 'p1'
                    ? const FileSystemException(
                        'Permission denied SECRET_KEY',
                        '/cache',
                        OSError('Permission denied', 13),
                      )
                    : const FormatException('Invalid UTF-8'),
                stack,
              );
            },
          ).scan(
            chapters: [_chapterWithTwoBlocks()],
            cacheKeyFor: (_, block) => block.id,
            throwIfCancelled: () {},
          );
      expect(result.unreadableBlocks, 2);
      expect(result.fileSystemFailures, 1);
      expect(result.formatFailures, 1);
      expect(result.cachedBlocks, 0);
      expect(diagnostics, hasLength(1));
      expect(result.firstReadError, same(diagnostics.single));
      expect(diagnostics.single.error, contains('Permission denied'));
      expect(diagnostics.single.error, isNot(contains('SECRET_KEY')));
      expect(
        diagnostics.single.stackTrace.toString(),
        contains('cache_reader.dart:42'),
      );
      expect(
        diagnostics.single.stackTrace.toString(),
        isNot(contains('SECRET_KEY')),
      );
      expect(
        diagnostics.single.stackTrace.toString(),
        isNot(contains('password')),
      );
    },
  );

  test('prefetched programming failures rethrow with original stack', () async {
    final error = StateError('reader bug');
    final stack = StackTrace.fromString('reader.dart:123');
    final scan =
        CacheRestorationScanner(
          readTranslation: (key) async {
            if (key == 'p1') await Future<void>.delayed(Duration.zero);
            Error.throwWithStackTrace(error, stack);
          },
        ).scan(
          chapters: [_chapterWithTwoBlocks()],
          cacheKeyFor: (_, block) => block.id,
          throwIfCancelled: () {},
        );
    try {
      await scan;
      fail('Programming errors must not be downgraded');
    } catch (caught, caughtStack) {
      expect(caught, same(error));
      expect(caughtStack.toString(), stack.toString());
    }
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'fully cached 2000-chapter suffix queries never revisit cache entries',
    () async {
      const count = 2000;
      int reads = 0;
      final result =
          await CacheRestorationScanner(
            readTranslation: (_) async {
              reads++;
              return '<p>Cached</p>';
            },
          ).scan(
            chapters: [
              for (int i = 0; i < count; i++)
                _chapterWithTwoBlocks().copyWith(path: 'c$i'),
            ],
            cacheKeyFor: (chapter, block) => '${chapter.path}:${block.id}',
            throwIfCancelled: () {},
          );
      expect(result.lastPendingChapterIndex, -1);
      expect(reads, count * 2);
      // The cache map is deliberately inaccessible after restoration. Any
      // reintroduced per-chapter/per-block scan fails instead of a flaky timer.
      final indexed = CacheRestorationResult(
        translationsByChapter: _NoReadTranslations(),
        scannedBlocks: result.scannedBlocks,
        cachedBlocks: result.cachedBlocks,
        unreadableBlocks: result.unreadableBlocks,
        lastPendingChapterIndex: result.lastPendingChapterIndex,
      );
      for (int i = 0; i <= count; i++) {
        expect(indexed.hasPendingBlocksFromChapter(i), isFalse);
      }
      expect(reads, count * 2);
    },
  );

  for (final miss in ['absent', 'blank', 'unreadable']) {
    test(
      'last pending index handles $miss with zero-block chapters and a cached tail',
      () async {
        final result =
            await CacheRestorationScanner(
              readTranslation: (key) async {
                if (key == 'c2:p2') {
                  if (miss == 'unreadable') {
                    throw const FileSystemException('broken');
                  }
                  return miss == 'blank' ? '  ' : null;
                }
                return '<p>Cached</p>';
              },
            ).scan(
              chapters: [
                _chapterWithTwoBlocks().copyWith(path: 'c0', blocks: []),
                for (int i = 1; i <= 3; i++)
                  _chapterWithTwoBlocks().copyWith(path: 'c$i'),
                _chapterWithTwoBlocks().copyWith(path: 'c4', blocks: []),
              ],
              cacheKeyFor: (chapter, block) => '${chapter.path}:${block.id}',
              throwIfCancelled: () {},
            );
        expect(result.lastPendingChapterIndex, 2);
        for (int i = 0; i <= 5; i++) {
          expect(result.hasPendingBlocksFromChapter(i), i <= 2);
        }
      },
    );
  }

  test('prefetches at most four reads and merges in source order', () async {
    final gates = List.generate(24, (_) => Completer<void>());
    final requested = <int>[];
    final events = <CacheRestorationProgress>[];
    int active = 0;
    int peak = 0;
    final scanner = CacheRestorationScanner(
      readTranslation: (key) async {
        final i = int.parse(key);
        requested.add(i);
        active++;
        if (active > peak) peak = active;
        try {
          await gates[i].future;
          if (i == 5) throw const FileSystemException('unreadable');
          if (i == 6) return '   ';
          if (i == 7) return null;
          return '<p>$i</p>';
        } finally {
          active--;
        }
      },
    );
    final chapter = _chapterWithTwoBlocks().copyWith(
      blocks: List.generate(
        24,
        (i) => ExtractedBlock(
          id: '$i',
          tagName: 'p',
          sourceHtml: '<p>$i</p>',
          sourceText: '$i',
        ),
      ),
    );
    final scan = scanner.scan(
      chapters: [chapter],
      cacheKeyFor: (_, block) => block.id,
      throwIfCancelled: () {},
      onProgress: events.add,
    );
    expect(requested, [0, 1, 2, 3]);
    for (final i in [3, 2, 1]) {
      gates[i].complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(requested, [0, 1, 2, 3]);
    for (int i = 23; i >= 4; i--) {
      gates[i].complete();
    }
    gates[0].complete();
    final result = await scan;
    expect(peak, 4);
    expect(requested, List.generate(24, (i) => i));
    expect(
      result.translationsByChapter['c1']!.keys,
      List.generate(24, (i) => i).where((i) => i < 5 || i > 7).map((i) => '$i'),
    );
    expect(result.translationFor('c1', '23'), '<p>23</p>');
    expect(result.cachedBlocks, 21);
    expect(result.unreadableBlocks, 1);
    expect(events.map((e) => e.scannedBlocks), [20, 24]);
    expect(events.last.cachedBlocks, 21);
    expect(events.last.unreadableBlocks, 1);
  });

  test(
    'cancellation during reads prevents merge and further scheduling',
    () async {
      final release = Completer<void>();
      int reads = 0;
      bool cancelled = false;
      final events = <CacheRestorationProgress>[];
      final scan =
          CacheRestorationScanner(
            readTranslation: (_) async {
              reads++;
              await release.future;
              throw const FileSystemException('late read failure');
            },
          ).scan(
            chapters: List.filled(10, _chapterWithTwoBlocks()),
            cacheKeyFor: (_, block) => block.id,
            throwIfCancelled: () {
              if (cancelled) throw StateError('cancelled');
            },
            onProgress: events.add,
          );
      expect(reads, 4);
      cancelled = true;
      release.complete();
      await expectLater(scan, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(reads, 4);
      expect(events, isEmpty);
    },
  );

  test(
    'scans every block and returns cached translations by chapter and id',
    () async {
      final List<String> requestedKeys = <String>[];
      final CacheRestorationScanner scanner = CacheRestorationScanner(
        readTranslation: (String key) async {
          requestedKeys.add(key);
          return key == 'c1:p1' ? '<p>译文</p>' : null;
        },
      );
      final List<CacheRestorationProgress> events =
          <CacheRestorationProgress>[];

      final CacheRestorationResult result = await scanner.scan(
        chapters: <InspectedChapter>[_chapterWithTwoBlocks()],
        cacheKeyFor: (InspectedChapter chapter, ExtractedBlock block) =>
            '${chapter.path}:${block.id}',
        onProgress: events.add,
        throwIfCancelled: () {},
      );

      expect(requestedKeys, <String>['c1:p1', 'c1:p2']);
      expect(result.scannedBlocks, 2);
      expect(result.cachedBlocks, 1);
      expect(result.unreadableBlocks, 0);
      expect(result.translationFor('c1', 'p1'), '<p>译文</p>');
      expect(result.translationFor('c1', 'p2'), isNull);
      expect(events.last.scannedBlocks, 2);
      expect(events.last.totalBlocks, 2);
      expect(events.last.cachedBlocks, 1);
    },
  );

  test('treats empty and unreadable cache files as misses', () async {
    int reads = 0;
    final CacheRestorationResult result =
        await CacheRestorationScanner(
          readTranslation: (_) async {
            reads += 1;
            if (reads == 1) {
              throw const FileSystemException('broken cache');
            }
            return '   ';
          },
        ).scan(
          chapters: <InspectedChapter>[_chapterWithTwoBlocks()],
          cacheKeyFor: (InspectedChapter chapter, ExtractedBlock block) =>
              '${chapter.path}:${block.id}',
          throwIfCancelled: () {},
        );

    expect(result.scannedBlocks, 2);
    expect(result.cachedBlocks, 0);
    expect(result.unreadableBlocks, 1);
  });

  test('stops scanning as soon as cancellation is observed', () async {
    int reads = 0;
    int cancellationChecks = 0;
    final CacheRestorationScanner scanner = CacheRestorationScanner(
      readTranslation: (_) async {
        reads += 1;
        return null;
      },
    );

    await expectLater(
      scanner.scan(
        chapters: <InspectedChapter>[_chapterWithTwoBlocks()],
        cacheKeyFor: (InspectedChapter chapter, ExtractedBlock block) =>
            '${chapter.path}:${block.id}',
        throwIfCancelled: () {
          cancellationChecks += 1;
          if (cancellationChecks == 2) {
            throw StateError('cancelled');
          }
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(reads, 1);
  });
}

class _NoReadTranslations extends MapBase<String, Map<String, String>> {
  @override
  Map<String, String>? operator [](Object? key) =>
      throw StateError('Cache revisited');
  @override
  Iterable<String> get keys => throw StateError('Cache traversed');
  @override
  void operator []=(String key, Map<String, String> value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Map<String, String>? remove(Object? key) =>
      throw UnsupportedError('read only');
}

InspectedChapter _chapterWithTwoBlocks() {
  return const InspectedChapter(
    path: 'c1',
    title: 'Chapter 1',
    body: 'One. Two.',
    originalHtml: '<p>One.</p><p>Two.</p>',
    blocks: <ExtractedBlock>[
      ExtractedBlock(
        id: 'p1',
        tagName: 'p',
        sourceHtml: '<p>One.</p>',
        sourceText: 'One.',
      ),
      ExtractedBlock(
        id: 'p2',
        tagName: 'p',
        sourceHtml: '<p>Two.</p>',
        sourceText: 'Two.',
      ),
    ],
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );
}
