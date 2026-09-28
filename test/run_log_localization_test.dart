import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

TranslationRunEstimate _estimateWith(Duration? remaining) =>
    TranslationRunEstimate(
      selectedChapters: 1,
      totalBlocks: 10,
      estimatedApiBatches: 2,
      completedBlocks: 4,
      blocksPerMinute: 20,
      estimatedRemaining: remaining,
    );

void main() {
  group('remainingLabel', () {
    test('english labels', () {
      const strings = AppStrings(UiLanguage.english);
      expect(_estimateWith(null).remainingLabel(strings), 'Calculating');
      expect(
        _estimateWith(Duration.zero).remainingLabel(strings),
        'Less than 1 min',
      );
      expect(
        _estimateWith(const Duration(seconds: 45)).remainingLabel(strings),
        '45 sec',
      );
      expect(
        _estimateWith(const Duration(minutes: 5)).remainingLabel(strings),
        '5 min',
      );
      expect(
        _estimateWith(
          const Duration(minutes: 5, seconds: 30),
        ).remainingLabel(strings),
        '5 min 30 sec',
      );
    });

    test('chinese labels', () {
      const strings = AppStrings(UiLanguage.chinese);
      expect(_estimateWith(null).remainingLabel(strings), '计算中');
      expect(_estimateWith(Duration.zero).remainingLabel(strings), '不到 1 分钟');
      expect(
        _estimateWith(const Duration(seconds: 45)).remainingLabel(strings),
        '45 秒',
      );
      expect(
        _estimateWith(const Duration(minutes: 5)).remainingLabel(strings),
        '5 分钟',
      );
      expect(
        _estimateWith(
          const Duration(minutes: 5, seconds: 30),
        ).remainingLabel(strings),
        '5 分钟 30 秒',
      );
    });
  });

  group('translation run log lines', () {
    const zh = AppStrings(UiLanguage.chinese);
    const en = AppStrings(UiLanguage.english);

    test('batch progress lines are localized', () {
      expect(zh.runLogTranslatingChapter(2, 8, '第一章'), '正在翻译第 2/8 章：第一章');
      expect(
        en.runLogTranslatingChapter(2, 8, 'Chapter 1'),
        'Translating chapter 2/8: Chapter 1',
      );
      expect(
        zh.runLogBatchPerformance(3, 10, '第一章', 24, '1.20s'),
        '性能：“第一章”的 API 批次 3/10（24 块）用时 1.20s。',
      );
      expect(zh.runLogChapterCompleted(2, 8, '第一章'), '已完成第 2/8 章：第一章');
      expect(zh.runLogReusedChapterCache(7, '第一章'), '“第一章”复用了 7 个缓存块。');
    });

    test('style profile and book memory lines are localized', () {
      expect(
        zh.runLogStyleProfileGenerated('科幻 · 冷静'),
        '风格画像：科幻 · 冷静。后续批次将遵循宽松的体裁/语气约束。',
      );
      expect(
        zh.runLogStyleProfileLowConfidence('科幻'),
        '风格画像：置信度较低（科幻），保持通用翻译风格。',
      );
      expect(zh.runLogStyleProfileNoSignal, contains('信号不足'));
      expect(
        zh.runLogBookMemoryCreated('2.10s'),
        '全书记忆：已根据前言和开篇章节生成初始摘要（用时 2.10s）。',
      );
      expect(
        zh.runLogBookMemoryUpdated('第一章', '0.80s'),
        '全书记忆：“第一章”后已更新滚动摘要（用时 0.80s）。',
      );
    });

    test('cache, repack and completion lines are localized', () {
      expect(
        zh.runLogCacheRestoredPartial(6, 4),
        '复用了 6 个缓存块，本次缓存恢复未产生 API 请求。继续翻译剩余 4 个块。',
      );
      expect(zh.runLogCacheRestoredAll(10), '复用了全部 10 个块，本次运行未产生 API 请求。');
      expect(zh.runProgressRepacking, '正在重新打包 EPUB');
      expect(en.runProgressRepacking, 'Repacking EPUB');
      expect(
        zh.runLogRunComplete('/out/book_translated.epub'),
        '翻译完成。已将译后 EPUB 写入 /out/book_translated.epub',
      );
      expect(
        zh.runLogRunCompletedWithWarnings('/out/book_translated.epub'),
        contains('有警告'),
      );
      expect(zh.runLogRunFailedAllDegraded, contains('翻译失败'));
      expect(zh.runLogDegradedBlocks(3, ''), '翻译中有 3 个块保留了回退内容。');
    });

    test('performance summary lines are localized', () {
      final line = zh.runLogFinalPerformance(
        '3m 5s',
        120,
        '38.9',
        '2m 50s',
        '10.20s',
        4,
        '1.10s',
        120,
        2,
        2,
      );
      expect(line, startsWith('性能：本次翻译共用时 3m 5s。'));
      expect(line, contains('平均 38.9 块/分钟'));
      expect(line, contains('跨文件脚注共 2 个批次、2 次 API 请求。'));

      final noFootnotes = zh.runLogFinalPerformance(
        '1m 0s',
        10,
        '10.0',
        '50.00s',
        '1.00s',
        1,
        '0.10s',
        10,
        0,
        0,
      );
      expect(noFootnotes, isNot(contains('脚注')));
    });

    test('footnote batch lines keep the english singular/plural rule', () {
      expect(
        en.runLogFootnoteBatchPerformance(1, 2, 10, 1, '1.00s', '0.80s'),
        'Performance: footnote batch 1/2 (10 blocks, 1 API request) took 1.00s; API time 0.80s.',
      );
      expect(
        en.runLogFootnoteBatchPerformance(1, 2, 10, 3, '1.00s', '0.80s'),
        contains('3 API requests'),
      );
    });
  });
}
