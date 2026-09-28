import 'dart:math';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
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
    final String content = client.extractMessageContent(<String, dynamic>{
      'choices': <dynamic>[
        <String, dynamic>{
          'message': <String, dynamic>{
            'content':
                '<think>I should translate this heading into Chinese.</think>\n'
                '{"blocks":[{"id":"h3-4","html":"<h3 class=\\"h2\\"><i class=\\"calibre5\\">想法成为财富</i></h3>"}]}',
          },
        },
      ],
    });
    expect(content, isNot(contains('think')));
    expect(content, startsWith('{'));
    expect(
      (client.decodeJsonObject(content)['blocks'] as List<dynamic>).single,
      containsPair('id', 'h3-4'),
    );
  });

  test('strips think blocks even when they contain JSON-looking text', () {
    final String content = client.extractMessageContent(<String, dynamic>{
      'choices': <dynamic>[
        <String, dynamic>{
          'message': <String, dynamic>{
            'content':
                '<think>{"blocks":[]} should not be parsed</think>'
                '{"blocks":[{"id":"p1","html":"<p>译文</p>"}]}',
          },
        },
      ],
    });
    expect(content, isNot(contains('should not be parsed')));
    expect(
      client.decodeJsonObject(content)['blocks'] as List<dynamic>,
      hasLength(1),
    );
  });

  test('keeps content without think blocks unchanged', () {
    const String raw = '{"blocks":[{"id":"p1","html":"<p>译文</p>"}]}';
    expect(
      client.extractMessageContent(<String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': raw},
          },
        ],
      }),
      raw,
    );
  });

  group('normalizedBaseUrl', () {
    test('lowercases an uppercase /V1 suffix', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com/V1'),
        'https://api.example.com/v1',
      );
    });

    test('keeps a lowercase /v1 suffix as-is', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com/v1'),
        'https://api.example.com/v1',
      );
    });

    test('strips trailing slashes before appending /v1', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com///'),
        'https://api.example.com/v1',
      );
    });

    test('preserves query parameters instead of corrupting them', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com/v1?key=xxx'),
        'https://api.example.com/v1?key=xxx',
      );
    });

    test('appends /v1 after a custom path without touching the query', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com/custom?key=xxx'),
        'https://api.example.com/custom/v1?key=xxx',
      );
    });

    test('strips a pasted /chat/completions suffix', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com/v1/chat/completions'),
        'https://api.example.com/v1',
      );
    });

    test('adds https scheme when missing', () {
      expect(
        client.normalizedBaseUrl('api.example.com'),
        'https://api.example.com/v1',
      );
    });

    test('keeps ports and does not duplicate /v1', () {
      expect(
        client.normalizedBaseUrl('http://127.0.0.1:8080/v1'),
        'http://127.0.0.1:8080/v1',
      );
    });
  });

  group('proxyHostPort', () {
    test('accepts host:port', () {
      expect(
        TranslationApiClient.proxyHostPort('127.0.0.1:7890'),
        '127.0.0.1:7890',
      );
    });

    test('accepts http(s)://host:port and strips the scheme', () {
      expect(
        TranslationApiClient.proxyHostPort('http://proxy.lan:8080'),
        'proxy.lan:8080',
      );
      expect(
        TranslationApiClient.proxyHostPort('https://proxy.lan:8080/'),
        'proxy.lan:8080',
      );
    });

    test('accepts bracketed IPv6 literals', () {
      expect(TranslationApiClient.proxyHostPort('[::1]:7890'), '::1:7890');
    });

    test('rejects empty, portless, and malformed values', () {
      expect(TranslationApiClient.proxyHostPort(''), isNull);
      expect(TranslationApiClient.proxyHostPort('   '), isNull);
      expect(TranslationApiClient.proxyHostPort('proxy.lan'), isNull);
      expect(TranslationApiClient.proxyHostPort('proxy.lan:abc'), isNull);
      expect(TranslationApiClient.proxyHostPort('proxy.lan:0'), isNull);
      expect(TranslationApiClient.proxyHostPort('proxy.lan:99999'), isNull);
      expect(TranslationApiClient.proxyHostPort('http://proxy.lan'), isNull);
    });

    test('rejects non-HTTP schemes instead of misusing them', () {
      // Dart's HttpClient only speaks HTTP proxies; a SOCKS address must not
      // be silently treated as one.
      expect(TranslationApiClient.proxyHostPort('socks5://host:1080'), isNull);
      expect(TranslationApiClient.proxyHostPort('socks5h://host:1080'), isNull);
      expect(TranslationApiClient.proxyHostPort('ftp://host:21'), isNull);
    });
  });

  group('validateProxySetting', () {
    test('accepts empty (disabled) and valid values', () {
      expect(TranslationApiClient.validateProxySetting(''), isNull);
      expect(TranslationApiClient.validateProxySetting('   '), isNull);
      expect(
        TranslationApiClient.validateProxySetting('127.0.0.1:7890'),
        isNull,
      );
      expect(
        TranslationApiClient.validateProxySetting('http://proxy.lan:8080'),
        isNull,
      );
      expect(
        TranslationApiClient.validateProxySetting('https://proxy.lan:8080/'),
        isNull,
      );
      expect(TranslationApiClient.validateProxySetting('[::1]:7890'), isNull);
    });

    test('flags malformed values as invalidFormat', () {
      expect(
        TranslationApiClient.validateProxySetting('proxy.lan'),
        ProxySettingError.invalidFormat,
      );
      expect(
        TranslationApiClient.validateProxySetting('proxy.lan:abc'),
        ProxySettingError.invalidFormat,
      );
      expect(
        TranslationApiClient.validateProxySetting('proxy.lan:0'),
        ProxySettingError.invalidFormat,
      );
      expect(
        TranslationApiClient.validateProxySetting('proxy.lan:99999'),
        ProxySettingError.invalidFormat,
      );
      expect(
        TranslationApiClient.validateProxySetting('http://proxy.lan'),
        ProxySettingError.invalidFormat,
      );
    });

    test('flags non-HTTP schemes as unsupportedScheme', () {
      expect(
        TranslationApiClient.validateProxySetting('socks5://host:1080'),
        ProxySettingError.unsupportedScheme,
      );
      expect(
        TranslationApiClient.validateProxySetting('socks5h://host:1080'),
        ProxySettingError.unsupportedScheme,
      );
      expect(
        TranslationApiClient.validateProxySetting('ftp://host:21'),
        ProxySettingError.unsupportedScheme,
      );
    });
  });

  group('proxyForUri', () {
    const String proxy = '127.0.0.1:7890';

    test('proxies public destinations', () {
      expect(
        TranslationApiClient.proxyForUri(
          proxy,
          Uri.parse('https://api.deepseek.com/v1'),
        ),
        'PROXY $proxy',
      );
      expect(
        TranslationApiClient.proxyForUri(proxy, Uri.parse('https://8.8.8.8/')),
        'PROXY $proxy',
      );
    });

    test('bypasses loopback and local names', () {
      for (final String url in <String>[
        'http://localhost:8080/v1',
        'http://127.0.0.1:8080/v1',
        'http://[::1]:8080/v1',
        'http://intranet/v1',
      ]) {
        expect(
          TranslationApiClient.proxyForUri(proxy, Uri.parse(url)),
          'DIRECT',
          reason: url,
        );
      }
    });

    test('bypasses private and link-local addresses', () {
      for (final String url in <String>[
        'http://10.0.0.5/v1',
        'http://172.16.4.9/v1',
        'http://192.168.1.20:8080/v1',
        'http://169.254.10.20/v1',
        'http://[fc00::1]/v1',
        'http://[fe80::1]/v1',
      ]) {
        expect(
          TranslationApiClient.proxyForUri(proxy, Uri.parse(url)),
          'DIRECT',
          reason: url,
        );
      }
    });

    test('bypasses IPv4-mapped IPv6 loopback and private ranges', () {
      for (final String url in <String>[
        'http://[::ffff:127.0.0.1]:8080/v1',
        'http://[::ffff:10.0.0.5]/v1',
        'http://[::ffff:192.168.1.20]:8080/v1',
      ]) {
        expect(
          TranslationApiClient.proxyForUri(proxy, Uri.parse(url)),
          'DIRECT',
          reason: url,
        );
      }
      // A mapped public address still goes through the proxy.
      expect(
        TranslationApiClient.proxyForUri(
          proxy,
          Uri.parse('http://[::ffff:8.8.8.8]/v1'),
        ),
        'PROXY $proxy',
      );
    });

    test('proxies public IPv6 literals instead of treating them as local', () {
      // Uri.host strips the brackets, so the bypass check sees a bare
      // "2001:4860:4860::8888" with no dot: it must still go through the
      // proxy, while ::1 stays DIRECT.
      expect(
        TranslationApiClient.proxyForUri(
          proxy,
          Uri.parse('http://[2001:4860:4860::8888]/v1'),
        ),
        'PROXY $proxy',
      );
      expect(
        TranslationApiClient.proxyForUri(proxy, Uri.parse('http://[::1]/v1')),
        'DIRECT',
      );
    });
  });

  group('extractMessageContent malformed envelopes', () {
    test(
      'empty choices array throws TranslationParseException, not RangeError',
      () {
        expect(
          () => client.extractMessageContent(<String, dynamic>{
            'choices': <dynamic>[],
          }),
          throwsA(isA<TranslationParseException>()),
        );
      },
    );

    test(
      'non-list choices throws TranslationParseException, not TypeError',
      () {
        expect(
          () => client.extractMessageContent(<String, dynamic>{
            'choices': 'oops',
          }),
          throwsA(isA<TranslationParseException>()),
        );
      },
    );

    test('non-map choice throws TranslationParseException', () {
      expect(
        () => client.extractMessageContent(<String, dynamic>{
          'choices': <dynamic>['oops'],
        }),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('non-map message yields empty content instead of throwing', () {
      expect(
        client.extractMessageContent(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{'message': 'oops'},
          ],
        }),
        isEmpty,
      );
    });
  });

  group('retryAfterDelay', () {
    DioException rateLimitErrorWith(String retryAfter) {
      return DioException(
        requestOptions: RequestOptions(path: '/v1/chat/completions'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/chat/completions'),
          statusCode: 429,
          headers: Headers.fromMap(<String, List<String>>{
            'retry-after': <String>[retryAfter],
          }),
        ),
        type: DioExceptionType.badResponse,
      );
    }

    test('parses RFC 1123 HTTP-date Retry-After', () {
      // Far-future date so the delay is certainly positive and large.
      final Duration? delay = TranslationApiClient.retryAfterDelay(
        rateLimitErrorWith('Wed, 21 Oct 2099 07:28:00 GMT'),
      );
      expect(delay, isNotNull);
      expect(delay! > const Duration(days: 365), isTrue);
    });

    test('past HTTP-date Retry-After yields zero delay, not null', () {
      final Duration? delay = TranslationApiClient.retryAfterDelay(
        rateLimitErrorWith('Wed, 21 Oct 2015 07:28:00 GMT'),
      );
      expect(delay, Duration.zero);
    });

    test('garbage Retry-After still falls back to backoff (null)', () {
      expect(
        TranslationApiClient.retryAfterDelay(rateLimitErrorWith('not-a-date')),
        isNull,
      );
    });

    test('negative Retry-After falls back to backoff (null)', () {
      expect(
        TranslationApiClient.retryAfterDelay(rateLimitErrorWith('-1')),
        isNull,
      );
    });
  });

  group('deterministic HTTP errors', () {
    DioException badResponse(int statusCode) {
      final RequestOptions requestOptions = RequestOptions(path: '/v1');
      return DioException(
        requestOptions: requestOptions,
        response: Response<dynamic>(
          requestOptions: requestOptions,
          statusCode: statusCode,
        ),
        type: DioExceptionType.badResponse,
      );
    }

    test('400 is deterministic and fails batch retry fast', () {
      expect(
        TranslationApiClient.isDeterministicHttpError(badResponse(400)),
        isTrue,
      );
      expect(
        TranslationApiClient.shouldRetryBatchError(badResponse(400)),
        isFalse,
      );
    });

    test('401/404 stay deterministic', () {
      for (final int code in <int>[401, 404]) {
        expect(
          TranslationApiClient.isDeterministicHttpError(badResponse(code)),
          isTrue,
          reason: '$code',
        );
      }
    });

    test('500 is still retried', () {
      expect(
        TranslationApiClient.isDeterministicHttpError(badResponse(500)),
        isFalse,
      );
      expect(
        TranslationApiClient.shouldRetryBatchError(badResponse(500)),
        isTrue,
      );
    });
  });

  group('retry backoff', () {
    DioException rateLimitError({String? retryAfter}) {
      final Map<String, List<String>> headers = retryAfter == null
          ? const <String, List<String>>{}
          : <String, List<String>>{
              'retry-after': <String>[retryAfter],
            };
      final RequestOptions requestOptions = RequestOptions(path: '/v1');
      return DioException(
        requestOptions: requestOptions,
        response: Response<dynamic>(
          requestOptions: requestOptions,
          statusCode: 429,
          headers: Headers.fromMap(headers),
        ),
      );
    }

    test('applyJitter stays within +-25% with a seeded random', () {
      final Random random = Random(42);
      for (int i = 0; i < 50; i++) {
        final Duration jittered = TranslationApiClient.applyJitter(
          const Duration(seconds: 20),
          random,
        );
        expect(jittered.inMilliseconds, greaterThanOrEqualTo(15000));
        expect(jittered.inMilliseconds, lessThanOrEqualTo(25000));
      }
    });

    test('applyJitter leaves zero durations alone', () {
      expect(
        TranslationApiClient.applyJitter(Duration.zero, Random(1)),
        Duration.zero,
      );
    });

    test('exponential backoff is jittered, not exact', () {
      final TranslationConfig config = TranslationConfig.defaults();
      final Set<int> seen = <int>{};
      for (int seed = 0; seed < 10; seed++) {
        final Duration delay = TranslationApiClient.retryDelayForError(
          config,
          rateLimitError(),
          1,
          random: Random(seed),
        );
        // Base would be exactly 5s; jitter must move it within [3.75s, 6.25s].
        expect(delay.inMilliseconds, greaterThanOrEqualTo(3750));
        expect(delay.inMilliseconds, lessThanOrEqualTo(6250));
        seen.add(delay.inMilliseconds);
      }
      // With jitter, distinct seeds must not all collapse to one value.
      expect(seen.length, greaterThan(1));
    });

    test('honors a server Retry-After under the cap exactly', () {
      final TranslationConfig config = TranslationConfig.defaults();
      expect(
        TranslationApiClient.retryDelayForError(
          config,
          rateLimitError(retryAfter: '300'),
          1,
        ),
        const Duration(seconds: 300),
      );
    });

    test('fails loud when Retry-After exceeds the 10 minute cap', () {
      final TranslationConfig config = TranslationConfig.defaults();
      expect(
        () => TranslationApiClient.retryDelayForError(
          config,
          rateLimitError(retryAfter: '3600'),
          1,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('60'),
          ),
        ),
      );
    });

    test('loud failure message is localized for Chinese UI', () {
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        uiLanguage: UiLanguage.chinese,
      );
      expect(
        () => TranslationApiClient.retryDelayForError(
          config,
          rateLimitError(retryAfter: '3600'),
          1,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('分钟'),
          ),
        ),
      );
    });
  });
}
