import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/cache_restoration_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
