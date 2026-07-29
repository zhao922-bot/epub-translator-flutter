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
}
