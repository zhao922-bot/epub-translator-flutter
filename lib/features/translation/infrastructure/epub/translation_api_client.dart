import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../../shared/localization/app_strings.dart';

import '../../domain/models/translation_config.dart';
import '../../domain/repositories/translation_repository.dart';
import '../translation_response_guard.dart';
import 'cancellation_listener.dart';

/// Thrown when a translation, style, or memory reply cannot be parsed as JSON
/// (the message content is missing or is not a JSON object).
///
/// Unlike a well-formed reply that fails validation (wrong block ids, a
/// failed residual-quality gate, an empty block), an unparseable reply is —
/// at temperature 0.2 — almost always deterministic for the same prompt, so
/// the batch-level retry policy skips re-sending the whole batch and goes
/// straight to the cheaper per-block fallback instead of billing
/// [TranslationConfig.maxRetries] identical full-batch requests.
class TranslationParseException extends FormatException {
  const TranslationParseException(super.message);
}

class MissingApiConfigurationException extends FormatException {
  const MissingApiConfigurationException()
    : super(
        'API base URL, API key, and model are required before testing the connection.',
      );
}

class ProxyAuthenticationException implements Exception {
  const ProxyAuthenticationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Counts actual HTTP attempts (including bounded truncation retries), not
/// orchestration calls. No headers, prompts or reply content are retained.
class TranslationApiMetrics {
  int requests = 0,
      errors = 0,
      promptTokens = 0,
      completionTokens = 0,
      elapsedMs = 0;
  int usageReportedRequests = 0;
  final Map<String, int> byKind = {};
  final Map<String, int> elapsedMsByKind = {},
      promptTokensByKind = {},
      completionTokensByKind = {};
  Map<String, Object> toJson() => {
    'requests': requests,
    'errors': errors,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'elapsedMs': elapsedMs,
    'byKind': Map<String, int>.from(byKind),
    'usageReportedRequests': usageReportedRequests,
    'elapsedMsByKind': Map<String, int>.from(elapsedMsByKind),
    'promptTokensByKind': Map<String, int>.from(promptTokensByKind),
    'completionTokensByKind': Map<String, int>.from(completionTokensByKind),
  };
  void add(TranslationApiMetrics other) {
    usageReportedRequests += other.usageReportedRequests;
    for (final pair in [
      (elapsedMsByKind, other.elapsedMsByKind),
      (promptTokensByKind, other.promptTokensByKind),
      (completionTokensByKind, other.completionTokensByKind),
    ]) {
      for (final e in pair.$2.entries) {
        pair.$1.update(e.key, (v) => v + e.value, ifAbsent: () => e.value);
      }
    }
    requests += other.requests;
    errors += other.errors;
    promptTokens += other.promptTokens;
    completionTokens += other.completionTokens;
    elapsedMs += other.elapsedMs;
    for (final e in other.byKind.entries) {
      byKind.update(e.key, (v) => v + e.value, ifAbsent: () => e.value);
    }
  }
}

// Some Dart SDKs retry cached Basic proxy credentials without invoking
// authenticateProxy again. Scope the transport guard to each adapter fetch,
// so concurrent requests and later successful requests have separate budgets.
final Object _proxyAttemptZoneKey = Object();

class _ProxyAttempt {
  final Set<Uri> credentialDestinations = <Uri>{};
}

class _ProxyAwareAdapter extends IOHttpClientAdapter {
  _ProxyAwareAdapter({required super.createHttpClient});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => runZoned(
    () => super.fetch(options, requestStream, cancelFuture),
    zoneValues: {_proxyAttemptZoneKey: _ProxyAttempt()},
  );
}

/// Why a user-typed proxy setting cannot be used as an HTTP proxy.
enum ProxySettingError {
  /// The value is not shaped like `host:port` or `http://host:port`.
  invalidFormat,

  /// An explicit scheme other than `http://` (including `https://`).
  unsupportedScheme,
}

/// OpenAI-compatible chat client with retry / rate-limit handling.
class TranslationApiClient {
  const TranslationApiClient({this.sharedRateLimitDelayOverride});

  /// Allows offline transport fixtures to advance retries without real waits.
  final Duration? sharedRateLimitDelayOverride;

  TranslationApiMetrics metricsFor(Dio dio) =>
      dio.options.extra.putIfAbsent('apiMetrics', TranslationApiMetrics.new)
          as TranslationApiMetrics;

  static final RegExp _whitespace = RegExp(r'\s');
  static final RegExp _leadingReasoningBlocks = RegExp(
    r'^(?:\s*<think(?:\s[^>]*)?>[\s\S]*?</think>)+',
    caseSensitive: false,
  );
  static final RegExp _thinkOpeningPrefix = RegExp(
    r'<think(?=[\s>])',
    caseSensitive: false,
  );
  static final RegExp _jsonFence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
  static final RegExp _unsupportedParameter = RegExp(
    r'unsupported[\s_]+parameter',
  );
  static final RegExp _contextOverflow = RegExp(
    r'maximum.{0,24}context|context.{0,40}(length|window|limit|budget|'
    r'size|too (long|large)|exceed|overflow|exhaust)|'
    r'too many tokens|token.{0,24}limit|exceed.{0,24}tokens?|'
    r'max_tokens.{0,40}(exceed|limit|too (long|large)|maximum)|'
    r'(exceed|limit|too (long|large)|maximum).{0,40}max_tokens|'
    r'input.{0,20}too (long|large)|prompt.{0,20}too (long|large)|'
    r'message.{0,20}too (long|large)',
  );

  /// Carries cancellation through the repository's unchanged probe API.
  static final Object probeCancelTokenKey = Object();

  static Future<T> runWithProbeCancelToken<T>(
    CancelToken token,
    Future<T> Function() body,
  ) => runZoned(body, zoneValues: {probeCancelTokenKey: token});

  static bool _isValidProxyPort(int? port) =>
      port != null && port >= 1 && port <= 65535;

