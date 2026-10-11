import 'package:epub_translator_flutter/shared/platform/android_service_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('foreground service start result', () {
    test('successful request has no error', () async {
      final result = await AndroidServiceBridge.runStartRequest(() async {});
      expect(result.status, ForegroundServiceStartStatus.success);
      expect(result.started, isTrue);
      expect(result.error, isNull);
      expect(result.stackTrace, isNull);
    });

    final errors = <Object, ForegroundServiceStartStatus>{
      PlatformException(
        code: 'START_SERVICE_BACKGROUND_DENIED',
        message: 'App is in background',
        details: {'sdk': 35},
      ): ForegroundServiceStartStatus.backgroundDenied,
      PlatformException(
        code: 'START_SERVICE_FAILED',
        message: 'Missing foreground permission',
        details: {'permission': 'FOREGROUND_SERVICE'},
      ): ForegroundServiceStartStatus.failed,
      StateError('Unexpected native failure'):
          ForegroundServiceStartStatus.failed,
    };
    for (final entry in errors.entries) {
      test('classifies and preserves ${entry.key}', () async {
        final trace = StackTrace.current;
        final result = await AndroidServiceBridge.runStartRequest(
          () => Future<void>.error(entry.key, trace),
        );
        expect(result.status, entry.value);
        expect(result.started, isFalse);
        expect(result.error, same(entry.key));
        expect(result.stackTrace, same(trace));
      });
    }
  });

  group('isBackgroundStartDenied', () {
    test('recognizes the distinct background-denied error code', () {
      expect(
        AndroidServiceBridge.isBackgroundStartDenied(
          PlatformException(code: 'START_SERVICE_BACKGROUND_DENIED'),
        ),
        isTrue,
      );
    });

    test('does not match generic start failures', () {
      expect(
        AndroidServiceBridge.isBackgroundStartDenied(
          PlatformException(code: 'START_SERVICE_FAILED'),
        ),
        isFalse,
      );
      expect(
        AndroidServiceBridge.isBackgroundStartDenied(
          PlatformException(code: 'UNKNOWN'),
        ),
        isFalse,
      );
    });
  });
}
