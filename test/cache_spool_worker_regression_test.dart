import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/cache_restoration_scanner.dart';

void main() {
  test(
    'parallel snapshots and queued replacements preserve each chapter',
    () async {
      final spool = CacheRestorationSpool();
      try {
        await Future.wait([
          spool.save('a.xhtml', {'p-1': 'first😀'}),
          spool.save('b.xhtml', {'p-1': '另一个章节'}),
          spool.save('a.xhtml', {'p-1': 'last <T> &lt;'}),
        ]);
        final result = CacheRestorationResult(
          translationsByChapter: {},
          scannedBlocks: 2,
          cachedBlocks: 2,
          unreadableBlocks: 0,
          lastPendingChapterIndex: -1,
        );
        await Future.wait([
          spool.loadChapter(result, 'a.xhtml'),
          spool.loadChapter(result, 'b.xhtml'),
        ]);
        expect(result.translationsByChapter, {
          'a.xhtml': {'p-1': 'last <T> &lt;'},
          'b.xhtml': {'p-1': '另一个章节'},
        });
      } finally {
        await spool.dispose();
      }
    },
  );
}
