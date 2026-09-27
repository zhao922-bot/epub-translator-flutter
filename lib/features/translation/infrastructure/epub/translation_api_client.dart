import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../../shared/localization/app_strings.dart';

import '../../domain/models/translation_config.dart';
import '../../domain/repositories/translation_repository.dart';

/// Thrown when a batch translation reply cannot be parsed as JSON at all
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

/// OpenAI-compatible chat client with retry / rate-limit handling.
class TranslationApiClient {
  const TranslationApiClient();

  Dio buildDio(TranslationConfig config) {
    final Dio dio = Dio(
      BaseOptions(
        baseUrl: normalizedBaseUrl(config.apiBaseUrl),
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

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final HttpClient client = HttpClient()
          ..connectionTimeout = Duration(seconds: config.timeoutSeconds)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = max(4, config.maxConcurrent * 2)
          ..userAgent = 'epub-translator-flutter/1.0';
        return client;
      },
    );

    return dio;
  }

  Future<String> testConnection({required TranslationConfig config}) async {
    if (config.apiBaseUrl.trim().isEmpty ||
        config.apiKey.trim().isEmpty ||
        config.model.trim().isEmpty) {
      throw const FormatException(
        'API base URL, API key, and model are required before testing the connection.',
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
      final Response<dynamic> response = await dio.post<dynamic>(
        '/chat/completions',
        data: requestData,
      );
      final String content = extractMessageContent(response.data);
      final String host = Uri.parse(normalizedBaseUrl(config.apiBaseUrl)).host;
      return AppStrings(
        config.uiLanguage,
      ).connectionDetail(host, content.isEmpty ? 'OK' : content);
    } on DioException catch (error) {
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
  }) {
    return dio.post<dynamic>(
      '/chat/completions',
      data: data,
      cancelToken: cancelToken,
    );
  }

  Future<T> runRetried<T>({
    required TranslationConfig config,
    required Future<T> Function() operation,
    bool Function(Object error)? shouldRetry,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    int? maxAttemptsOverride,
  }) async {
    for (int attempt = 1; ; attempt += 1) {
      try {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        return await operation();
      } catch (error, stackTrace) {
        if (error is TranslationCancelledException || isCancelError(error)) {
          throw const TranslationCancelledException();
        }
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

    try {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(delay),
        cancelToken.whenCancel.then((_) {
          throw const TranslationCancelledException();
        }),
      ]);
    } on TranslationCancelledException {
      rethrow;
    } catch (error) {
      if (isCancelError(error) || cancelToken.isCancelled) {
        throw const TranslationCancelledException();
      }
      rethrow;
    }

    if (cancelToken.isCancelled) {
      throw const TranslationCancelledException();
    }
  }

  String extractMessageContent(dynamic responseData) {
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
    final dynamic rawContent =
        responseData['choices']?[0]?['message']?['content'];
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
      _ => '',
    };
    return _stripReasoningBlocks(content);
  }

  /// Removes `<think>...</think>` reasoning blocks that reasoning models
  /// (for example DeepSeek-R1 variants) may prepend to the visible content.
  ///
  /// These blocks are model-internal reasoning, not translation output; they
  /// would otherwise break strict JSON parsing in batch mode and be mistaken
  /// for untranslated source text in single-block mode.
  String _stripReasoningBlocks(String content) {
    final String stripped = content.replaceAllMapped(
      RegExp(r'<think(?:\s[^>]*)?>[\s\S]*?</think>', caseSensitive: false),
      (Match match) => '',
    );
    return stripped.trim();
  }

  Map<String, dynamic> decodeJsonObject(String content) {
    final String normalized = content.trim();
    final Match? fenced = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
    ).firstMatch(normalized);
    final String candidate = fenced?.group(1)?.trim() ?? normalized;
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

