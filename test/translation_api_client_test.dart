import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/sse_stream_decoder.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const TranslationApiClient client = TranslationApiClient();

  for (final scheme in ['http', 'https']) {
    test(
      '$scheme rejected proxy credentials stop after one challenge retry',
      () async {
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final received = <String?>[];
        final subscription = proxy.listen((request) async {
          received.add(
            request.headers.value(HttpHeaders.proxyAuthorizationHeader),
          );
          request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
          request.response.contentLength = 0;
          request.response.headers.set(
            'proxy-authenticate',
            'Basic realm="proxy"',
          );
          await request.response.close();
        });
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: '$scheme://api.example.com',
          apiKey: 'key',
          httpProxy: 'http://user:wrong@127.0.0.1:${proxy.port}',
          uiLanguage: UiLanguage.chinese,
          maxRetries: 5,
        );
        final dio = client.buildDio(config);
        try {
          await expectLater(
            client
                .runRetried(
                  config: config,
                  retryDelayOverride: Duration.zero,
                  operation: () =>
                      dio.get<String>('$scheme://api.example.com/probe'),
                )
                .timeout(const Duration(seconds: 5)),
            throwsA(
              isA<DioException>()
                  .having((e) => e.message, 'diagnostic', contains('代理认证失败'))
                  .having(
                    (e) => TranslationApiClient.shouldRetryBatchError(e),
                    'retryable',
                    isFalse,
                  ),
            ),
          );
          expect(received, [
            null,
            'Basic ${base64Encode(utf8.encode('user:wrong'))}',
          ]);
        } finally {
          dio.close(force: true);
          await subscription.cancel();
          await proxy.close(force: true);
        }
      },
    );
  }

  test('rejects HTTPS proxy credentials before any connection', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    int connections = 0;
    final subscription = proxy.listen((socket) {
      connections += 1;
      socket.destroy();
    });
    try {
      for (final value in <String>[
        'https://proxy.example:443',
        'HTTPS://[::1]:443/',
        'https://user:secret@127.0.0.1:${proxy.port}',
      ]) {
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://api.example.com',
          apiKey: 'key',
          model: 'model',
          httpProxy: value,
        );
        expect(
          TranslationApiClient.validateProxySetting(value),
          ProxySettingError.unsupportedScheme,
        );
        expect(TranslationApiClient.proxyHostPort(value), isNull);
        final diagnostic = isA<FormatException>().having(
          (error) => error.message,
          'explicit HTTPS rejection',
          contains('HTTPS'),
        );
        expect(() => client.buildDio(config), throwsA(diagnostic));
        await expectLater(
          client.testConnection(config: config),
          throwsA(diagnostic),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connections, 0);
    } finally {
      await subscription.cancel();
      await proxy.close();
    }
  });

  test(
    'authenticates a proxy challenge with decoded URI credentials',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final credentials =
          'Basic ${base64Encode(utf8.encode('user@name:p:a ss'))}';
      final received = <String?>[];
      final subscription = proxy.listen((request) async {
        received.add(
          request.headers.value(HttpHeaders.proxyAuthorizationHeader),
        );
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer key',
        );
        if (received.last != credentials) {
          request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
          request.response.headers.set(
            'proxy-authenticate',
            'Basic realm="proxy"',
          );
        } else if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            'location',
            'http://api.example.com/probe',
          );
        } else {
          request.response.write('OK');
        }
        await request.response.close();
      });
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://api.example.com',
        apiKey: 'key',
        httpProxy: 'http://user%40name:p%3Aa%20ss@127.0.0.1:${proxy.port}',
      );
      expect(
        TranslationApiClient.validateProxySetting(config.httpProxy),
        isNull,
      );
      final dio = client.buildDio(config);
      try {
        final response = await dio.get<String>('http://api.example.com/probe');
        expect(response.data, 'OK');
        expect(received, [null, credentials]);
        final redirected = await dio.get<String>(
          'http://api.example.com/redirect',
        );
        expect(redirected.data, 'OK');
        final subsequent = await Future.wait([
          dio.get<String>('http://api.example.com/probe'),
          dio.get<String>('http://api.example.com/probe'),
        ]);
        expect(subsequent.map((response) => response.data), ['OK', 'OK']);
        expect(received.skip(2).every((value) => value == credentials), isTrue);
      } finally {
        dio.close(force: true);
        await subscription.cancel();
        await proxy.close(force: true);
      }
    },
  );

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

    test('rejects embedded query credentials before a request', () {
      expect(
        () => client.normalizedBaseUrl('https://api.example.com/v1?key=xxx'),
        throwsFormatException,
      );
    });

    test('appends /v1 after a credential-free custom path', () {
      expect(
        client.normalizedBaseUrl('https://api.example.com/custom'),
        'https://api.example.com/custom/v1',
      );
    });

    test('rejects userinfo without echoing credentials', () {
      for (final url in [
        'https://user:password@host/v1?key=secret',
        'https://user:password@host/v1',
      ]) {
        expect(() => client.normalizedBaseUrl(url), throwsFormatException);
      }
      // Fragments are rejected outright (C-1): they never reach the server,
      // so allowing them has zero business value, and OAuth-implicit-style
      // fragments like #api_key= can carry plaintext credentials.
      expect(
        () => client.normalizedBaseUrl('https://host/v1#secret'),
        throwsFormatException,
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

    test('accepts http://host:port and rejects HTTPS proxies', () {
      expect(
        TranslationApiClient.proxyHostPort('http://proxy.lan:8080'),
        'proxy.lan:8080',
      );
      expect(
        TranslationApiClient.proxyHostPort('https://proxy.lan:8080/'),
        isNull,
      );
    });

    test('accepts bracketed IPv6 literals', () {
      expect(TranslationApiClient.proxyHostPort('[::1]:7890'), '[::1]:7890');
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

  group('shared proxy parsing', () {
    final valid = <String, String>{
      '[::1]:7890': '[::1]:7890',
      'http://[::1]:7890': '[::1]:7890',
      '  [2001:4860:4860::8888]:65535  ': '[2001:4860:4860::8888]:65535',
      'http://proxy.lan:80': 'proxy.lan:80',
      'http://[::1]:80/': '[::1]:80',
      'HTTP://proxy.lan:8080/': 'proxy.lan:8080',
      'http://proxy.lan:8080/path?next=http://other.lan:9090': 'proxy.lan:8080',
      'proxy.lan:00080': 'proxy.lan:80',
    };
    for (final entry in valid.entries) {
      test('validates and formats ${entry.key}', () {
        expect(TranslationApiClient.validateProxySetting(entry.key), isNull);
        final proxy = TranslationApiClient.proxyHostPort(entry.key);
        expect(proxy, entry.value);
        expect(
          TranslationApiClient.proxyForUri(
            proxy!,
            Uri.parse('https://example.com'),
          ),
          'PROXY ${entry.value}',
        );
      });
    }
    for (final value in <String>[
      '::1:7890',
      '[not-ipv6]:7890',
      '[::1]:0',
      'http://[::1]:65536',
      'http://[::1]',
      'http://[::1]:abc',
      'http://[::1:7890',
      'proxy host:8080',
      'http://proxy host:8080',
      'proxy.lan:8080/path',
    ]) {
      test('consistently rejects $value', () {
        expect(
          TranslationApiClient.validateProxySetting(value),
          ProxySettingError.invalidFormat,
        );
        expect(TranslationApiClient.proxyHostPort(value), isNull);
      });
    }
    test('unsupported IPv6 proxy schemes retain diagnostic category', () {
      const value = 'socks5://[::1]:1080';
      expect(TranslationApiClient.proxyHostPort(value), isNull);
      expect(
        TranslationApiClient.validateProxySetting(value),
        ProxySettingError.unsupportedScheme,
      );
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
        ProxySettingError.unsupportedScheme,
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

    test('non-map message throws TranslationParseException', () {
      expect(
        () => client.extractMessageContent(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{'message': 'oops'},
          ],
        }),
        throwsA(isA<TranslationParseException>()),
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

    test('honors a server Retry-After as a minimum with positive jitter', () {
      final TranslationConfig config = TranslationConfig.defaults();
      final Set<int> seen = <int>{};
      for (int seed = 0; seed < 10; seed++) {
        final Duration delay = TranslationApiClient.retryDelayForError(
          config,
          rateLimitError(retryAfter: '300'),
          1,
          random: Random(seed),
        );
        // Server said 300s: never shorter, at most +25% on top.
        expect(delay.inMilliseconds, greaterThanOrEqualTo(300000));
        expect(delay.inMilliseconds, lessThanOrEqualTo(375000));
        seen.add(delay.inMilliseconds);
      }
      // With jitter, distinct seeds must not all collapse to one value.
      expect(seen.length, greaterThan(1));
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

  group('SSE streaming and ModelCapabilityProfile', () {
    test('dispatches all data lines in a single SSE event', () async {
      final result = await decodeChatCompletionStream(
        contentType: 'text/event-stream',
        stream: Stream<Uint8List>.value(
          Uint8List.fromList(
            utf8.encode(
              'data: {"choices": [\r\n'
              ': comment within the event\r\n'
              'data: {"delta": {"content": "translated"}}]}\r\n\r\n'
              'data: [DONE]\r\n\r\n',
            ),
          ),
        ),
      );
      expect(client.extractMessageContent(result), 'translated');
    });

    for (final contentType in ['application/json', 'text/event-stream']) {
      test('cancels an idle $contentType response', () async {
        final subscribed = Completer<void>();
        final stream = StreamController<Uint8List>(
          onListen: subscribed.complete,
        );
        addTearDown(stream.close);
        final token = CancelToken();
        final result = decodeChatCompletionStream(
          stream: stream.stream,
          contentType: contentType,
          cancelToken: token,
        );
        final cancelled = expectLater(
          result.timeout(const Duration(seconds: 1)),
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await subscribed.future;
        token.cancel('test cancellation');
        await cancelled;
        expect(stream.hasListener, isFalse);
      });
    }

    test('assembles SSE chunks including split UTF-8 bytes and usage', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final recordedRequests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final rawBody = await utf8.decoder.bind(request).join();
        recordedRequests.add(jsonDecode(rawBody) as Map<String, dynamic>);
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream; charset=utf-8',
        );
        final chunk1 = utf8.encode(
          ': keepalive\n\ndata: ${jsonEncode(<String, Object>{
            'id': 'cmpl-1',
            'model': 'deepseek-v4-flash',
            'choices': <Object>[
              <String, Object>{
                'delta': <String, Object>{'role': 'assistant', 'reasoning_content': '思考中'},
              },
            ],
          })}\n\n',
        );
        // Split a multibyte Chinese character "你" (3 UTF-8 bytes) across chunks.
        final chunk2Full = utf8.encode(
          'data: ${jsonEncode(<String, Object>{
            'choices': <Object>[
              <String, Object>{
                'delta': <String, Object>{'content': '你好'},
              },
            ],
          })}\n\n',
        );
        final splitAt = chunk2Full.length - 6;
        final chunk2a = chunk2Full.sublist(0, splitAt);
        final chunk2b = chunk2Full.sublist(splitAt);
        final chunk3 = utf8.encode(
          'data: ${jsonEncode(<String, Object>{
            'choices': <Object>[
              <String, Object>{
                'finish_reason': 'stop',
                'delta': <String, Object>{'content': '世界'},
              },
            ],
            'usage': <String, Object>{'total_tokens': 42},
          })}\n\ndata: [DONE]\n\n',
        );
        request.response.add(chunk1);
        await request.response.flush();
        request.response.add(chunk2a);
        await request.response.flush();
        request.response.add(chunk2b);
        await request.response.flush();
        request.response.add(chunk3);
        await request.response.close();
      });

      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        useStreamingApi: true,
      );
      final dio = client.buildDio(config);
      addTearDown(() => dio.close(force: true));

      final deltas = <String>[];
      final response = await client.postChatCompletionsStream(
        dio: dio,
        data: <String, dynamic>{
          'model': config.model,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'hello'},
          ],
          'max_tokens': 256,
        },
        onStreamDelta: deltas.add,
      );

      expect(recordedRequests.single['stream'], isTrue);
      expect(deltas, ['你好', '世界']);
      expect(client.extractMessageContent(response.data), '你好世界');
      final choices = (response.data as Map)['choices'] as List;
      expect((choices.first as Map)['finish_reason'], 'stop');
      expect((choices.first as Map)['message']['reasoning_content'], '思考中');
      expect((response.data as Map)['usage']['total_tokens'], 42);
    });

    test(
      'falls back seamlessly when gateway returns buffered JSON or rejects stream',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        int callCount = 0;
        server.listen((request) async {
          callCount++;
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          if (callCount == 1) {
            // Gateway ignores stream: true and returns normal application/json.
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object>{
                'choices': <Object>[
                  <String, Object>{
                    'finish_reason': 'stop',
                    'message': <String, Object>{'content': 'JSON回退成功'},
                  },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          if (body['stream'] == true) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object>{
                'error': <String, Object>{
                  'message': 'Unsupported parameter: stream',
                },
              }),
            );
            await request.response.close();
            return;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object>{
              'choices': <Object>[
                <String, Object>{
                  'finish_reason': 'stop',
                  'message': <String, Object>{'content': '非流式重试成功'},
                },
              ],
            }),
          );
          await request.response.close();
        });

        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'sk-test',
          useStreamingApi: true,
        );
        final dio = client.buildDio(config);
        addTearDown(() => dio.close(force: true));

        final first = await client.postChatCompletions(
          dio: dio,
          data: <String, dynamic>{
            'model': 'm',
            'messages': [],
            'max_tokens': 64,
          },
        );
        expect(client.extractMessageContent(first.data), 'JSON回退成功');

        final second = await client.postChatCompletions(
          dio: dio,
          data: <String, dynamic>{
            'model': 'm',
            'messages': [],
            'max_tokens': 64,
          },
        );
        expect(client.extractMessageContent(second.data), '非流式重试成功');
        expect(callCount, 3);
      },
    );
  });
}
