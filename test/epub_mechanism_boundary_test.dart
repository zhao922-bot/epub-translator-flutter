import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';

void main() {
  TranslationResidualFinding? residual(String source, String target) =>
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: source,
        translatedHtml: target,
        targetLanguage: 'Chinese',
      );
  for (final span in [false, true]) {
    String wrap(String value) =>
        span ? '<span class="koboSpan" id="r1">$value</span>' : value;
    test('retained epigraph author with reader spans=$span', () {
      String quote(String text) =>
          '<blockquote><p>$text</p><p class="x02-Part-Epigraph-Source">${wrap('Lucius Stone')}</p></blockquote>';
      expect(
        residual(
          quote('A gentle word can calm a room.'),
          quote('温和的话语能让房间安静下来。'),
        ),
        isNull,
      );
      expect(
        residual(
          quote('A gentle word can calm a room.'),
          quote('A gentle word can calm a room.'),
        ),
        isNotNull,
      );
    });
    test('signature with reader spans=$span', () {
      final s = '<p class="x14-Signature">${wrap('Miriam Clark')}</p>';
      expect(residual(s, s), isNull);
      expect(
        residual(
          '<p class="x14-Signature">Please Read Everything</p>',
          '<p class="x14-Signature">Please Read Everything</p>',
        ),
        isNotNull,
      );
    });
    test('source-owned title metadata with reader spans=$span', () {
      expect(
        residual(
          '<p class="copyright">${wrap('Title: A quiet voyage : notes from the sea / Miriam Clark.')}</p>',
          '<p class="copyright">${wrap('书名：A quiet voyage : notes from the sea / Miriam Clark.')}</p>',
        ),
        isNull,
      );
    });
    test('classification metadata with reader spans=$span', () {
      expect(
        residual(
          '<p class="copyright">${wrap('Classification: LCC PS3511.A86 B4 2021 (print) | LCC PS3511.A86 (ebook) | DDC 813/.52—dc23/eng/20210601')}</p>',
          '<p class="copyright">${wrap('分类：LCC PS3511.A86 B4 2021（印刷版）| LCC PS3511.A86（电子版）| DDC 813/.52—dc23/eng/20210601')}</p>',
        ),
        isNull,
      );
    });
  }
  test('reader spans do not turn a retained name into untranslated prose', () {
    expect(
      residual(
        '<p><span class="koboSpan" id="r1">Miriam Clark Jr.</span> <span class="koboSpan" id="r2">learned patience from her mother.</span></p>',
        '<p><span class="koboSpan" id="r1">Miriam Clark Jr.</span> <span class="koboSpan" id="r2">从母亲那里学会了耐心。</span></p>',
      ),
      isNull,
    );
    expect(
      residual(
        '<p><span class="koboSpan" id="r1">This Is Entirely Untranslated</span> <span class="koboSpan" id="r2">and should not be exempt.</span></p>',
        '<p><span class="koboSpan" id="r1">This Is Entirely Untranslated</span> <span class="koboSpan" id="r2">不应被豁免。</span></p>',
      ),
      isNotNull,
    );
  });
  test('opaque publication identifier is not natural language', () {
    const s =
        '<p id="publication_identifier"><span>pub_demo_7.2_091234_c1_r3</span></p>';
    expect(residual(s, s), isNull);
    expect(
      residual(
        '<p>Never stop trying to improve every single day.</p>',
        '<p>Never stop trying to improve every single day.</p>',
      ),
      isNotNull,
    );
  });
  test('ordinary residual separated by whitespace is still found', () {
    expect(
      residual(
        '<p>She carefully turned the handle.</p>',
        '<p>她 carefully 转动把手。</p>',
      ),
      isNotNull,
    );
    expect(
      residual(
        '<p>They practiced the foreign concept zanshin.</p>',
        '<p>他们练习残心（zanshin）。</p>',
      ),
      isNull,
    );
    expect(
      residual(
        '<p>Visit https://example.org/carefully for details.</p>',
        '<p>详情请见 https://example.org/carefully 。</p>',
      ),
      isNull,
    );
  });
  test('documented end-of-sequence reason accepts complete content', () {
    expect(
      const TranslationApiClient().extractMessageContent({
        'choices': [
          {
            'finish_reason': 'eos_token',
            'message': {'content': '完整内容'},
          },
        ],
      }),
      '完整内容',
    );
    for (final reason in [
      'length',
      'content_filter',
      'tool_calls',
      'unknown',
    ]) {
      expect(
        () => const TranslationApiClient().extractMessageContent({
          'choices': [
            {
              'finish_reason': reason,
              'message': {'content': '完整内容'},
            },
          ],
        }),
        throwsFormatException,
      );
    }
  });
  test('navigation keeps opening subtitle group but excludes later sections', () {
    const source =
        '<html><body><h1>Part Four</h1><h2>The Journey</h2><h3>(The Mind)</h3><p>Body.</p><h2>Later section</h2></body></html>';
    final extracted = const EpubHtmlExtractor().extractBlocks(
      html.parse(source),
      chapterPath: 'OPS/c.xhtml',
    );
    final targets = ['第四部分', '旅程', '（心灵）', '正文。', '后续小节'];
    final chapter = InspectedChapter(
      path: 'OPS/c.xhtml',
      title: 'Chapter',
      body: '',
      originalHtml: source,
      blocks: [
        for (var i = 0; i < extracted.length; i++)
          extracted[i].copyWith(
            translatedHtml:
                '<${extracted[i].tagName}>${targets[i]}</${extracted[i].tagName}>',
          ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );
    expect(
      EpubRepacker().debugNavigationLabels([chapter])['OPS/c.xhtml'],
      '第四部分: 旅程（心灵）',
    );
  });
}
