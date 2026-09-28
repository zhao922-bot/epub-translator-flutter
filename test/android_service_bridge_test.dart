import 'package:epub_translator_flutter/shared/platform/android_service_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
