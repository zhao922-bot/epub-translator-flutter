import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  for (final debugMode in [true, false]) {
    test(
      'AppLogger preserves warning/error with assertions $debugMode',
      () async {
        final dart = path.join(
          path.dirname(Platform.resolvedExecutable),
          '..',
          '..',
          '..',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        );
        final result = await Process.run(dart, [
          if (debugMode) '--enable-asserts',
          'test/fixtures/app_logger_process.dart',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final lines = const LineSplitter().convert('${result.stdout}');
        final data = jsonDecode(lines.last) as Map<String, dynamic>;
        expect(data['assertionsEnabled'], debugMode);
        final events = data['events'] as List<dynamic>;
        expect(events.map((dynamic event) => event['level']), [
          'warning',
          'error',
        ]);
        expect(
          events[0]['lines'].join('\n'),
          contains('[cache] cache warning'),
        );
        expect(
          events[1]['lines'].join('\n'),
          contains('[history] history failure'),
        );
        expect(events[1]['error'], contains('disk unavailable'));
        expect(events[1]['stackTrace'], 'persistence stack');
        // Verify the default console output as well as the filtered output events.
        expect(
          lines.take(lines.length - 1).join('\n'),
          contains('history failure'),
        );
      },
    );
  }
}
