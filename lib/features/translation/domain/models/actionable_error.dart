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

  static ActionableError? fromMessage(
    String message, {
    bool isChinese = false,
  }) {
    final String lower = message.toLowerCase();
    if (lower.contains('api key') ||
        lower.contains('401') ||
        lower.contains('unauthorized') ||
        lower.contains('403') ||
        lower.contains('required before translation')) {
      return ActionableError(
        title: isChinese ? 'API 配置问题' : 'API configuration issue',
        message: message,
        actionLabel: isChinese ? '打开设置' : 'Open settings',
        actionKind: ActionableErrorKind.openSettings,
      );
    }
    if (lower.contains('429') ||
        lower.contains('rate limit') ||
        lower.contains('too many requests')) {
      return ActionableError(
        title: isChinese ? '触发限流' : 'Rate limited',
        message: message,
        actionLabel: isChinese ? '降低并发' : 'Reduce concurrency',
        actionKind: ActionableErrorKind.reduceConcurrency,
      );
    }
    if (lower.contains('inspection failed') || lower.contains('inspect')) {
      return ActionableError(
        title: isChinese ? '检查失败' : 'Inspection failed',
        message: message,
        actionLabel: isChinese ? '重新检查' : 'Inspect again',
        actionKind: ActionableErrorKind.retryInspection,
      );
    }
    if (lower.contains('translation failed') ||
        lower.contains('translate') ||
        lower.contains('cancelled')) {
      return ActionableError(
        title: isChinese ? '翻译中断' : 'Translation interrupted',
        message: message,
        actionLabel: isChinese ? '继续翻译' : 'Resume translation',
        actionKind: ActionableErrorKind.retryTranslation,
      );
    }
    if (message.trim().isEmpty) {
      return null;
    }
    return ActionableError(
      title: isChinese ? '运行出错' : 'Run error',
      message: message,
      actionLabel: isChinese ? '知道了' : 'Dismiss',
      actionKind: ActionableErrorKind.dismiss,
    );
  }
}
