import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../domain/models/translation_config.dart';
import '../../domain/repositories/translation_repository.dart';

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
      return 'Connected to $host successfully. Model responded: ${content.isEmpty ? 'OK' : content}';
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
        final int maxAttempts = maxAttemptsForError(config, error);
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
    final dynamic rawContent =
        (responseData
            as Map<String, dynamic>)['choices']?[0]?['message']?['content'];
    return switch (rawContent) {
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
  }

  Map<String, dynamic> decodeJsonObject(String content) {
    final String normalized = content.trim();
    final Match? fenced = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
    ).firstMatch(normalized);
    final String candidate = fenced?.group(1)?.trim() ?? normalized;
    final Object? decoded = jsonDecode(candidate);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Model response is not a JSON object.');
    }
    return decoded;
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

  static bool shouldFallbackBatchDioException(DioException error) {
    return error.response?.statusCode == 413;
  }

  static bool shouldRetryBatchError(Object error) {
    if (error is TranslationCancelledException || isCancelError(error)) {
      return false;
    }
    return error is! DioException || !shouldFallbackBatchDioException(error);
  }

  static bool isRateLimitError(Object error) {
    return error is DioException && error.response?.statusCode == 429;
  }

  static int maxAttemptsForError(TranslationConfig config, Object error) {
    final int normalMaxAttempts = max(1, config.maxRetries);
    if (isRateLimitError(error)) {
      return max(normalMaxAttempts, 8);
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
