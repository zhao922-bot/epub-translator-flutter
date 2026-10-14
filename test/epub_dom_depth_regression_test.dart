import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';

void main() {
  for (final depth in [100, 20000]) {
    test(
      'R07 extractor must handle DOM depth $depth without stack overflow',
      () {
        final document = Document();
        final html = Element.tag('html');
        final body = Element.tag('body');
        document.append(html);
        html.append(body);
        var parent = body;
        for (var i = 0; i < depth; i++) {
          final node = Element.tag('div');
          parent.append(node);
          parent = node;
        }
        parent.append(Text('deep'));
        try {
          const EpubHtmlExtractor().extractTranslatableElements(document);
          if (depth > 132) {
            expect(
              () => const EpubHtmlExtractor().extractBlocks(
                document,
                chapterPath: 'deep.xhtml',
              ),
              throwsFormatException,
            );
          }
        } catch (error, stack) {
          stdout.writeln(
            'DEPTH_FAILURE depth=$depth error=${error.runtimeType}\n'
            '${stack.toString().split('\n').take(8).join('\n')}',
          );
          rethrow;
        }
      },
    );
  }
}
