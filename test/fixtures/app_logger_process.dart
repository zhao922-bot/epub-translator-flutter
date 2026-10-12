import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/shared/logging/app_logger.dart';
import 'package:logger/logger.dart';

void main() {
  bool assertionsEnabled = false;
  assert(assertionsEnabled = true);
  final events = <Map<String, dynamic>>[];
  Logger.addOutputListener((event) {
    events.add({
      'level': event.origin.level.name,
      'lines': event.lines,
      'error': event.origin.error?.toString(),
      'stackTrace': event.origin.stackTrace?.toString(),
    });
  });
  AppLogger.debug('debug hidden');
  AppLogger.info('info hidden');
  AppLogger.warn('cache warning', tag: 'cache');
  AppLogger.error(
    'history failure',
    tag: 'history',
    error: StateError('disk unavailable'),
    stackTrace: StackTrace.fromString('persistence stack'),
  );
  stdout.writeln(
    jsonEncode({'assertionsEnabled': assertionsEnabled, 'events': events}),
  );
}
