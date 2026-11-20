import '../../../shared/localization/app_strings.dart';

extension WorkbenchStrings on AppStrings {
  String get releaseToImportEpub =>
      isChinese ? '松开以导入 EPUB' : 'Release to import EPUB';

  String reviewBudgetSummary(int requests, int tokens) => isChinese
      ? '复核预算 · 最多 $requests 次 · 预估 $tokens tokens'
      : 'Review budget · Up to $requests calls · Est. $tokens tokens';

  String get reviewBudgetDescription => isChinese
      ? '达到任一上限后，保留译文并标记尚未完成的复核。'
      : 'When either limit is reached, the translation is kept and unfinished checks are flagged.';

  String get warningReviewSummary => isChinese
      ? '译本已导出。请查看待确认建议或尚未完成的检查。'
      : 'The EPUB is ready. Check pending suggestions or unfinished reviews.';

  String get previewTranslationWarnings =>
      isChinese ? '预览章节' : 'Preview chapters';

  String get reviewTranslationWarnings =>
      isChinese ? '查看检查结果' : 'Review warnings';

  String get editStyleProfile => isChinese ? '编辑风格档案' : 'Edit style profile';
}
