import 'app_strings.dart';

extension BookBudgetStrings on AppStrings {
  String get bookTokenBudget =>
      isChinese ? '整本书 Token 预算' : 'Whole-book token budget';
  String get bookBudgetUnlimitedHint =>
      isChinese ? '留空或输入 0 表示不限额' : 'Leave blank or enter 0 for unlimited';
  String get bookBudgetHelp => isChinese
      ? '按当前 EPUB 版本和目标语言累计计入输入与输出 Token。下一次请求预计超过阈值时暂停，已保存的译文可继续使用。'
      : 'Counts input and output tokens across attempts for this EPUB revision and target language. The app pauses if the next request is estimated to exceed the threshold and saves completed work.';
  String get invalidBookBudget => isChinese
      ? '请输入 0 至 10 亿之间的整数。'
      : 'Enter a whole number between 0 and 1,000,000,000.';
  String get budgetPaused => isChinese ? '因预算暂停' : 'Paused at token budget';
  String get budgetPausedBody => isChinese
      ? '已保存通过检查的译文。可调整预算后继续。'
      : 'Validated translations are saved. Adjust the budget to continue.';
  String get adjustBookBudget =>
      isChinese ? '调整 Token 预算' : 'Adjust token budget';
  String get adjustBudgetAndResume =>
      isChinese ? '调整预算并继续' : 'Adjust budget and resume';
  String get useSuggestedBookBudget =>
      isChinese ? '使用建议预算' : 'Use suggested budget';
  String get resumeBookTranslation => isChinese ? '继续翻译' : 'Resume translation';
  String get resumeBookWithBudget =>
      isChinese ? '保存预算并继续' : 'Save budget and resume';
  String suggestedBookBudget(int threshold) => isChinese
      ? '按当前估算，下次请求至少需要 $threshold Token 的总预算。'
      : 'The estimated total budget needed for the next request is at least $threshold tokens.';
  String get savedBookBudgetFailed => isChinese
      ? '未能保存 Token 预算，请重试。'
      : 'Could not save the token budget. Try again.';
  String estimatedBookTokenRange(
    int low,
    int high, {
    required bool usesObservedUsage,
  }) => isChinese
      ? '${usesObservedUsage ? '按当前用量估算' : '全书预估用量'} $low–$high Token'
      : '${usesObservedUsage ? 'Updated estimate' : 'Estimated book total'} $low–$high tokens';
  String bookBudgetThreshold(int limit) =>
      isChinese ? '预算阈值 $limit Token' : 'Budget threshold $limit tokens';
  String bookAccountedTokens(int count) => isChinese
      ? '累计计入预算约 $count Token'
      : 'Approx. $count tokens counted toward budget';
  String bookEarlierTokens(int count) => isChinese
      ? '含先前运行约 $count Token'
      : 'Includes approx. $count tokens from earlier attempts';
  String bookUsageUnreported(int count, int estimate) => isChinese
      ? '$count 次请求未报告完整的输入／输出用量，预算计入估算 $estimate Token。'
      : '$count requests did not report a full input/output breakdown. The budget counts an estimated $estimate tokens for them.';
  String bookUsageUnknown(int count) => isChinese
      ? '$count 次请求未报告完整的输入／输出用量。'
      : '$count requests did not report a full input/output breakdown.';
  String bookProviderTotal(int tokens, int requests) => isChinese
      ? '$requests 次请求报告总计 $tokens Token。'
      : 'Provider total $tokens tokens across $requests reporting requests.';
  String bookReasoningTokens(int count) => isChinese
      ? '服务商报告的推理用量 $count Token，已包含在总用量中。'
      : 'Provider-reported reasoning $count tokens, included in the total.';
  String bookPromptCacheTokens(int count) => isChinese
      ? '服务商报告的命中缓存输入 $count Token，已包含在输入用量中。'
      : 'Provider-reported cached input $count tokens, included in input usage.';
}
