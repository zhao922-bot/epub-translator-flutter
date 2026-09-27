import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lightweight Android-only [MethodChannel] wrapper for the translation
/// foreground service and the system app-settings deep link.
///
/// The native side (Track B) implements `startTranslationService`,
/// `updateTranslationNotification`, `stopTranslationService` and
/// `openAppSettings` on the same channel the export calls already use.
/// Every method is guarded by [Platform.isAndroid] and wrapped in try/catch
/// so a channel failure (or a not-yet-updated native side) never disturbs
/// the main flow.
class AndroidServiceBridge {
  const AndroidServiceBridge._();

  static const MethodChannel _channel = MethodChannel(
    'epub_translator_flutter/android_export',
  );

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Opens the system app-info/settings screen so the user can re-grant a
  /// permanently denied permission.
  static Future<void> openAppSettings() async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } catch (_) {
      // Best effort only: the settings screen is a convenience shortcut.
    }
  }

  /// Starts the foreground service that keeps translation alive under Doze.
  static Future<void> startTranslationService({
    required String title,
    required String text,
  }) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('startTranslationService', {
        'title': title,
        'text': text,
      });
    } catch (_) {
      // Translation proceeds without the foreground service.
    }
  }

  /// Throttled progress refresh for the foreground-service notification.
  /// [progress] is 0-100.
  static Future<void> updateTranslationNotification({
    required int progress,
    required String text,
  }) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateTranslationNotification', {
        'progress': progress.clamp(0, 100),
        'text': text,
      });
    } catch (_) {
      // Stale notification text is harmless.
    }
  }

  /// Stops the foreground service; safe to call when it was never started.
  static Future<void> stopTranslationService() async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopTranslationService');
    } catch (_) {
      // Nothing to clean up on the Dart side.
    }
  }
}
