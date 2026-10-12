import 'package:logger/logger.dart';

/// App-wide structured logger (levels + simple context tags).
class AppLogger {
  AppLogger._();

  static final Logger _logger = Logger(
    // Unlike DevelopmentFilter, this does not depend on enabled assertions.
    filter: ProductionFilter(),
    printer: SimplePrinter(colors: false),
    // Keep noise low during unit tests and normal runs.
    level: Level.warning,
  );

  static void debug(String message, {String? tag}) {
    _logger.d(_format(tag, message));
  }

  static void info(String message, {String? tag}) {
    _logger.i(_format(tag, message));
  }

  static void warn(String message, {String? tag}) {
    _logger.w(_format(tag, message));
  }

  static void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _logger.e(
      _format(tag, message),
      error: safeError(error),
      stackTrace: stackTrace,
    );
  }

  /// Parser errors can carry the entire input, including old plaintext keys.
  static Object? safeError(Object? error) => error is FormatException
      ? 'FormatException (offset: ${error.offset ?? 'unknown'})'
      : error;

  static String _format(String? tag, String message) {
    if (tag == null || tag.isEmpty) {
      return message;
    }
    return '[$tag] $message';
  }
}
