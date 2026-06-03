import 'dart:convert';
import 'dart:io' show Directory, Platform, Process, ProcessResult;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

class NativePlatformBridge {
  const NativePlatformBridge._();

  static const MethodChannel _androidChannel = MethodChannel(
    'epub_translator_flutter/android_export',
  );

  static Future<String?> pickEpubFile() async {
    if (!kIsWeb && Platform.isAndroid) {
      return _androidChannel.invokeMethod<String>('pickEpubFile');
    }

    if (!kIsWeb && Platform.isWindows) {
      const String script = r'''
Add-Type -AssemblyName System.Windows.Forms
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = 'EPUB files (*.epub)|*.epub|All files (*.*)|*.*'
$dialog.Title = 'Choose EPUB'
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.WriteLine($dialog.FileName)
}
''';
      return _runWindowsDialog(script);
    }

    return null;
  }

  static Future<String?> appDocumentsDirectory() async {
    if (!kIsWeb && Platform.isAndroid) {
      return _androidChannel.invokeMethod<String>('appDocumentsDirectory');
    }

    final String? appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return path.join(appData, 'EPUB Translator');
    }

    final String? home = Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return path.join(home, 'EPUB Translator');
    }

    return Directory.current.path;
  }

  static Future<String?> pickDirectory() async {
    if (!kIsWeb && Platform.isWindows) {
      const String script = r'''
Add-Type -AssemblyName System.Windows.Forms
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = 'Choose output directory'
$dialog.ShowNewFolderButton = $true
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.WriteLine($dialog.SelectedPath)
}
''';
      return _runWindowsDialog(script);
    }

    return null;
  }

  static Future<String?> saveToDownloads({
    required String sourcePath,
    required String displayName,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      return _androidChannel.invokeMethod<String>('saveToDownloads', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mimeType': 'application/epub+zip',
      });
    }

    return null;
  }

  static Future<void> shareFile({
    required String sourcePath,
    required String displayName,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('shareFile', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mimeType': 'application/epub+zip',
      });
    }
  }

  static Future<String?> _runWindowsDialog(String script) async {
    final ProcessResult result = await Process.run(
      'powershell',
      <String>['-NoProfile', '-STA', '-Command', script],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    if (result.exitCode != 0) {
      final String stderr = _decodeWindowsDialogBytes(result.stderr).trim();
      throw StateError(
        stderr.isNotEmpty ? stderr : 'Windows file dialog failed.',
      );
    }

    return decodeWindowsDialogSelection(result.stdout);
  }

  @visibleForTesting
  static Future<String?> runWindowsDialogScriptForTest(String script) {
    return _runWindowsDialog(script);
  }

  @visibleForTesting
  static String? decodeWindowsDialogSelection(Object? stdout) {
    final String selected = _decodeWindowsDialogBytes(stdout).trim();
    return selected.isEmpty ? null : path.normalize(selected);
  }

  static String _decodeWindowsDialogBytes(Object? output) {
    if (output is List<int>) {
      return utf8.decode(output);
    }
    return output?.toString() ?? '';
  }
}