  Dio buildDio(TranslationConfig config) {
    final ProxySettingError? proxyError = validateProxySetting(
      config.httpProxy,
    );
    if (proxyError != null) {
      final AppStrings strings = AppStrings(config.uiLanguage);
      throw FormatException(
        proxyError == ProxySettingError.unsupportedScheme
            ? strings.httpProxyUnsupportedScheme
            : strings.httpProxyInvalidFormat,
      );
    }
    final Dio dio = Dio(
      BaseOptions(
        baseUrl: normalizedBaseUrl(config.apiBaseUrl),
        extra: <String, dynamic>{
          'reasoningEffort': config.effectiveReasoningEffort,
          'reasoningModel':
              config.isGlm53 || config.effectiveReasoningEffort != null,
          'maxOutputTokens': config.maxOutputTokens.clamp(512, 32768),
        },
        headers: <String, String>{
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
          'Connection': 'keep-alive',
          'User-Agent': 'epub-translator-flutter/1.0',
        },
        connectTimeout: Duration(seconds: config.timeoutSeconds),
        receiveTimeout: Duration(seconds: config.timeoutSeconds),
        sendTimeout: Duration(seconds: config.timeoutSeconds),
      ),
    );
    final metrics = metricsFor(dio);
    void finish(RequestOptions options, dynamic data, {bool failed = false}) {
      final watch = options.extra.remove('apiWatch') as Stopwatch?;
      if (watch == null) return;
      final kind = options.extra['requestKind'] as String? ?? 'translation';
      metrics.elapsedMsByKind.update(
        kind,
        (v) => v + watch.elapsedMilliseconds,
        ifAbsent: () => watch.elapsedMilliseconds,
      );
      metrics.elapsedMs += watch.elapsedMilliseconds;
      if (failed) metrics.errors++;
      final usage = data is Map ? data['usage'] : null;
      if (usage is Map) {
        if (usage['prompt_tokens'] is int &&
            usage['completion_tokens'] is int) {
          metrics.usageReportedRequests++;
        }
        if (usage['prompt_tokens'] is int) {
          final count = max(0, usage['prompt_tokens'] as int);
          metrics.promptTokens += count;
          metrics.promptTokensByKind.update(
            kind,
            (v) => v + count,
            ifAbsent: () => count,
          );
        }
        if (usage['completion_tokens'] is int) {
          final count = max(0, usage['completion_tokens'] as int);
          metrics.completionTokens += count;
          metrics.completionTokensByKind.update(
            kind,
            (v) => v + count,
            ifAbsent: () => count,
          );
        }
      }
    }

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra['apiWatch'] = Stopwatch()..start();
          metrics.requests++;
          final kind = options.extra['requestKind'] as String? ?? 'translation';
          metrics.byKind.update(kind, (v) => v + 1, ifAbsent: () => 1);
          handler.next(options);
        },
        onResponse: (response, handler) {
          finish(response.requestOptions, response.data);
          handler.next(response);
        },
        onError: (error, handler) {
          finish(error.requestOptions, error.response?.data, failed: true);
          handler.next(error);
        },
      ),
    );

    final proxyFailureMessage = config.uiLanguage == UiLanguage.chinese
        ? '代理认证失败（HTTP 407），请检查代理用户名和密码。'
        : 'Proxy authentication failed (HTTP 407). Check the proxy username and password.';
    dio.httpClientAdapter = _ProxyAwareAdapter(
      createHttpClient: () {
        final HttpClient client = HttpClient()
          ..connectionTimeout = Duration(seconds: config.timeoutSeconds)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = max(4, config.maxConcurrent * 2)
          ..userAgent = 'epub-translator-flutter/1.0';
        // Dart's HttpClient only honors proxy *environment variables*;
        // the Windows system proxy and the Android Wi-Fi proxy are invisible
        // to it, so an explicit user-configured proxy wins here. Local and
        // private destinations always bypass it (no_proxy semantics).
        final String? proxy = proxyHostPort(config.httpProxy);
        // An empty setting means disabled, including environment proxies.
        client.findProxy = (_) => 'DIRECT';
        if (proxy != null) {
          client.findProxy = (Uri uri) => proxyForUri(proxy, uri);
          final String value = config.httpProxy.trim();
          final Uri proxyUri = Uri.parse(_proxyUriValue(value));
          if (proxyUri.userInfo.isNotEmpty) {
            final int separator = proxyUri.userInfo.indexOf(':');
            final String username = Uri.decodeComponent(
              separator < 0
                  ? proxyUri.userInfo
                  : proxyUri.userInfo.substring(0, separator),
            );
            final String password = separator < 0
                ? ''
                : Uri.decodeComponent(
                    proxyUri.userInfo.substring(separator + 1),
                  );
            final attemptedChallenges = <(String, int, String, String)>{};
            client.findProxy = (uri) {
              final selection = proxyForUri(proxy, uri);
              final attempt =
                  Zone.current[_proxyAttemptZoneKey] as _ProxyAttempt?;
              if (selection != 'DIRECT' &&
                  attemptedChallenges.isNotEmpty &&
                  attempt != null) {
                if (!attempt.credentialDestinations.add(uri)) {
                  throw ProxyAuthenticationException(proxyFailureMessage);
                }
              }
              return selection;
            };
            client.authenticateProxy = (host, port, scheme, realm) async {
              // Credentials belong to this proxy, never the API origin.
              if (scheme.toLowerCase() != 'basic') return false;
              if (!attemptedChallenges.add((
                host.toLowerCase(),
                port,
                scheme.toLowerCase(),
                realm ?? '',
              ))) {
                return false;
              }
              client.addProxyCredentials(
                host,
                port,
                realm ?? '',
                HttpClientBasicCredentials(username, password),
              );
              return true;
            };
          }
        }
        return client;
      },
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          // HTTPS CONNECT failures have no Response; HttpClient reports the 407
          // as an HttpException instead. Normalize both transports identically.
          if (error.error is ProxyAuthenticationException ||
              error.response?.statusCode ==
                  HttpStatus.proxyAuthenticationRequired ||
              (error.error is HttpException &&
                  RegExp(
                    r'\b407\b',
                  ).hasMatch((error.error as HttpException).message))) {
            handler.next(
              error.copyWith(
                message: proxyFailureMessage,
                error: ProxyAuthenticationException(proxyFailureMessage),
              ),
            );
            return;
          }
          handler.next(error);
        },
      ),
    );
    return dio;
  }

  /// Normalizes a user-typed proxy setting into `"host:port"`, or null when
  /// it is empty or malformed. Accepts `host:port` and `http://host:port`
  /// (IPv6 literals need brackets: `[::1]:8080`). HTTPS proxies are rejected:
  /// Dart's HttpClient PROXY transport does not establish TLS to the proxy,
  /// and stripping that scheme would expose proxy credentials in plaintext.
  /// Other schemes (e.g. `socks5://`) are also rejected. Use
  /// [validateProxySetting] to tell the user why a value is invalid.
  static String? proxyHostPort(String value) {
    return _parseProxySetting(value).hostPort;
  }

  /// Why a user-typed proxy setting is unusable, for inline error display.
  ///
  /// Returns null when the value is empty (proxy disabled) or valid.
  /// Unlike [proxyHostPort], this distinguishes "wrong shape" from
  /// "unsupported protocol" so the settings page can explain the problem
  /// instead of saving a value that silently does nothing.
  static ProxySettingError? validateProxySetting(String value) {
    return _parseProxySetting(value).error;
  }

  static String _proxyUriValue(String value) {
    final String uriValue = value.contains('://') ? value : 'http://$value';
    final int authorityStart = uriValue.indexOf('://') + 3;
    final int authorityEnd = uriValue.indexOf(RegExp(r'[/?#]'), authorityStart);
    final int end = authorityEnd < 0 ? uriValue.length : authorityEnd;
    final String authority = uriValue.substring(authorityStart, end);
    final int separator = authority.lastIndexOf('@');
    if (separator < 0) return uriValue;
    // The last @ separates credentials from the host. Escape earlier literal
    // @ characters so Uri parsing and transport agree on the same userinfo.
    return uriValue.replaceRange(
      authorityStart,
      authorityStart + separator,
      authority.substring(0, separator).replaceAll('@', '%40'),
    );
  }

  /// Validation and transport must agree, including explicit default ports
  /// (which Uri normalizes away) and brackets required by HttpClient for IPv6.
  static ({String? hostPort, ProxySettingError? error}) _parseProxySetting(
    String value,
  ) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return (hostPort: null, error: null);
    }
    const invalid = (hostPort: null, error: ProxySettingError.invalidFormat);
    final bool hasScheme = trimmed.contains('://');
    final String hostPort = trimmed.substring(trimmed.lastIndexOf('@') + 1);
    if (!hasScheme &&
        !RegExp(r'^(?:\[[^\]]+\]|[^:/?#\s]+):\d{1,5}$').hasMatch(hostPort)) {
      return invalid;
    }
    final String uriValue = _proxyUriValue(trimmed);
    final Uri? parsed = Uri.tryParse(uriValue);
    // Inspect the original authority so explicit :80 / :443 remain valid.
    final String authority = uriValue
        .substring(uriValue.indexOf('://') + 3)
        .split(RegExp(r'[/?#]'))
        .first;
    final RegExpMatch? portMatch = RegExp(r':(\d{1,5})$').firstMatch(authority);
    final int? port = int.tryParse(portMatch?.group(1) ?? '');
    if (parsed == null ||
        parsed.host.isEmpty ||
        RegExp(r'\s').hasMatch(authority) ||
        !_isValidProxyPort(port)) {
      return invalid;
    }
    if (parsed.scheme != 'http') {
      return (hostPort: null, error: ProxySettingError.unsupportedScheme);
    }
    final String host = parsed.host;
    final String formattedHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return (hostPort: '$formattedHost:$port', error: null);
  }

  /// PAC-style proxy selector for [hostPort] (`"host:port"`) with no_proxy
  /// semantics: loopback, single-label, private-use and link-local
  /// destinations bypass the proxy via `DIRECT`.
  static String proxyForUri(String hostPort, Uri uri) {
    return _isProxyBypassHost(uri.host) ? 'DIRECT' : 'PROXY $hostPort';
  }

  static bool _isProxyBypassHost(String host) {
    final String name = host.trim().toLowerCase().replaceFirst(
      RegExp(r'\.$'),
      '',
    );
    if (name.isEmpty || name == 'localhost' || name.endsWith('.localhost')) {
      return true;
    }
    // Parse IP literals before the single-label rule: an unbracketed IPv6
    // literal (Dart's Uri.host strips the brackets, e.g.
    // "2001:4860:4860::8888") contains no '.' and must not be mistaken for
    // a local intranet hostname.
    final String literal = name.startsWith('[') && name.endsWith(']')
        ? name.substring(1, name.length - 1)
        : name;
    final InternetAddress? address = InternetAddress.tryParse(literal);
    if (address == null) {
      // Single-label names (e.g. intranet hosts) are treated as local.
      if (!name.contains('.')) {
        return true;
      }
      return false;
    }
    final List<int> bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      // 127/8 loopback, 10/8, 172.16/12, 192.168/16, 169.254/16 link-local.
      if (bytes[0] == 127 || bytes[0] == 10) {
        return true;
      }
      if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) {
        return true;
      }
      if (bytes[0] == 192 && bytes[1] == 168) {
        return true;
      }
      if (bytes[0] == 169 && bytes[1] == 254) {
        return true;
      }
      return false;
    }
    // IPv4-mapped IPv6 (::ffff:a.b.c.d) arrives as a 16-byte address: judge
    // the embedded IPv4 octets with the IPv4 rules above instead of falling
    // through to the IPv6 checks (where ::ffff:127.0.0.1 would miss the
    // ::1 loopback test and be sent through the user's proxy).
    if (bytes.length == 16 &&
        bytes.sublist(0, 10).every((int b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      final int m0 = bytes[12];
      if (m0 == 127 || m0 == 10) {
        return true;
      }
      if (m0 == 172 && bytes[13] >= 16 && bytes[13] <= 31) {
        return true;
      }
      if (m0 == 192 && bytes[13] == 168) {
        return true;
      }
      if (m0 == 169 && bytes[13] == 254) {
        return true;
      }
      return false;
    }
    // IPv6: ::1 loopback, fe80::/10 link-local, fc00::/7 unique-local.
    if (bytes.length == 16 &&
        bytes.sublist(0, 15).every((int b) => b == 0) &&
        bytes[15] == 1) {
      return true;
    }
    if (bytes.length == 16 && (bytes[0] & 0xfe) == 0xfc) {
      return true;
    }
    if (bytes.length == 16 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
      return true;
    }
    return false;
  }

  Future<String> testConnection({required TranslationConfig config}) async {
    if (config.apiBaseUrl.trim().isEmpty ||
        config.apiKey.trim().isEmpty ||
        config.model.trim().isEmpty) {
      throw const MissingApiConfigurationException();
    }

    // Fail fast on a proxy the client cannot use: without this the probe
    // would die later with a generic connection error that says nothing
    // about the misconfigured proxy field.
    final ProxySettingError? proxyError = validateProxySetting(
      config.httpProxy,
    );
    if (proxyError != null) {
      final AppStrings strings = AppStrings(config.uiLanguage);
      throw FormatException(
        proxyError == ProxySettingError.unsupportedScheme
            ? strings.httpProxyUnsupportedScheme
            : strings.httpProxyInvalidFormat,
      );
    }

    final Dio dio = buildDio(config);
    try {
      final Map<String, dynamic> requestData = <String, dynamic>{
        'model': config.model,
        'temperature': 0.2,
        'max_tokens': 24,
        'messages': <Map<String, String>>[
          <String, String>{
            'role': 'system',
            'content':
                'You are a connectivity probe for an EPUB translator. Reply with OK only.',
          },
          <String, String>{
            'role': 'user',
            'content':
                'Probe request for ${config.targetLanguage}. Reply with OK only.',
          },
        ],
      };
      final Response<dynamic> response = await postChatCompletions(
        dio: dio,
        data: requestData,
        cancelToken: Zone.current[probeCancelTokenKey] as CancelToken?,
      );
      final String content = extractMessageContent(
        response.data,
        requireNonEmpty: true,
      );
      final String host = Uri.parse(normalizedBaseUrl(config.apiBaseUrl)).host;
      return AppStrings(config.uiLanguage).connectionDetail(host, content);
    } on TranslationParseException catch (error) {
      throw TranslationParseException(
        '${AppStrings(config.uiLanguage).connectionResponseParseError} ${error.message}',
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      if (error.error is HandshakeException) {
        final String host = Uri.parse(
          normalizedBaseUrl(config.apiBaseUrl),
        ).host;
        throw StateError(
          'TLS handshake failed while connecting to $host. Check the endpoint, proxy/VPN, and whether this network intercepts certificates.',
        );
      }
      final int? statusCode = error.response?.statusCode;
      final String host = Uri.parse(normalizedBaseUrl(config.apiBaseUrl)).host;
      throw StateError(
        'Connection test failed for $host${statusCode != null ? ' with HTTP $statusCode' : ''}: ${error.message}',
      );
    } finally {
      // Each probe builds a fresh Dio (with its own HttpClient connection
      // pool); close it so sockets are not left lingering.
      dio.close(force: true);
    }
  }

  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    // Dio concatenates baseUrl and a relative path as strings. Construct the
    // absolute endpoint first so a base query/fragment cannot absorb the path.
    final Uri base = Uri.parse(dio.options.baseUrl);
    final Uri endpoint = base.replace(
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/chat/completions',
      fragment: '',
    );
    final request = Map<String, dynamic>.from(data);
    final cap = (dio.options.extra['maxOutputTokens'] as int? ?? 8192).clamp(
      512,
      32768,
    );
    final reasoning = dio.options.extra['reasoningEffort'] as String?;
    if (reasoning != null) request['reasoning_effort'] = reasoning;
    final requested = request['max_tokens'] as int? ?? 900;
    request['max_tokens'] =
        (dio.options.extra['reasoningModel'] == true
                ? max(4096, requested)
                : requested)
            .clamp(1, cap);
    // A length-truncated answer cannot be cached as complete. Retry at most
    // once with a genuinely larger budget, never repeat an identical paid call.
    var kind = 'translation';
    final messages = request['messages'];
    if (messages is List && messages.isNotEmpty) {
      final system = messages.first is Map
          ? messages.first['content'].toString()
          : '';
      if (system.contains('connectivity probe')) kind = 'probe';
      if (system.startsWith('Translate the book title')) kind = 'bookTitle';
      try {
        final payload = jsonDecode((messages.last as Map)['content'] as String);
        if (payload is Map && payload['kind'] is String) {
          kind = payload['kind'] as String;
        }
      } on Object {
        /* Normal prose/title requests are not JSON. */
      }
    }
    for (var attempt = 0; ; attempt++) {
      final response = await dio.post<dynamic>(
        endpoint.toString(),
        data: request,
        cancelToken: cancelToken,
        options: Options(extra: {'requestKind': kind}),
      );
      final body = response.data;
      final choices = body is Map ? body['choices'] : null;
      final truncated =
          choices is List &&
          choices.isNotEmpty &&
          choices.first is Map &&
          choices.first['finish_reason'] == 'length';
      final budget = request['max_tokens'] as int;
      if (!truncated ||
          kind == 'semanticReview' ||
          attempt == 1 ||
          budget >= cap) {
        return response;
      }
      request['max_tokens'] = min(cap, budget * 2);
    }
  }

  Future<T> runRetried<T>({
    required TranslationConfig config,
    required Future<T> Function() operation,
    bool Function(Object error)? shouldRetry,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    int? maxAttemptsOverride,
    void Function()? throwIfCancelled,
  }) async {
    for (int attempt = 1; ; attempt += 1) {
      try {
        throwIfCancelled?.call();
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        return await operation();
      } catch (error, stackTrace) {
        if (error is TranslationCancelledException || isCancelError(error)) {
          throw const TranslationCancelledException();
        }
        // Callback cancellation must win before retry policy/backoff, even
        // when it changed while the failed request was completing.
        throwIfCancelled?.call();
        final bool retryable = shouldRetry?.call(error) ?? true;
        final int maxAttempts =
            maxAttemptsOverride ?? maxAttemptsForError(config, error);
        if (!retryable || attempt >= maxAttempts) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        final Duration retryDelay =
            retryDelayOverride ?? retryDelayForError(config, error, attempt);
        await delayUnlessCancelled(retryDelay, cancelToken: cancelToken);
      }
    }
  }

  /// Sleeps for [delay] but aborts immediately when [cancelToken] is cancelled.
  static Future<void> delayUnlessCancelled(
    Duration delay, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const TranslationCancelledException();
    }
    if (delay <= Duration.zero) {
      return;
    }
    if (cancelToken == null) {
      await Future<void>.delayed(delay);
      return;
    }

    final completed = Completer<void>();
    final timer = Timer(delay, () => completed.complete());
    final detach = CancellationListener.listen(cancelToken, () {
      timer.cancel();
      if (!completed.isCompleted) {
        completed.completeError(const TranslationCancelledException());
      }
    });
    try {
      await completed.future;
    } finally {
      timer.cancel();
      detach();
    }

    if (cancelToken.isCancelled) {
      throw const TranslationCancelledException();
    }
  }

  String extractMessageContent(
    dynamic responseData, {
    bool requireNonEmpty = false,
  }) {
    // A proxy/gateway may answer with a plain string (or another non-JSON
    // shape) instead of the chat-completions object. Report that as a
    // deterministic parse failure so the retry policy does not burn
    // maxRetries re-sending a request the endpoint cannot answer.
    if (responseData is! Map<String, dynamic>) {
      throw TranslationParseException(
        'Translation API response is not a JSON object '
        '(${responseData.runtimeType}).',
      );
    }
    // Validate the choices envelope structurally before indexing: `[]?[0]`
    // throws RangeError on an empty list and `?['message']` on a non-Map
    // choice throws TypeError — both would bypass the TranslationParseException
    // contract (deterministic, no retry) and burn maxRetries of paid retries
    // before killing the whole run.
    final dynamic rawChoices = responseData['choices'];
    if (rawChoices is! List || rawChoices.isEmpty) {
      throw TranslationParseException(
        'Translation API response has no usable choices '
        '(${rawChoices.runtimeType}).',
      );
    }
    final dynamic firstChoice = rawChoices.first;
    if (firstChoice is! Map<String, dynamic>) {
      throw TranslationParseException(
        'Translation API response choice is not a JSON object '
        '(${firstChoice.runtimeType}).',
      );
    }
    // A complete JSON/HTML envelope can still contain incomplete prose.
    // Reject explicit non-natural completion statuses before any consumer
    // validates, caches, or displays the content. Older compatible gateways
    // sometimes omit this field; retain their existing behavior.
    final dynamic finishReason = firstChoice['finish_reason'];
    if (finishReason != null && finishReason != 'stop') {
      throw TranslationParseException(
        'Translation API response did not finish normally '
        '(finish_reason=$finishReason). '
        '${finishReason == 'length' ? 'Increase the output token limit or reduce reasoning effort in settings.' : ''}',
      );
    }
    final dynamic rawMessage = firstChoice['message'];
    if (rawMessage is! Map<String, dynamic>) {
      throw const TranslationParseException(
        'Translation API response message is not a JSON object.',
      );
    }
    final dynamic rawContent = rawMessage['content'];
    final String content = switch (rawContent) {
      String value => value.trim(),
      List<dynamic> value =>
        value
            .map<dynamic>(
              (dynamic item) =>
                  item is Map<String, dynamic> ? item['text'] : item,
            )
            .whereType<String>()
            .join()
            .trim(),
      _ => throw const TranslationParseException(
        'Translation API response content is not text or a content-parts list.',
      ),
    };
    final String visibleContent = _stripReasoningBlocks(content);
    // Translation consumers already validate empty output with their own
    // quality/retry policy. Probes must reject it before reporting success.
    if (requireNonEmpty && visibleContent.isEmpty) {
      throw const TranslationParseException(
        'Translation API response has no visible message content.',
      );
    }
    return visibleContent;
  }

  /// A trailing reasoning block needs a complete closing tag at the end.
  static bool _endsWithThinkClose(String content) {
    int end = content.length;
    // Match the non-Unicode regexp's trailing \s*: tab, LF, VT, FF, CR, space.
    while (end > 0) {
      final int unit = content.codeUnitAt(end - 1);
      if (unit != 0x20 &&
          unit != 0x09 &&
          unit != 0x0A &&
          unit != 0x0B &&
          unit != 0x0C &&
          unit != 0x0D) {
        break;
      }
      end--;
    }
    const String close = '</think>';
    if (end < close.length) return false;
    return content.substring(end - close.length, end).toLowerCase() == close;
  }

  /// Protect a JSON envelope's literal tags before scanning its suffix.
  /// Each JSON string is traversed once, including its escape sequences.
  int _jsonEnvelopeEnd(String content) {
    int start = 0;
    while (start < content.length && _whitespace.hasMatch(content[start])) {
      start++;
    }
    if (content.startsWith('```', start)) {
      start += 3;
      if (content.startsWith('json', start)) start += 4;
      while (start < content.length && _whitespace.hasMatch(content[start])) {
        start++;
      }
    }
    if (start >= content.length ||
        (content[start] != '{' && content[start] != '[')) {
      return 0;
    }
    int depth = 0;
    for (int cursor = start; cursor < content.length; cursor++) {
      final String character = content[cursor];
      if (character == '"') {
        try {
          cursor = _jsonStringEnd(content, cursor);
        } on FormatException {
          return 0;
        }
      } else if (character == '{' || character == '[') {
        depth++;
      } else if (character == '}' || character == ']') {
        if (--depth == 0) return cursor + 1;
      }
    }
    return 0;
  }

  /// Scan backwards over complete, consecutive suffix blocks. A preceding
  /// closing tag bounds each scan; no prefix is repeatedly searched.
  int _trailingReasoningStart(String content) {
    final int lowerBound = _jsonEnvelopeEnd(content);
    int strippedEnd = content.length;
    int end = strippedEnd;
    const String close = '</think>';
    while (end > lowerBound) {
      while (end > lowerBound && _whitespace.hasMatch(content[end - 1])) {
        end--;
      }
      final int closingStart = end - close.length;
      if (closingStart < lowerBound ||
          content.substring(closingStart, end).toLowerCase() != close) {
        break;
      }
      int opening = -1;
      int tagEnd = -1;
      bool sawClosingTag = false;
      for (int cursor = closingStart - 1; cursor >= lowerBound; cursor--) {
        if (content[cursor] == '>') {
          if (sawClosingTag) break;
          tagEnd = cursor;
        }
        if (content[cursor] != '<') continue;
        if (cursor + close.length <= closingStart &&
            content.substring(cursor, cursor + close.length).toLowerCase() ==
                close) {
          // An opening tag's attributes may contain this literal close.
          // Search only to the preceding '>', never across another block.
          sawClosingTag = true;
          continue;
        }
        final Match? prefix = _thinkOpeningPrefix.matchAsPrefix(
          content,
          cursor,
        );
        if (prefix != null && tagEnd >= prefix.end) {
          // Keep the earliest opening before the next closing tag, matching
          // the previous stripping semantics for nested opening tags.
          opening = cursor;
        }
      }
      if (opening < 0) break;
      strippedEnd = end = opening;
    }
    return strippedEnd;
  }

  /// Removes `<think>...</think>` reasoning blocks that reasoning models
  /// (for example DeepSeek-R1 variants) may prepend or append to the content.
  ///
  /// These blocks are model-internal reasoning, not translation output; they
  /// would otherwise break strict JSON parsing in batch mode and be mistaken
  /// for untranslated source text in single-block mode.
  String _stripReasoningBlocks(String content) {
    // Interior blocks can be literal translation text, including JSON values.
    String stripped = content.replaceFirst(_leadingReasoningBlocks, '');
    if (_endsWithThinkClose(stripped)) {
      stripped = stripped.substring(0, _trailingReasoningStart(stripped));
    }
    return stripped.trim();
  }

  static String _stripJsonFence(String content) {
    final String normalized = content.trim();
    final Match? fenced = _jsonFence.firstMatch(normalized);
    return fenced?.group(1)?.trim() ?? normalized;
  }

  Map<String, dynamic> decodeJsonObject(String content) {
    final String candidate = _stripJsonFence(content);
    try {
      return _decodeJsonObjectStrict(candidate);
    } on FormatException catch (original, stackTrace) {
      final String repaired = _escapeBareQuotesInsideJsonStrings(candidate);
      if (repaired == candidate) {
        Error.throwWithStackTrace(original, stackTrace);
      }
      try {
        return _decodeJsonObjectStrict(repaired);
      } on FormatException {
        Error.throwWithStackTrace(original, stackTrace);
      }
    }
  }

  /// Decodes [content] after stripping an optional markdown fence, without
  /// requiring the result to be an object. Validators use this to tell a
  /// legally-decoded non-object (deterministic schema failure) apart from
  /// broken syntax (retryable jitter): the fence must be stripped first,
  /// otherwise a fenced non-object always looks like broken syntax.
  ({bool valid, Object? value}) decodeJsonValueAfterFenceStrip(String content) {
    try {
      return (valid: true, value: jsonDecode(_stripJsonFence(content)));
    } on FormatException {
      return (valid: false, value: null);
    }
  }

  Map<String, dynamic> _decodeJsonObjectStrict(String candidate) {
    final Object? decoded = jsonDecode(candidate);
    _ensureNoDuplicateObjectKeys(candidate);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Model response is not a JSON object.');
    }
    return decoded;
  }

  /// Extracts the message content from a chat-completions response and
  /// decodes it as a JSON object for translation, style, and memory requests.
  /// Any failure to parse the reply becomes a [TranslationParseException]
  /// so the shared retry policy can tell "the model did not return JSON" from
  /// "the JSON failed validation".
  Map<String, dynamic> decodeBatchJsonPayload(dynamic responseData) {
    try {
      return decodeJsonObject(extractMessageContent(responseData));
    } on FormatException catch (error) {
      throw TranslationParseException(error.message);
    }
  }

  void _ensureNoDuplicateObjectKeys(String source) {
    final List<Set<String>?> containerKeys = <Set<String>?>[];
    for (int index = 0; index < source.length; index += 1) {
      final String character = source[index];
      if (character == '{') {
        containerKeys.add(<String>{});
        continue;
      }
      if (character == '[') {
        containerKeys.add(null);
        continue;
      }
      if (character == '}' || character == ']') {
        containerKeys.removeLast();
        continue;
      }
      if (character != '"') {
        continue;
      }

      final int end = _jsonStringEnd(source, index);
      final String? next = _nextNonWhitespaceCharacter(source, end + 1);
      if (next == ':' && containerKeys.isNotEmpty) {
        final Set<String>? keys = containerKeys.last;
        if (keys != null) {
          final String key =
              jsonDecode(source.substring(index, end + 1)) as String;
          if (!keys.add(key)) {
            throw FormatException(
              'Model response contains duplicate object key "$key".',
            );
          }
        }
      }
      index = end;
    }
  }

  int _jsonStringEnd(String source, int start) {
    bool escaped = false;
    for (int index = start + 1; index < source.length; index += 1) {
      final String character = source[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character == r'\') {
        escaped = true;
        continue;
      }
      if (character == '"') {
        return index;
      }
    }
    throw const FormatException('Unterminated JSON string.');
  }

  String _escapeBareQuotesInsideJsonStrings(String source) {
    final StringBuffer repaired = StringBuffer();
    bool inString = false;
    bool escaped = false;
    int repairedQuoteCount = 0;

    for (int index = 0; index < source.length; index += 1) {
      final String character = source[index];
      if (!inString) {
        repaired.write(character);
        if (character == '"') {
          inString = true;
          repairedQuoteCount = 0;
        }
        continue;
      }

      if (escaped) {
        repaired.write(character);
        escaped = false;
        continue;
      }
      if (character == r'\') {
        repaired.write(character);
        escaped = true;
        continue;
      }
      if (character != '"') {
        repaired.write(character);
        continue;
      }

      final String? next = _nextNonWhitespaceCharacter(source, index + 1);
      final bool closesString =
          next == null ||
          next == ':' ||
          next == ',' ||
          next == '}' ||
          next == ']';
      if (closesString) {
        if (repairedQuoteCount.isOdd) {
          return source;
        }
        repaired.write(character);
        inString = false;
      } else {
        if (index + 1 >= source.length || source[index + 1].trim().isEmpty) {
          return source;
        }
        repaired.write(r'\"');
        repairedQuoteCount += 1;
      }
    }

    return inString ? source : repaired.toString();
  }

  String? _nextNonWhitespaceCharacter(String source, int start) {
    for (int index = start; index < source.length; index += 1) {
      final String character = source[index];
      if (!_whitespace.hasMatch(character)) {
        return character;
      }
    }
    return null;
  }

  /// Normalizes a user-typed API base URL into `<scheme>://<host>[:port]<path>/v1`
  /// form. Embedded credentials, query and fragment components are rejected.
  /// Handles `/V1`
  /// (case-insensitive match, normalized to lowercase because a literal
  /// `/V1` 404s on case-sensitive servers), trailing slashes and a pasted
  /// `/chat/completions` suffix.
  String normalizedBaseUrl(String value) {
    TranslationConfig.validateApiUrl(value);
    String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    if (!trimmed.contains('://')) {
      trimmed = 'https://$trimmed';
    }
    final Uri uri = Uri.parse(trimmed);
    final List<String> segments = uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: true);
    if (segments.length >= 2 &&
        segments[segments.length - 2].toLowerCase() == 'chat' &&
        segments[segments.length - 1].toLowerCase() == 'completions') {
      segments.removeRange(segments.length - 2, segments.length);
    }
    if (segments.isEmpty || segments.last.toLowerCase() != 'v1') {
      segments.add('v1');
    } else {
      segments[segments.length - 1] = 'v1';
    }
    return uri.replace(pathSegments: segments).toString();
  }

  String lockedGlossaryInstruction(TranslationConfig config) {
    final String glossary = config.lockedGlossary.trim();
    if (glossary.isEmpty) {
      return '';
    }
    return ' Locked terminology (always honor these mappings):\n$glossary';
  }

  static bool isCancelError(Object error) {
    return error is DioException && CancelToken.isCancel(error);
  }

  static bool isReceiveTimeout(Object error) {
    return error is DioException &&
        error.type == DioExceptionType.receiveTimeout;
  }

  static bool isSendTimeout(Object error) {
    return error is DioException && error.type == DioExceptionType.sendTimeout;
  }

  static bool isConnectionTimeout(Object error) {
    return error is DioException &&
        error.type == DioExceptionType.connectionTimeout;
  }

  static bool isRequestTimeout(Object error) {
    return isReceiveTimeout(error) ||
        isSendTimeout(error) ||
        isConnectionTimeout(error);
  }

  static bool shouldFallbackBatchDioException(DioException error) {
    if (error.response?.statusCode == 413) {
      return true;
    }
    // A 400 that complains about context length / token limits is a size
    // problem, not a configuration problem: smaller payloads (per-block or
    // bisected requests) usually pass, so it takes the shrink fallback
    // instead of the deterministic fatal path.
    if (isContextOverflowError(error)) {
      return true;
    }
    // A send or receive timeout on a large batch often means the endpoint is
    // too slow for the whole batch rather than that translation failed. Fall
    // back to smaller single-block requests, which are far less likely to
    // time out, instead of failing the entire translation run.
    return error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout;
  }

  /// True when the provider rejected the request because it exceeds a
  /// context/output token limit (HTTP 400 with a context/token-limit
  /// message). Unlike other 400s this is payload-size dependent: a smaller
  /// request can succeed, so callers route it to the shrink fallback
  /// instead of treating it as a deterministic configuration error.
  ///
  /// The patterns require genuine length/overflow semantics (context
  /// length, too long, maximum context, token limit, ...). A bare
  /// "context" substring is NOT enough: gateway 400s about malformed
  /// structure (e.g. "invalid context: ...") must stay on the deterministic
  /// fail-fast path instead of being misrouted into shrink retries.
  static bool isContextOverflowError(Object error) {
    if (error is! DioException) {
      return false;
    }
    if (error.response?.statusCode != 400) {
      return false;
    }
    final String body = (error.response?.data?.toString() ?? '').toLowerCase();
    if (_unsupportedParameter.hasMatch(body)) {
      return false;
    }
    return _contextOverflow.hasMatch(body);
  }

  /// HTTP status codes that are deterministic configuration errors: a
  /// rejected request (400: context limit exceeded, content filter,
  /// malformed payload), a wrong or inactive API key (401), a key without
  /// access to the model (403), or a wrong Base URL / model name (404).
  /// Re-sending the same request cannot fix them, so callers must fail
  /// fast instead of burning retry attempts.
  ///
  /// A 403 is only deterministic when it is genuinely a permission problem:
  /// some gateways report rate limiting as 403 instead of 429. When the
  /// response carries a `Retry-After` header or the body mentions rate
  /// limiting / quota exhaustion, the error counts as a rate limit
  /// ([isRateLimitError]) and takes the retry path instead of failing fast.
  static bool isDeterministicHttpError(Object error) {
    if (error is DioException && error.error is ProxyAuthenticationException) {
      return true;
    }
    final int? statusCode = error is DioException
        ? error.response?.statusCode
        : null;
    if (statusCode == 400 ||
        statusCode == 401 ||
        statusCode == 404 ||
        statusCode == 407) {
      return true;
    }
    return statusCode == 403 && !isRateLimitError(error);
  }

  /// Precise user-facing message for [isDeterministicHttpError] failures,
  /// mirroring the settings-page connection diagnostic wording so a
  /// misconfigured key/URL fails loudly with an actionable hint.
  static String deterministicHttpErrorMessage(
    Object error,
    TranslationConfig config,
  ) {
    if (error is DioException && error.error is ProxyAuthenticationException) {
      return error.error.toString();
    }
    final int? statusCode = error is DioException
        ? error.response?.statusCode
        : null;
    final AppStrings strings = AppStrings(config.uiLanguage);
    final String host = _diagnosticHost(config);
    switch (statusCode) {
      case 400:
        return 'HTTP 400 from $host. The provider rejected the request itself (often a context limit or content filter); it will not succeed by retrying. Try a smaller chunk size or check the request content.';
      case 401:
        return strings.httpAuthError(host);
      case 403:
        return strings.httpForbiddenError(host, config.model);
      case 404:
        return strings.httpNotFoundError(host, config.model);
      case 407:
        return config.uiLanguage == UiLanguage.chinese
            ? '代理认证失败（HTTP 407），请检查代理用户名和密码。'
            : 'Proxy authentication failed (HTTP 407). Check the proxy username and password.';
      default:
        return 'HTTP $statusCode from $host. The provider rejected the request; check the Base URL, API key, and model name.';
    }
  }

  static String _diagnosticHost(TranslationConfig config) {
    try {
      final String value = config.apiBaseUrl.trim();
      final Uri uri = Uri.parse(
        value.contains('://') ? value : 'https://$value',
      );
      return uri.host.isEmpty ? 'the API host' : uri.host;
    } catch (_) {
      return 'the API host';
    }
  }

  static bool shouldRetryBatchError(Object error) {
    if (error is TranslationCancelledException || isCancelError(error)) {
      return false;
    }
    // 400/401/403/404 are deterministic errors (a 403 that looks
    // like rate limiting is already excluded by [isDeterministicHttpError]):
    // re-sending the whole batch would just bill the same doomed request
    // again.
    if (isDeterministicHttpError(error)) {
      return false;
    }
    // An unparseable reply is almost always deterministic for the same
    // prompt (see [TranslationParseException]): re-sending the whole batch
    // would just bill the same request again, so go straight to the
    // per-block fallback. Validation failures on a well-formed reply
    // (wrong ids, residual-quality gate, empty block) are often transient
    // and keep the normal batch retry policy.
    if (error is TranslationParseException ||
        error is NonTranslationReplyException) {
      return false;
    }
    return error is! DioException || !shouldFallbackBatchDioException(error);
  }

  static bool isRateLimitError(Object error) {
    if (error is! DioException) {
      return false;
    }
    if (error.response?.statusCode == 429) {
      return true;
    }
    // Some gateways signal rate limiting with 403 instead of 429 (often
    // with a Retry-After header or a "quota exceeded" style body). Those
    // must be retried, not treated as deterministic configuration errors.
    return error.response?.statusCode == 403 &&
        _looksLikeRateLimitResponse(error);
  }

  /// True when a 403 response carries the hallmarks of rate limiting: a
  /// `Retry-After` header, or a body mentioning rate limits / quota
  /// exhaustion (case-insensitive).
  static bool _looksLikeRateLimitResponse(DioException error) {
    final String? retryAfter = error.response?.headers
        .value('retry-after')
        ?.trim();
    if (retryAfter != null && retryAfter.isNotEmpty) {
      return true;
    }
    final String body = (error.response?.data?.toString() ?? '').toLowerCase();
    return body.contains('rate limit') ||
        body.contains('rate-limit') ||
        body.contains('ratelimit') ||
        body.contains('rate_limited') ||
        body.contains('quota') ||
        body.contains('too many requests');
  }

  static int maxAttemptsForError(TranslationConfig config, Object error) {
    if (error is DioException &&
        (error.error is ProxyAuthenticationException ||
            error.response?.statusCode ==
                HttpStatus.proxyAuthenticationRequired)) {
      return 1;
    }
    final int normalMaxAttempts = max(1, config.maxRetries);
    if (error is NonTranslationReplyException) return min(normalMaxAttempts, 2);
    if (isRateLimitError(error)) {
      return max(normalMaxAttempts, 8);
    }
    // A connection, send, or receive timeout means the endpoint did not
    // become usable within the configured window. Retrying the same request
    // four or more times can block the whole EPUB for many minutes; one
    // retry is enough to distinguish a transient stall before the caller
    // degrades it.
    if (isRequestTimeout(error)) {
      return min(normalMaxAttempts, 2);
    }
    return normalMaxAttempts;
  }

  static Duration retryDelayForError(
    TranslationConfig config,
    Object error,
    int attempt, {
    Random? random,
  }) {
    if (isRateLimitError(error)) {
      final Duration? retryAfter = retryAfterDelay(error);
      if (retryAfter != null) {
        // The server's Retry-After stays a hard minimum (never shortened),
        // but a small positive-only jitter desynchronizes batches that were
        // limited together so they don't wake in lockstep and re-trigger
        // the limit as a herd. Still refuses to stall a run past
        // [_maxServerCooldown]: fail loud with an actionable message
        // instead.
        if (retryAfter > _maxServerCooldown) {
          final int minutes = (retryAfter.inSeconds / 60).ceil();
          throw StateError(
            AppStrings(
              config.uiLanguage,
            ).rateLimitCooldownTooLong(_diagnosticHost(config), minutes),
          );
        }
        final Duration jittered = addPositiveJitter(
          retryAfter,
          random ?? Random(),
        );
        return jittered > _maxServerCooldown ? _maxServerCooldown : jittered;
      }
      final int baseSeconds = max(5, config.retryDelaySeconds);
      final int multiplier = 1 << min(attempt - 1, 4);
      // ±25% jitter: without it, maxConcurrent batches that hit a 429
      // together retry in lockstep and re-trigger the limit as a herd.
      return applyJitter(
        Duration(seconds: min(90, baseSeconds * multiplier)),
        random ?? Random(),
      );
    }
    // Exponential backoff with jitter for every other retryable failure
    // (transient 5xx, connection blips): without it, maxConcurrent batches
    // that fail together retry in lockstep and hammer the endpoint as a
    // herd. Same 90s cap as the rate-limit path.
    final int baseSeconds = max(1, config.retryDelaySeconds);
    final int multiplier = 1 << min(attempt - 1, 4);
    return applyJitter(
      Duration(seconds: min(90, baseSeconds * multiplier)),
      random ?? Random(),
    );
  }

  /// Longest server-requested cooldown this client will actually wait out.
  /// Beyond this the run fails loud with an actionable message instead of
  /// stalling (or burning the whole retry budget re-hitting the limit).
  static const Duration _maxServerCooldown = Duration(minutes: 10);

  /// Applies ±25% uniform jitter to [base]. Extracted so tests can pass a
  /// seeded [Random] and assert the range instead of an exact value.
  static Duration applyJitter(Duration base, Random random) {
    if (base <= Duration.zero) {
      return base;
    }
    final double factor = 0.75 + random.nextDouble() * 0.5;
    return Duration(milliseconds: (base.inMilliseconds * factor).round());
  }

  /// Adds 0–25% extra delay on top of [base], never shortening it. Used for
  /// server-directed Retry-After values, where the server's instruction
  /// must stay a hard minimum while batches limited together stop waking
  /// in lockstep. Extracted so tests can pass a seeded [Random] and assert
  /// the range instead of an exact value.
  static Duration addPositiveJitter(Duration base, Random random) {
    if (base <= Duration.zero) {
      return base;
    }
    final double factor = 1.0 + random.nextDouble() * 0.25;
    return Duration(milliseconds: (base.inMilliseconds * factor).round());
  }

  static Duration? retryAfterDelay(Object error) {
    if (error is! DioException) {
      return null;
    }
    final String? rawValue = error.response?.headers.value('retry-after');
    final String value = rawValue?.trim() ?? '';
    if (value.isEmpty) {
      return null;
    }
    final BigInt? seconds = BigInt.tryParse(value);
    if (seconds != null) {
      // A negative value is malformed (RFC 9110 delay-seconds is
      // non-negative); treat it like an unparseable value so the caller
      // falls back to exponential backoff instead of hammering the server
      // with a zero-delay retry.
      if (seconds.isNegative) return null;
      // Preserve ordinary server delays, but reject unrepresentable durations
      // before the VM's microsecond multiplication can wrap.
      final largestSeconds = BigInt.from(
        0x7fffffffffffffff ~/ Duration.microsecondsPerSecond,
      );
      return seconds > largestSeconds
          ? _maxServerCooldown + const Duration(seconds: 1)
          : Duration(seconds: seconds.toInt());
    }
    // RFC 9110 allows an HTTP-date as well as delay-seconds; Dart's
    // DateTime.tryParse only understands an ISO-8601 subset, so parse the
    // RFC 1123 form (e.g. "Wed, 21 Oct 2015 07:28:00 GMT") with
    // HttpDate.parse first. An unparseable value falls back to the caller's
    // exponential backoff — never to a zero delay that would hammer the
    // server's cooldown.
    DateTime? retryAt;
    try {
      retryAt = HttpDate.parse(value);
    } on HttpException {
      retryAt = DateTime.tryParse(value);
    }
    if (retryAt == null) {
      return null;
    }
    final Duration delay = retryAt.toUtc().difference(DateTime.now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  }

  /// Makes [suffix] safe as a Windows/macOS/Linux filename fragment.
  ///
  /// Strips path separators, reserved characters, control characters, and
  /// trailing dots/spaces (Windows would otherwise collapse names like
  /// `book....epub` back to `book.epub` and risk overwriting the source).
  static String sanitizeOutputSuffix(String suffix) {
    String sanitized = suffix
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Windows file names cannot end with dots or spaces.
    sanitized = sanitized.replaceAll(RegExp(r'[\. ]+$'), '');
    // Prevent empty / all-separator suffixes and pure-dot payloads.
    sanitized = sanitized.replaceAll(RegExp(r'^\.+'), '');
    if (sanitized.isEmpty) {
      return '_translated';
    }
    // Keep suffixes reasonably short so paths stay under OS limits.
    if (sanitized.length > 80) {
      sanitized = sanitized.substring(0, 80).replaceAll(RegExp(r'[\. ]+$'), '');
    }
    return sanitized.isEmpty ? '_translated' : sanitized;
  }
}
