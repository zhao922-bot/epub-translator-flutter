import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const TranslationApiClient client = TranslationApiClient();

  test('repairs unescaped quotes inside model JSON strings', () {
    final Map<String, dynamic> decoded = client.decodeJsonObject(
      r'''{"blocks":[{"id":"p1","slots":[{"id":"s1","text":"而所谓的"玻璃天花板"——也就是那种"}]}]}''',
    );

    final List<dynamic> blocks = decoded['blocks'] as List<dynamic>;
    final List<dynamic> slots =
        (blocks.single as Map<String, dynamic>)['slots'] as List<dynamic>;
    expect(
      (slots.single as Map<String, dynamic>)['text'],
      '而所谓的"玻璃天花板"——也就是那种',
    );
  });

  test('keeps already escaped quotes unchanged', () {
    expect(
      client.decodeJsonObject(r'''{"text":"他说：\"你好\"。"}''')['text'],
      '他说："你好"。',
    );
  });

  test('still rejects structurally incomplete JSON', () {
    expect(
      () => client.decodeJsonObject(r'''{"blocks":[{"id":"p1"}'''),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a repair that would create duplicate object keys', () {
    expect(
      () => client.decodeJsonObject(
        r'''{"slot":{"id":"s1","text":"first "text", "text":"second"}}''',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('does not absorb trailing explanation into a JSON string', () {
    expect(
      () => client.decodeJsonObject(
        r'''{"slot":{"id":"s1","text":"译文" trailing explanation"}}''',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('strips reasoning think blocks from message content', () {
    final String content = client.extractMessageContent(
      <String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'content':
                  '<think>I should translate this heading into Chinese.</think>\n'
                      '{"blocks":[{"id":"h3-4","html":"<h3 class=\\"h2\\"><i class=\\"calibre5\\">想法成为财富</i></h3>"}]}',
            },
          },
        ],
      },
    );
    expect(content, isNot(contains('think')));
    expect(content, startsWith('{'));
    expect(
      (client.decodeJsonObject(content)['blocks'] as List<dynamic>).single,
      containsPair('id', 'h3-4'),
    );
  });

  test('strips think blocks even when they contain JSON-looking text', () {
    final String content = client.extractMessageContent(
      <String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'content':
                  '<think>{"blocks":[]} should not be parsed</think>'
                      '{"blocks":[{"id":"p1","html":"<p>译文</p>"}]}',
            },
          },
        ],
      },
    );
    expect(content, isNot(contains('should not be parsed')));
    expect(
      client.decodeJsonObject(content)['blocks'] as List<dynamic>,
      hasLength(1),
    );
  });

  test('keeps content without think blocks unchanged', () {
    const String raw = '{"blocks":[{"id":"p1","html":"<p>译文</p>"}]}';
    expect(
      client.extractMessageContent(
        <String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': raw},
            },
          ],
        },
      ),
      raw,
    );
  });
}
