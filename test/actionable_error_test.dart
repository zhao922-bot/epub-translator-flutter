import 'package:epub_translator_flutter/features/translation/domain/models/actionable_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActionableErrorFactory', () {
    test('classifies Chinese inspection failure for retry', () {
      final ActionableError? error = ActionableErrorFactory.fromMessage(
        '检查失败：网络超时',
        isChinese: true,
      );
      expect(error, isNotNull);
      expect(error!.actionKind, ActionableErrorKind.retryInspection);
      expect(error.actionLabel, '重新检查');
    });

    test('classifies Chinese translation failure for retry', () {
      final ActionableError? error = ActionableErrorFactory.fromMessage(
        '翻译失败：HTTP 500',
        isChinese: true,
      );
      expect(error, isNotNull);
      expect(error!.actionKind, ActionableErrorKind.retryTranslation);
      expect(error.actionLabel, '继续翻译');
    });

    test('preferredKind wins over message keywords', () {
      final ActionableError? error = ActionableErrorFactory.fromMessage(
        '检查失败：无关文案',
        isChinese: true,
        preferredKind: ActionableErrorKind.retryTranslation,
      );
      expect(error, isNotNull);
      expect(error!.actionKind, ActionableErrorKind.retryTranslation);
    });

    test('still classifies English inspection failure', () {
      final ActionableError? error = ActionableErrorFactory.fromMessage(
        'Inspection failed: boom',
        isChinese: false,
      );
      expect(error, isNotNull);
      expect(error!.actionKind, ActionableErrorKind.retryInspection);
    });

    test('classifies Chinese rate limit', () {
      final ActionableError? error = ActionableErrorFactory.fromMessage(
        '触发限流：请求过多',
        isChinese: true,
      );
      expect(error, isNotNull);
      expect(error!.actionKind, ActionableErrorKind.reduceConcurrency);
    });
  });
}
