import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _response(String content) => <String, dynamic>{
  'choices': <dynamic>[
    <String, dynamic>{
      'message': <String, dynamic>{'content': content},
    },
  ],
};

void main() {
  const client = TranslationApiClient();
  final leadingReasoningBlocks = RegExp(
    r'^(?:\s*<think(?:\s[^>]*)?>[\s\S]*?</think>)+',
    caseSensitive: false,
  );
  final trailingReasoningBlocks = RegExp(
    r'(?:<think(?:\s[^>]*)?>(?:(?!</think>)[\s\S])*</think>\s*)+$',
    caseSensitive: false,
  );
  final unclosedJson = '{"t":"${List.filled(1600, '<think>').join()}"}';
  final samples = <String, String>{
    '1600 unclosed tags in JSON': unclosedJson,
    'trailing block and whitespace':
        '{"a":1}<think>trailing thought</think>  \n',
    'consecutive leading blocks': '<think>one</think><think>two</think>{"a":1}',
    'leading and trailing blocks': '<think>a</think> junk <think>b</think>',
    'nested unclosed opening tag': '<think>outer <think>inner</think>',
    'case insensitive tags': 'data<THINK>x</THINK> ',
    'unclosed trailing block': 'data <think>unclosed',
    'tag attributes': 'data<think mode="r">x</think>',
  };

  for (final sample in samples.entries) {
    test('P2-05 matches the old stripping path: ${sample.key}', () {
      final expected = sample.value
          .replaceFirst(leadingReasoningBlocks, '')
          .replaceFirst(trailingReasoningBlocks, '')
          .trim();

      expect(client.extractMessageContent(_response(sample.value)), expected);
    });
  }

  test('P2-05 unclosed think tags in JSON finish within 500 ms', () {
    final stopwatch = Stopwatch()..start();
    final output = client.extractMessageContent(_response(unclosedJson));
    stopwatch.stop();

    expect(output, unclosedJson);
    expect(stopwatch.elapsedMilliseconds, lessThan(500));
  });
}
