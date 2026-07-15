import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process, ProcessResult;

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

  static Future<String?> readSecret(String name) async {
    if (!kIsWeb && Platform.isAndroid) {
      return _androidChannel.invokeMethod<String>('readSecret', {'name': name});
    }

    if (!kIsWeb && Platform.isWindows) {
      final File file = await _windowsSecretFile(name);
      if (!await file.exists()) {
        return null;
      }
      final String encrypted = (await file.readAsString()).trim();
      if (encrypted.isEmpty) {
        return null;
      }
      final String decrypted = await _runWindowsSecretScript(r'''
Add-Type -AssemblyName System.Security
$raw = [Console]::In.ReadToEnd().Trim()
if ([string]::IsNullOrWhiteSpace($raw)) { return }
$protected = [Convert]::FromBase64String($raw)
$bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([System.Text.Encoding]::UTF8.GetString($bytes))
''', encrypted);
      return decrypted.isEmpty ? null : decrypted;
    }

    return null;
  }

  static Future<void> writeSecret(String name, String value) async {
    if (!kIsWeb && Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('writeSecret', {
        'name': name,
        'value': value,
      });
      return;
    }

    if (!kIsWeb && Platform.isWindows) {
      final File file = await _windowsSecretFile(name);
      await file.parent.create(recursive: true);
      final String encrypted = await _runWindowsSecretScript(r'''
Add-Type -AssemblyName System.Security
$plain = [Console]::In.ReadToEnd()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
$protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Convert]::ToBase64String($protected))
''', value);
      await file.writeAsString(encrypted, flush: true);
    }
  }

  static Future<void> deleteSecret(String name) async {
    if (!kIsWeb && Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('deleteSecret', {'name': name});
      return;
    }

    if (!kIsWeb && Platform.isWindows) {
      final File file = await _windowsSecretFile(name);
      if (await file.exists()) {
        await file.delete();
      }
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

  static Future<File> _windowsSecretFile(String name) async {
    final String appDirectory =
        await appDocumentsDirectory() ?? Directory.current.path;
    final String safeName = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return File(path.join(appDirectory, 'secrets', '$safeName.dpapi'));
  }

  static Future<String> _runWindowsSecretScript(
    String script,
    String input,
  ) async {
    final Process process = await Process.start('powershell', <String>[
      '-NoProfile',
      '-Command',
      script,
    ]);
    process.stdin.write(input);
    await process.stdin.close();

    final Future<String> stdout = utf8.decoder.bind(process.stdout).join();
    final Future<String> stderr = utf8.decoder.bind(process.stderr).join();
    final int exitCode = await process.exitCode;
    final String stdoutText = await stdout;
    final String stderrText = await stderr;
    if (exitCode != 0) {
      final String error = stderrText.trim();
      throw StateError(
        error.isNotEmpty ? error : 'Windows secret operation failed.',
      );
    }
    return stdoutText;
  }
}
