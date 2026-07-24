/// User-facing error with a primary recovery action.
class ActionableError {
  const ActionableError({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.actionKind,
  });

  final String title;
  final String message;
  final String actionLabel;
  final ActionableErrorKind actionKind;
}

enum ActionableErrorKind {
  openSettings,
  reduceConcurrency,
  retryTranslation,
  retryInspection,
  dismiss,
}

class ActionableErrorFactory {
  const ActionableErrorFactory._();

  /// Builds a recovery banner from [message].
  ///
  /// Prefer [preferredKind] for known failures so localization cannot break
  /// keyword matching. Otherwise classifies via English **and** Chinese cues.
  static ActionableError? fromMessage(
    String message, {
    bool isChinese = false,
    ActionableErrorKind? preferredKind,
  }) {
    if (message.trim().isEmpty) {
      return null;
    }

    final ActionableErrorKind kind =
        preferredKind ?? _classify(message) ?? ActionableErrorKind.dismiss;
    return _forKind(kind, message, isChinese);
  }

  static ActionableErrorKind? _classify(String message) {
    final String lower = message.toLowerCase();
    final String text = message;

    // Auth / config
    if (lower.contains('api key') ||
        lower.contains('401') ||
        lower.contains('unauthorized') ||
        lower.contains('403') ||
        lower.contains('required before translation') ||
        text.contains('API') &&
            (text.contains('密钥') ||
                text.contains('配置') ||
                text.contains('未授权')) ||
        text.contains('密钥') ||
        text.contains('未授权')) {
      return ActionableErrorKind.openSettings;
    }

    // Rate limit
    if (lower.contains('429') ||
        lower.contains('rate limit') ||
        lower.contains('too many requests') ||
        text.contains('限流') ||
        text.contains('请求过多') ||
        text.contains('频率')) {
      return ActionableErrorKind.reduceConcurrency;
    }

    // Inspection (check before generic "translate" noise)
    if (lower.contains('inspection failed') ||
        lower.contains('inspection cancelled') ||
        // Avoid matching "Inspect an EPUB before…" as a failed inspection UI
        // only when clearly a failure/cancel signal:
        (lower.contains('inspect') &&
            (lower.contains('fail') || lower.contains('cancel'))) ||
        text.contains('检查失败') ||
        text.contains('检查已取消') ||
        text.contains('检查取消')) {
      return ActionableErrorKind.retryInspection;
    }

    // Translation / cancel
    if (lower.contains('translation failed') ||
        lower.contains('translation cancelled') ||
        lower.contains('translate') &&
            (lower.contains('fail') || lower.contains('cancel')) ||
        lower.contains('cancelled') ||
        text.contains('翻译失败') ||
        text.contains('翻译中断') ||
        text.contains('翻译已取消') ||
        text.contains('任务已取消') ||
        text.contains('已取消')) {
      return ActionableErrorKind.retryTranslation;
    }

    // Loose inspect fallback (English progress-style "inspect" without fail)
    if (lower.contains('inspection') || lower.contains('inspect')) {
      return ActionableErrorKind.retryInspection;
    }

    return null;
  }

  static ActionableError _forKind(
    ActionableErrorKind kind,
    String message,
    bool isChinese,
  ) {
    return switch (kind) {
      ActionableErrorKind.openSettings => ActionableError(
        title: isChinese ? 'API 配置问题' : 'API configuration issue',
        message: message,
        actionLabel: isChinese ? '打开设置' : 'Open settings',
        actionKind: ActionableErrorKind.openSettings,
      ),
      ActionableErrorKind.reduceConcurrency => ActionableError(
        title: isChinese ? '触发限流' : 'Rate limited',
        message: message,
        actionLabel: isChinese ? '降低并发' : 'Reduce concurrency',
        actionKind: ActionableErrorKind.reduceConcurrency,
      ),
      ActionableErrorKind.retryInspection => ActionableError(
        title: isChinese ? '检查失败' : 'Inspection failed',
        message: message,
        actionLabel: isChinese ? '重新检查' : 'Inspect again',
        actionKind: ActionableErrorKind.retryInspection,
      ),
      ActionableErrorKind.retryTranslation => ActionableError(
        title: isChinese ? '翻译中断' : 'Translation interrupted',
        message: message,
        actionLabel: isChinese ? '继续翻译' : 'Resume translation',
        actionKind: ActionableErrorKind.retryTranslation,
      ),
      ActionableErrorKind.dismiss => ActionableError(
        title: isChinese ? '运行出错' : 'Run error',
        message: message,
        actionLabel: isChinese ? '知道了' : 'Dismiss',
        actionKind: ActionableErrorKind.dismiss,
      ),
    };
  }
}
