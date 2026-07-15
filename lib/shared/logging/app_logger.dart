import 'package:logger/logger.dart';

/// App-wide structured logger (levels + simple context tags).
class AppLogger {
  AppLogger._();

  static final Logger _logger = Logger(
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
    _logger.e(_format(tag, message), error: error, stackTrace: stackTrace);
  }

  static String _format(String? tag, String message) {
    if (tag == null || tag.isEmpty) {
      return message;
    }
    return '[$tag] $message';
  }
}
