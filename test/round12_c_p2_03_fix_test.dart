import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

const _japanese = '今日は学校で先生と一緒に勉強しています。明日は友達と図書館で本を読みます。';
const _korean = '오늘은 학교에서 열심히 공부했습니다.';

void _expectResidual(
  String source,
  String translated,
  String target,
  bool residual,
) {
  expect(
    TranslationQuality.hasSuspiciousSourceResidual(
      sourceText: source,
      translatedText: translated,
      targetLanguage: target,
    ),
    residual,
  );
  expect(
    TranslationQuality.findSuspiciousHtmlResidual(
      sourceHtml: '<p>$source</p>',
      translatedHtml: '<p>$translated</p>',
      targetLanguage: target,
    )?.kind,
    residual ? TranslationResidualKind.longSourceText : null,
  );
  expect(
    TranslationQuality.findSuspiciousFragmentResidual(
      sourceFragment: html.parseFragment('<p>$source</p>'),
      translatedFragment: html.parseFragment('<p>$translated</p>'),
      targetLanguage: target,
    )?.kind,
    residual ? TranslationResidualKind.longSourceText : null,
  );
}

void main() {
  test('P2-03 汉字与假名交错正文边界样本一致性验证', () {
    _expectResidual(_japanese, _japanese, 'Chinese', true);
  });

  test('P2-03 带词间空格的韩文正文边界样本一致性验证', () {
    _expectResidual(_korean, _korean, 'Japanese', true);
  });

  test('P2-03 共享汉字及目标语言正文一致性验证', () {
    for (final target in ['Chinese', 'Japanese', 'Korean']) {
      for (final title in ['中国古代文学作品选集', '東京都立中央図書館', '𠀀𠀁𠀂𠀃𠀄𠀅𠀆𠀇']) {
        _expectResidual(title, title, target, false);
      }
    }
    _expectResidual(_japanese, _japanese, 'Japanese', false);
    _expectResidual(_korean, _korean, 'Korean', false);
  });

  test('P2-03 八字阈值与正文窗口边界样本一致性验证', () {
    _expectResidual('あ中い中う中え中お中か中き', 'あ中い中う中え中お中か中き', 'Chinese', false);
    _expectResidual('あ中い中う中え中お中か中き中く', 'あ中い中う中え中お中か中き中く', 'Chinese', true);
    _expectResidual('가 나 다 라 마 바 사', '가 나 다 라 마 바 사', 'Japanese', false);
    _expectResidual('가 나 다 라 마 바 사 아', '가 나 다 라 마 바 사 아', 'Japanese', true);
    final sparse = 'あ${'中' * 32}' * 8;
    _expectResidual(sparse, sparse, 'Chinese', false);
  });

  test('P2-03 原文逐字匹配与完整译文一致性验证', () {
    _expectResidual('あ中い中う中え中お中か中き中く', 'あ文い文う文え文お文か文き文く', 'Chinese', false);
    _expectResidual('中国古代文学作品选集', _japanese, 'Chinese', false);
    _expectResidual(_japanese, '今天在学校和老师一起学习。明天和朋友去图书馆读书。', 'Chinese', false);
    _expectResidual(_korean, '今日は学校で一生懸命勉強しました。', 'Japanese', false);
  });
}
