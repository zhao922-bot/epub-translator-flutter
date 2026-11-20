import 'package:flutter/services.dart';

import '../../../shared/localization/app_strings.dart';
import '../../../shared/logging/app_logger.dart';
import '../../../shared/platform/native_platform_bridge.dart';
import '../../../shared/security/sensitive_text.dart';

/// Localized error and path notices for dashboard operations.
abstract final class DashboardErrorMessages {
  static String redactErrorText(
    Object error, {
    required String? runApiKey,
    required String currentApiKey,
  }) {
    // Redact with the key that was in effect when the run started (an error
    // may surface the old key after the user changes it mid-run) as well as
    // the current key.
    String redacted = SensitiveText.redact(
      error.toString(),
      configuredApiKey: runApiKey,
    );
    if (runApiKey != currentApiKey) {
      redacted = SensitiveText.redact(
        redacted,
        configuredApiKey: currentApiKey,
      );
    }
    return redacted;
  }

  static String formatSaveErrorLogLine(
    Object error,
    AppStrings strings,
    String Function(Object error) safeErrorText,
  ) {
    if (error is PlatformException && error.code == 'SAVE_NO_SPACE') {
      return strings.logNotEnoughSpace;
    }
    if (error is PlatformException) {
      switch (error.code) {
        case 'SAVE_IN_PROGRESS':
          return strings.logSaveInProgress;
        case 'SAVE_FAILED':
          return strings.logSaveFailed;
        case 'SAVE_PERMISSION_DENIED':
          return strings.logSavePermissionDenied;
        case 'SAVE_PERMISSION_PERMANENTLY_DENIED':
          return strings.logSavePermissionPermanentlyDenied;
      }
    }
    final String safeError = safeErrorText(error);
    // The Dart-side timeout ends the wait while the native save continues.
    return safeError.contains('timed out')
        ? strings.saveTimeoutContinuesBackground
        : strings.logCouldNotSaveDownloads(safeError);
  }

  static String formatShareErrorLogLine(
    Object error,
    AppStrings strings,
    String Function(Object error) safeErrorText,
  ) {
    if (error is PlatformException && error.code == 'SHARE_NO_SPACE') {
      return strings.logNotEnoughSpace;
    }
    return strings.logCouldNotExport(safeErrorText(error));
  }

  static String formatOpenJobOutputErrorLogLine(
    Object error,
    AppStrings strings,
    String Function(Object error) safeErrorText,
  ) {
    if (error is PlatformException && error.code == 'SHARE_NO_SPACE') {
      return strings.logNotEnoughSpace;
    }
    return strings.logCouldNotOpenJobOutput(safeErrorText(error));
  }

  static String formatPickErrorLogLine(
    Object error,
    AppStrings strings,
    String Function(String error) genericLog,
    String Function(Object error) safeErrorText,
  ) {
    if (error is WindowsLongPathException) {
      AppLogger.warn(
        'Windows dialog path too long: ${error.detail}',
        tag: 'picker',
      );
      return strings.logWindowsDialogPathTooLong;
    }
    if (error is PlatformException && error.code == 'PICK_NO_SPACE') {
      return strings.logNotEnoughSpace;
    }
    if (error is PlatformException && error.code == 'PICK_TOO_LARGE') {
      return strings.logFileTooLarge;
    }
    if (error is PlatformException) {
      switch (error.code) {
        case 'PICK_TIMEOUT':
          return strings.logPickTimeout;
        case 'PICK_NO_PICKER':
          return strings.logNoPicker;
        case 'PICK_IN_PROGRESS':
          return strings.logPickInProgress;
        case 'PICK_REQUESTS_EXHAUSTED':
          return strings.logPickRequestsExhausted;
        case 'INVALID_FILE_TYPE':
          return strings.logInvalidFileType;
        case 'PICK_FAILED':
          return strings.logPickFailed;
      }
    }
    return genericLog(safeErrorText(error));
  }

  static String? formatWindowsPathNotice(
    WindowsPathNotice notice,
    String? selectedPath,
    AppStrings strings,
  ) {
    switch (notice) {
      case WindowsPathNotice.dialogOpened:
        return strings.logFileDialogOpened;
      case WindowsPathNotice.longPathWithoutPolicy:
        final String? targetPath = selectedPath;
        if (targetPath == null || targetPath.isEmpty) {
          return null;
        }
        return strings.logLongPathWithoutPolicy(targetPath);
      case WindowsPathNotice.oneDrivePlaceholder:
        return strings.logOneDrivePlaceholderHint;
    }
  }
}
