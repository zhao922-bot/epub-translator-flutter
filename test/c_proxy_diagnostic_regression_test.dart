import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:epub_translator_flutter/features/settings/application/connection_diagnostic.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/shared/security/sensitive_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapturedClient implements HttpClient {
  String Function(Uri)? selection;

  @override
  set findProxy(String Function(Uri)? value) => selection = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HttpOverrides extends HttpOverrides {
  final client = _CapturedClient();

  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

class _ProbeRepository implements TranslationRepository {
  final tokens = <CancelToken>[];
  final completions = <Completer<String>>[];

  @override
  Future<String> testConnection({required TranslationConfig config}) async {
    // Also verify the token survives an asynchronous repository boundary.
    await Future<void>.value();
    tokens.add(
      Zone.current[TranslationApiClient.probeCancelTokenKey] as CancelToken,
    );
    final completion = Completer<String>();
    completions.add(completion);
    return completion.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://api.example.com/v1',
    apiKey: 'test-api-key',
    model: 'example-model',
    uiLanguage: UiLanguage.english,
  );

  test('C-21 blank proxy explicitly disables environment proxy selection', () {
    for (final value in ['', '   ']) {
      final overrides = _HttpOverrides();
      HttpOverrides.runWithHttpOverrides(() {
        final dio = const TranslationApiClient().buildDio(
          config.copyWith(httpProxy: value),
        );
        final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
        adapter.createHttpClient!();
        expect(overrides.client.selection, isNotNull);
        for (final url in [
          'https://api.example.com/v1',
          'http://8.8.8.8/x',
          'http://localhost/',
        ]) {
          expect(overrides.client.selection!(Uri.parse(url)), 'DIRECT');
        }
        dio.close(force: true);
      }, overrides);
    }
  });

  test('C-21 explicit proxy retains no_proxy destination rules', () {
    final overrides = _HttpOverrides();
    HttpOverrides.runWithHttpOverrides(() {
      final dio = const TranslationApiClient().buildDio(
        config.copyWith(httpProxy: '127.0.0.1:8080'),
      );
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient!();
      expect(
        overrides.client.selection!(Uri.parse('https://api.example.com/')),
        'PROXY 127.0.0.1:8080',
      );
      expect(
        overrides.client.selection!(Uri.parse('http://192.168.1.2/')),
        'DIRECT',
      );
      dio.close(force: true);
    }, overrides);
  });

  test('C-22 trailing-dot localhost bypasses the proxy case-insensitively', () {
    for (final host in ['localhost.', 'LOCALHOST.', 'sub.localhost.']) {
      expect(
        TranslationApiClient.proxyForUri(
          '127.0.0.1:8080',
          Uri.parse('http://$host:8080/x'),
        ),
        'DIRECT',
      );
    }
    expect(
      TranslationApiClient.proxyForUri(
        '127.0.0.1:8080',
        Uri.parse('http://api.example.com./'),
      ),
      'PROXY 127.0.0.1:8080',
    );
  });

  test(
    'C-23 schemeless authenticated proxies validate without exposing credentials',
    () {
      for (final entry in {
        'user:pass@127.0.0.1:8080': '127.0.0.1:8080',
        'user:pa:ss@word@proxy.example:80': 'proxy.example:80',
        'user:p%40ss@[::1]:8080': '[::1]:8080',
      }.entries) {
        expect(TranslationApiClient.validateProxySetting(entry.key), isNull);
        expect(TranslationApiClient.proxyHostPort(entry.key), entry.value);
      }
      for (final value in [
        'user:pass@host:port',
        'user:pass@host',
        'user:pass@host:0',
        'user:pass@::1:8080',
      ]) {
        expect(
          TranslationApiClient.validateProxySetting(value),
          ProxySettingError.invalidFormat,
        );
      }
      for (final scheme in ['https', 'socks5']) {
        expect(
          TranslationApiClient.validateProxySetting(
            '$scheme://user:pass@host:8080',
          ),
          ProxySettingError.unsupportedScheme,
        );
      }
      expect(
        () => const TranslationApiClient().normalizedBaseUrl(
          'https://user:secret@api.example.com',
        ),
        throwsFormatException,
      );
    },
  );

  test('C-23 schemeless credentials use the proxy challenge flow', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <String?>[];
    final credentials = 'Basic ${base64Encode(utf8.encode('user:pa:ss@word'))}';
    final subscription = proxy.listen((request) async {
      received.add(request.headers.value(HttpHeaders.proxyAuthorizationHeader));
      expect(request.uri.userInfo, isEmpty);
      if (received.last == credentials) {
        request.response.write('OK');
      } else {
        request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
        request.response.headers.set(
          'proxy-authenticate',
          'Basic realm="proxy"',
        );
      }
      await request.response.close();
    });
    final dio = const TranslationApiClient().buildDio(
      config.copyWith(
        apiBaseUrl: 'http://api.example.com',
        httpProxy: 'user:pa:ss@word@127.0.0.1:${proxy.port}',
      ),
    );
    try {
      final response = await dio.get<String>('http://api.example.com/probe');
      expect(response.data, 'OK');
      expect(received, [null, credentials]);
    } finally {
      dio.close(force: true);
      await subscription.cancel();
      await proxy.close(force: true);
    }
  });

  test('C-24 URL userinfo is redacted in both direct and diagnostic paths', () {
    for (final url in [
      'http://admin:s3cret@10.0.0.1:8080/x',
      'HTTPS://admin:s3cret@10.0.0.1:8080/x',
    ]) {
      final redacted = SensitiveText.redact('proxy $url');
      expect(redacted, isNot(contains('s3cret')));
      expect(redacted, isNot(contains('admin')));
      expect(redacted, contains('[redacted]@10.0.0.1:8080/x'));
      final message = ConnectionDiagnostic.fromError(
        StateError('proxy $url'),
        config: config,
      ).message;
      expect(message, isNot(contains('s3cret')));
      expect(message, contains('10.0.0.1'));
    }
  });

  test('C-25 rerun, clear and disposal cancel the active probe only', () async {
    final repository = _ProbeRepository();
    final controller = ConnectionTestController(repository);
    final first = controller.run(config);
    await Future<void>.delayed(Duration.zero);
    final second = controller.run(config);
    await Future<void>.delayed(Duration.zero);
    expect(repository.tokens[0].isCancelled, isTrue);
    expect(repository.tokens[1].isCancelled, isFalse);
    repository.completions[0].complete('stale');
    await first;
    expect(controller.state.isLoading, isTrue);
    controller.clear();
    expect(repository.tokens[1].isCancelled, isTrue);
    repository.completions[1].complete('cleared');
    await second;
    expect(controller.state, const AsyncData<String?>(null));
    final third = controller.run(config);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    expect(repository.tokens[2].isCancelled, isTrue);
    repository.completions[2].complete('disposed');
    await third;
  });

  test('C-25 zone cancellation interrupts an in-flight HTTP probe', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    final subscription = server.listen((request) async {
      await request.drain<void>();
      arrived.complete();
      // Deliberately leave the response pending until cancellation.
    });
    try {
      final token = CancelToken();
      final probe = TranslationApiClient.runWithProbeCancelToken(
        token,
        () => const TranslationApiClient().testConnection(
          config: config.copyWith(
            apiBaseUrl: 'http://127.0.0.1:${server.port}',
            httpProxy: '',
          ),
        ),
      );
      final assertion = expectLater(
        probe,
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await arrived.future.timeout(const Duration(seconds: 5));
      token.cancel();
      await assertion.timeout(const Duration(seconds: 5));
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  final cases = <(Object, String, String)>[
    (
      StateError('HTTP 401'),
      '认证失败',
      'HTTP 401 authentication failed for api.example.com. Check that the API key is valid, active, and copied without extra spaces.',
    ),
    (
      StateError('HTTP 403'),
      '访问权限',
      'HTTP 403 permission denied for api.example.com. Check whether this API key can use example-model and whether the account has access.',
    ),
    (
      StateError('HTTP 404'),
      '接口地址',
      'HTTP 404 from api.example.com. Check the Base URL, keep only the provider root or /v1 path, and verify that example-model exists.',
    ),
    (
      StateError('HTTP 429'),
      '请求受限',
      'HTTP 429 rate limit from api.example.com. Lower concurrency, wait for quota to recover, or check the provider billing/rate limit page.',
    ),
    (
      StateError('HTTP 503'),
      '服务器错误',
      'HTTP 503 from api.example.com. The provider is returning a server error; retry later or test the same key in the provider console.',
    ),
    (
      StateError('TLS handshake'),
      '握手失败',
      'TLS handshake failed for api.example.com. Check the endpoint, proxy/VPN, device date, and whether this network intercepts certificates.',
    ),
    (
      StateError('Failed host lookup'),
      '解析失败',
      'DNS lookup failed for api.example.com. Check the Base URL spelling and whether the current network or VPN can resolve the provider host.',
    ),
    (
      StateError('receive timeout'),
      '超时',
      'Connection to api.example.com timed out. Try a longer timeout, a more stable network, or a reachable proxy/VPN.',
    ),
    (
      StateError('model does not exist'),
      '未识别模型',
      'The provider did not recognize example-model. Check the model name exactly as listed by the API provider.',
    ),
    (
      StateError('unexpected transport failure'),
      '连接测试失败',
      'Connection test failed for api.example.com. Details: Bad state: unexpected transport failure',
    ),
    (
      const MissingApiConfigurationException(),
      '请先填写',
      'Fill in the Base URL, API key, and model before testing the connection.',
    ),
  ];
  for (final (error, chinese, english) in cases) {
    test('C-26 localized diagnostic: $chinese', () {
      expect(
        ConnectionDiagnostic.fromError(
          error,
          config: config.copyWith(uiLanguage: UiLanguage.chinese),
        ).message,
        contains(chinese),
      );
      expect(
        ConnectionDiagnostic.fromError(error, config: config).message,
        english,
      );
    });
  }
  test('C-26 missing API host uses a localized fallback', () {
    expect(
      ConnectionDiagnostic.fromError(
        StateError('unexpected'),
        config: config.copyWith(apiBaseUrl: '', uiLanguage: UiLanguage.chinese),
      ).message,
      contains('API 主机'),
    );
    expect(
      ConnectionDiagnostic.fromError(
        StateError('unexpected'),
        config: config.copyWith(apiBaseUrl: ''),
      ).message,
      contains('the API host'),
    );
  });
}
