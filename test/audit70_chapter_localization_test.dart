import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';

void main() {
  test('Chinese chapter categories and counts are localized together', () {
    const zh = AppStrings(UiLanguage.chinese),
        en = AppStrings(UiLanguage.english);
    for (final entry in {
      'Content': '正文',
      'Front matter': '前言',
      'Back matter': '后记',
      'Reference': '参考资料',
      'Skip by default': '默认跳过',
    }.entries) {
      expect(zh.chapterCategoryBlocks(entry.key, 3), '${entry.value} · 3 块');
      expect(en.chapterCategoryBlocks(entry.key, 3), '${entry.key} · 3 blocks');
    }
    expect(zh.chapterCategoryBlocks('自定义', 0), '自定义 · 0 块');
  });
}
