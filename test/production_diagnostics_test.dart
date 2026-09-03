import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production translator has no hard-coded sensitive diagnostic sink', () {
    final String source = File(
      'lib/features/translation/infrastructure/epub/'
      'epub_chapter_translator.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('_p13_failure_diag.log')));
    expect(source, isNot(contains('RAW=\$lastCleaned')));
    expect(source, isNot(contains('SOURCE=\$sourcePreview')));
  });
}
