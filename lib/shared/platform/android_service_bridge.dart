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
  /// [stopLabel] and [timeoutText] are shown on the notification's Stop
  /// action and on the final message if Android 15+ stops the service for
  /// exceeding its background time budget. [runId] is an opaque Dart-side
  /// run token; the native side tags stashed notification updates with it
  /// so a start only consumes updates from its own run.
  ///
  /// Returns false when the start was rejected because the app is in the
  /// background (Android 12+ throws
  /// ForegroundServiceStartNotAllowedException there): the caller should
  /// warn the user that the keep-alive is missing. The translation itself
  /// continues in Dart either way — a failed start must never take the run
  /// down with it.
  static Future<bool> startTranslationService({
    required String title,
    required String text,
    required String stopLabel,
    required String timeoutText,
    required String runId,
  }) async {
    if (!_isAndroid) {
      return true;
    }
    try {
      await _channel.invokeMethod<void>('startTranslationService', {
        'title': title,
        'text': text,
        'stopLabel': stopLabel,
        'timeoutText': timeoutText,
        'runId': runId,
      });
    } on PlatformException catch (error) {
      if (isBackgroundStartDenied(error)) {
        return false;
      }
      // Other start failures keep the historical behavior: translation
      // proceeds without the foreground service.
    } catch (_) {
      // Same: never let the keep-alive take the translation down.
    }
    return true;
  }

  /// Whether [error] is the distinct "background start denied" failure
  /// (see the native START_SERVICE_BACKGROUND_DENIED code). Pure so it can
  /// be unit tested off Android.
  @visibleForTesting
  static bool isBackgroundStartDenied(PlatformException error) {
    return error.code == 'START_SERVICE_BACKGROUND_DENIED';
  }

  /// Throttled progress refresh for the foreground-service notification.
  /// [progress] is 0-100. [runId] must match the run token passed to
  /// [startTranslationService].
  static Future<void> updateTranslationNotification({
    required int progress,
    required String text,
    required String runId,
  }) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateTranslationNotification', {
        'progress': progress.clamp(0, 100),
        'text': text,
        'runId': runId,
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

  /// Reads and clears the persisted foreground-service timeout notice.
  /// The native side sets it when Android 15+ stops the service for
  /// exceeding its background time budget *while notifications are
  /// disabled*: the final system notification would be silently dropped, so
  /// the next app start surfaces the timeout in-app instead. Returns true
  /// when such a notice was pending. Clearing on read keeps it from
  /// showing twice.
  static Future<bool> consumePendingForegroundServiceTimeout() async {
    if (!_isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'consumePendingForegroundServiceTimeout',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Registers (or clears) the handler for the notification Stop action.
  /// The native side invokes `cancelTranslationFromNotification` when the
  /// user taps Stop on the foreground-service notification; the handler
  /// should cancel the run through the normal cancel path. Safe to call
  /// when no run is active — the handler just won't be invoked then.
  static void setNotificationCancelHandler(Future<void> Function()? handler) {
    if (!_isAndroid) {
      return;
    }
    _cancelHandler = handler;
    _syncMethodCallHandler();
  }

  /// Registers (or clears) the handler invoked when Android 15+ stops the
  /// foreground service for exceeding its background time budget
  /// (~6h). The handler should wind the run down promptly — the process
  /// lost its foreground protection and may be killed at any moment, so
  /// continuing to burn API tokens is unsafe.
  static void setForegroundServiceTimeoutHandler(
    Future<void> Function()? handler,
  ) {
    if (!_isAndroid) {
      return;
    }
    _timeoutHandler = handler;
    _syncMethodCallHandler();
  }

  static Future<void> Function()? _cancelHandler;
  static Future<void> Function()? _timeoutHandler;

  /// Keeps a single dispatching method-call handler installed exactly while
  /// at least one native-to-Dart callback is registered. Both setters share
  /// it so registering one callback never clobbers the other.
  static void _syncMethodCallHandler() {
    if (_cancelHandler == null && _timeoutHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'cancelTranslationFromNotification':
          await _cancelHandler?.call();
        case 'foregroundServiceTimeout':
          await _timeoutHandler?.call();
      }
    });
  }
}