  Map<String, dynamic> _decodeJsonObjectStrict(String candidate) {
    final Object? decoded = jsonDecode(candidate);
    _ensureNoDuplicateObjectKeys(candidate);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Model response is not a JSON object.');
    }
    return decoded;
  }

  /// Extracts the message content from a chat-completions response and
  /// decodes it as a JSON object for a batch request. Any failure to even
  /// parse the reply becomes a [TranslationParseException] so the batch
  /// retry policy can tell "the model did not return JSON" apart from
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
      if (!RegExp(r'\s').hasMatch(character)) {
        return character;
      }
    }
    return null;
  }

  String normalizedBaseUrl(String value) {
    String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    if (!trimmed.contains('://')) {
      trimmed = 'https://$trimmed';
    }
    trimmed = trimmed.replaceAll(RegExp(r'/+$'), '');

    final String lower = trimmed.toLowerCase();
    if (lower.endsWith('/chat/completions')) {
      trimmed = trimmed.substring(
        0,
        trimmed.length - '/chat/completions'.length,
      );
    }
    if (trimmed.toLowerCase().endsWith('/v1')) {
      return trimmed;
    }
    return '$trimmed/v1';
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
    return error is DioException &&
        error.type == DioExceptionType.sendTimeout;
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
    // A send or receive timeout on a large batch often means the endpoint is
    // too slow for the whole batch rather than that translation failed. Fall
    // back to smaller single-block requests, which are far less likely to
    // time out, instead of failing the entire translation run.
    return error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout;
  }

  /// HTTP status codes that are deterministic configuration errors: a wrong
  /// or inactive API key (401), a key without access to the model (403), or
  /// a wrong Base URL / model name (404). Re-sending the same request cannot
  /// fix them, so callers must fail fast instead of burning retry attempts.
  ///
  /// A 403 is only deterministic when it is genuinely a permission problem:
  /// some gateways report rate limiting as 403 instead of 429. When the
  /// response carries a `Retry-After` header or the body mentions rate
  /// limiting / quota exhaustion, the error counts as a rate limit
  /// ([isRateLimitError]) and takes the retry path instead of failing fast.
  static bool isDeterministicHttpError(Object error) {
    final int? statusCode = error is DioException
        ? error.response?.statusCode
        : null;
    if (statusCode == 401 || statusCode == 404) {
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
    final int? statusCode = error is DioException
        ? error.response?.statusCode
        : null;
    final AppStrings strings = AppStrings(config.uiLanguage);
    final String host = _diagnosticHost(config);
    switch (statusCode) {
      case 401:
        return strings.httpAuthError(host);
      case 403:
        return strings.httpForbiddenError(host, config.model);
      case 404:
        return strings.httpNotFoundError(host, config.model);
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
    // 401/403/404 are deterministic configuration errors (a 403 that looks
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
    if (error is TranslationParseException) {
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
        body.contains('quota') ||
        body.contains('too many requests');
  }

  static int maxAttemptsForError(TranslationConfig config, Object error) {
    final int normalMaxAttempts = max(1, config.maxRetries);
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
    int attempt,
  ) {
    if (isRateLimitError(error)) {
      final Duration? retryAfter = retryAfterDelay(error);
      if (retryAfter != null) {
        return clampRetryDelay(retryAfter);
      }
      final int baseSeconds = max(5, config.retryDelaySeconds);
      final int multiplier = 1 << min(attempt - 1, 4);
      return Duration(seconds: min(90, baseSeconds * multiplier));
    }
    return Duration(seconds: max(1, config.retryDelaySeconds));
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
    final int? seconds = int.tryParse(value);
    if (seconds != null) {
      return Duration(seconds: seconds);
    }
    final DateTime? retryAt = DateTime.tryParse(value);
    if (retryAt == null) {
      return null;
    }
    final Duration delay = retryAt.toUtc().difference(DateTime.now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  }

  static Duration clampRetryDelay(Duration delay) {
    if (delay < Duration.zero) {
      return Duration.zero;
    }
    if (delay > const Duration(seconds: 120)) {
      return const Duration(seconds: 120);
    }
    return delay;
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
