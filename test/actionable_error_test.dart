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

    test(
      'encoding-unsupported never offers retry, even with preferredKind',
      () {
        const String raw =
            'Unsupported text encoding "GBK" declared by OEBPS/ch1.html: '
            'only UTF-8 encoded EPUB content is supported.';
        final ActionableError? error = ActionableErrorFactory.fromMessage(
          '检查失败：$raw',
          isChinese: true,
          preferredKind: ActionableErrorKind.retryInspection,
        );
        expect(error, isNotNull);
        expect(error!.actionKind, ActionableErrorKind.dismiss);
        expect(error.actionLabel, '知道了');
        expect(error.title, '编码不受支持');
        expect(error.message, contains('转码为 UTF-8'));
      },
    );

    test('encoding-unsupported gets English hint without preferredKind', () {
      final ActionableError? error = ActionableErrorFactory.fromMessage(
        'Inspection failed: Unsupported text encoding "GBK" declared by '
        'OEBPS/ch1.html: only UTF-8 encoded EPUB content is supported.',
        isChinese: false,
      );
      expect(error, isNotNull);
      expect(error!.actionKind, ActionableErrorKind.dismiss);
      expect(error.actionLabel, 'Dismiss');
      expect(error.message, contains('Convert it to UTF-8'));
    });
  });
}
