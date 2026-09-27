import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessException, ProcessResult;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../io/atomic_file_writer.dart';
import '../logging/app_logger.dart';

/// Windows-only observations about file selection that the UI may want to
/// surface as log lines. The bridge cannot localize these itself (importing
/// AppStrings here would create an import cycle), so callers map each notice
/// to the matching AppStrings getter and append it to the user-visible logs.
enum WindowsPathNotice {
  /// A native file dialog was opened. It has no owner window and may open
  /// behind the app window.
  dialogOpened,

  /// The chosen path exceeds MAX_PATH (260 chars) while the system
  /// long-path policy (LongPathsEnabled) is off.
  longPathWithoutPolicy,

  /// The chosen path is under OneDrive; on-demand placeholder files may
  /// need to download before import can proceed.
  oneDrivePlaceholder,
}

class NativePlatformBridge {
  const NativePlatformBridge._();

  static const MethodChannel _androidChannel = MethodChannel(
    'epub_translator_flutter/android_export',
  );

  /// Service grouping for desktop secret helpers: `secret-tool` attributes
  /// on Linux and the keychain service on macOS. Keeps the three API-key
  /// slots namespaced under one service.
  static const String _desktopSecretService = 'epub-translator';

  static Future<String?> pickEpubFile({
    void Function(WindowsPathNotice notice)? onWindowsNotice,
  }) async {
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
      final String? selected = await _runWindowsDialog(
        script,
        onWindowsNotice: onWindowsNotice,
      );
      await _notifyWindowsPathObservations(selected, onWindowsNotice);
      return selected;
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

  static Future<String?> pickDirectory({
    void Function(WindowsPathNotice notice)? onWindowsNotice,
  }) async {
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
      final String? selected = await _runWindowsDialog(
        script,
        onWindowsNotice: onWindowsNotice,
      );
      await _notifyWindowsPathObservations(selected, onWindowsNotice);
      return selected;
    }

    return null;
  }

  static Future<String?> saveToDownloads({
    required String sourcePath,
    required String displayName,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        return await _androidChannel
            .invokeMethod<String>('saveToDownloads', {
              'sourcePath': sourcePath,
              'displayName': displayName,
              'mimeType': 'application/epub+zip',
            })
            .timeout(const Duration(minutes: 5));
      } on TimeoutException {
        // The native side may be stuck on a permission dialog after an
        // activity recreation; never hang the UI forever.
        throw StateError('Save to Downloads timed out.');
      }
    }

    return null;
  }

  static Future<void> shareFile({
    required String sourcePath,
    required String displayName,
    String? chooserTitle,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _androidChannel
            .invokeMethod<void>('shareFile', {
              'sourcePath': sourcePath,
              'displayName': displayName,
              'mimeType': 'application/epub+zip',
              'chooserTitle': chooserTitle,
            })
            .timeout(const Duration(minutes: 5));
      } on TimeoutException {
        throw StateError('Share timed out.');
      }
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
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
Add-Type -AssemblyName System.Security
# NB: [System.Text.Encoding]::UTF8 emits a BOM on .NET Framework
# (Windows PowerShell 5.1); the $false constructor above avoids it.
# Read raw stdin bytes and decode as UTF-8 explicitly: [Console]::In decodes
# with the OEM code page (e.g. GBK on Chinese Windows) and would mangle any
# non-ASCII secret.
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
$raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
if ([string]::IsNullOrWhiteSpace($raw)) { return }
$protected = [Convert]::FromBase64String($raw)
$bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([System.Text.Encoding]::UTF8.GetString($bytes))
''', encrypted);
      // Belt and braces: never let a stray BOM/whitespace prefix reach the
      // API key (a \uFEFF prefix would cause 401s on every request).
      final String clean = decrypted.trim();
      return clean.isEmpty ? null : clean;
    }

    if (!kIsWeb && Platform.isLinux) {
      return _readLinuxSecret(name);
    }

    if (!kIsWeb && Platform.isMacOS) {
      return _readMacosSecret(name);
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
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
Add-Type -AssemblyName System.Security
# NB: [System.Text.Encoding]::UTF8 emits a BOM on .NET Framework
# (Windows PowerShell 5.1); the $false constructor above avoids it.
# See readSecret: decode stdin as UTF-8 explicitly, independent of the OEM
# code page, so non-ASCII secrets round-trip intact.
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
$plain = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
$protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Convert]::ToBase64String($protected))
''', value);
      // Atomic write: a kill mid-save must not leave a truncated DPAPI file
      // behind (that would force the user to re-enter the key).
      await writeFileAtomically(file, encrypted);
    }

    if (!kIsWeb && Platform.isLinux) {
      await _writeLinuxSecret(name, value);
      return;
    }

    if (!kIsWeb && Platform.isMacOS) {
      await _writeMacosSecret(name, value);
      return;
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
      return;
    }

    if (!kIsWeb && Platform.isLinux) {
      await _deleteLinuxSecret(name);
      return;
    }

    if (!kIsWeb && Platform.isMacOS) {
      await _deleteMacosSecret(name);
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Linux secrets via `secret-tool` (libsecret / Secret Service).
  // ---------------------------------------------------------------------------

  /// Builds the argv for `secret-tool store`. The password is passed on
  /// stdin (never argv), which `secret-tool` reads in full.
  @visibleForTesting
  static List<String> linuxSecretStoreArgs(String service, String name) {
    return <String>[
      'secret-tool',
      'store',
      '--label',
      'EPUB Translator ($name)',
      'service',
      service,
      'name',
      name,
    ];
  }

  /// Builds the argv for `secret-tool lookup`. Prints the secret (if any) to
  /// stdout; a missing item yields empty output.
  @visibleForTesting
  static List<String> linuxSecretLookupArgs(String service, String name) {
    return <String>[
      'secret-tool',
      'lookup',
      'service',
      service,
      'name',
      name,
    ];
  }

  /// Builds the argv for `secret-tool clear`.
  @visibleForTesting
  static List<String> linuxSecretClearArgs(String service, String name) {
    return <String>[
      'secret-tool',
      'clear',
      'service',
      service,
      'name',
      name,
    ];
  }

  static Future<String?> _readLinuxSecret(String name) async {
    // A missing or broken secret-tool degrades to "no saved key": desktop
    // startup must never be interrupted by the secret backend.
    try {
      final String output = await _runDesktopSecretHelper(
        'secret-tool',
        linuxSecretLookupArgs(_desktopSecretService, name),
      );
      final String clean = output.trim();
      return clean.isEmpty ? null : clean;
    } catch (error) {
      AppLogger.debug(
        'Linux secret lookup failed for "$name": $error',
        tag: 'secrets',
      );
      return null;
    }
  }

  static Future<void> _writeLinuxSecret(String name, String value) async {
    await _runDesktopSecretHelper(
      'secret-tool',
      linuxSecretStoreArgs(_desktopSecretService, name),
      stdinInput: value,
    );
  }

  static Future<void> _deleteLinuxSecret(String name) async {
    // Best effort: deleting a key that was never stored is not an error.
    try {
      await _runDesktopSecretHelper(
        'secret-tool',
        linuxSecretClearArgs(_desktopSecretService, name),
      );
    } catch (_) {
      // Ignore: nothing to delete, or no secret-tool installed.
    }
  }

  // ---------------------------------------------------------------------------
  // macOS secrets via the `security` CLI (login keychain).
  // ---------------------------------------------------------------------------

  /// Builds the argv for `security -i` (interactive mode). Writes go through
  /// the interactive shell instead of the bare `-w` flag: the full command,
  /// with the shell-quoted password (see [macosSecretStoreCommand]), is fed
  /// via stdin, so the secret never appears in argv (visible via `ps`) and
  /// never passes through readpassphrase(3), which prefers /dev/tty over the
  /// pipe when a controlling terminal exists.
  @visibleForTesting
  static List<String> macosSecretStoreArgs() {
    return <String>['security', '-i'];
  }

  /// Wraps [value] in POSIX single quotes, escaping embedded single quotes as
  /// `'\''`. `security -i` executes its stdin as shell commands, so every
  /// value on the command line must be quoted this way: double quotes would
  /// still let `$`, backticks and `\` be interpreted.
  @visibleForTesting
  static String posixShellQuote(String value) {
    return "'${value.replaceAll("'", r"'\''")}'";
  }

  /// Builds the complete `add-generic-password` command line fed to
  /// `security -i`'s stdin. `-U` updates an existing item instead of failing
  /// with "already exists". All values are POSIX-shell-quoted because
  /// `security -i` parses stdin as shell commands.
  @visibleForTesting
  static String macosSecretStoreCommand(
    String service,
    String account,
    String password,
  ) {
    return 'add-generic-password'
        ' -a ${posixShellQuote(account)}'
        ' -s ${posixShellQuote(service)}'
        ' -U'
        ' -w ${posixShellQuote(password)}';
  }

  /// Rejects multiline values loudly: the keychain cannot store them, and a
  /// silent truncation would corrupt the saved key. (API keys are single-line
  /// tokens; this guard is just belt & braces.)
  @visibleForTesting
  static void rejectMultilineMacosSecret(String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw StateError(
        'Cannot store a multiline secret in the macOS keychain.',
      );
    }
  }

  /// Builds the argv for `security find-generic-password -w`, which prints
  /// just the password to stdout.
  @visibleForTesting
  static List<String> macosSecretLookupArgs(String service, String account) {
    return <String>[
      'security',
      'find-generic-password',
      '-a',
      account,
      '-s',
      service,
      '-w',
    ];
  }

  /// Builds the argv for `security delete-generic-password`.
  @visibleForTesting
  static List<String> macosSecretDeleteArgs(String service, String account) {
    return <String>[
      'security',
      'delete-generic-password',
      '-a',
      account,
      '-s',
      service,
    ];
  }

  static Future<String?> _readMacosSecret(String name) async {
    // Same degradation policy as Linux: never interrupt startup.
    try {
      final String output = await _runDesktopSecretHelper(
        'security',
        macosSecretLookupArgs(_desktopSecretService, name),
      );
      final String clean = output.trim();
      return clean.isEmpty ? null : clean;
    } catch (error) {
      AppLogger.debug(
        'macOS secret lookup failed for "$name": $error',
        tag: 'secrets',
      );
      return null;
    }
  }

  static Future<void> _writeMacosSecret(String name, String value) async {
    rejectMultilineMacosSecret(value);
    // The old bare `-w` flag made `security` read the password via
    // readpassphrase(3), which prefers /dev/tty over the pipe when a
    // controlling terminal exists: the terminal would show password:/retype:
    // prompts, and on stdin EOF two empty reads "agree" with each other,
    // silently storing an empty password. Drive `security -i` instead — the
    // complete, shell-quoted command goes through stdin, bypassing the
    // getpass/readpassphrase path entirely.
    final String command = macosSecretStoreCommand(
      _desktopSecretService,
      name,
      value,
    );
    await _runDesktopSecretHelper(
      'security',
      macosSecretStoreArgs(),
      stdinInput: '$command\n',
    );
  }

  static Future<void> _deleteMacosSecret(String name) async {
    // Best effort: deleting a key that was never stored is not an error.
    try {
      await _runDesktopSecretHelper(
        'security',
        macosSecretDeleteArgs(_desktopSecretService, name),
      );
    } catch (_) {
      // Ignore: nothing to delete, or `security` unavailable.
    }
  }

  /// Runs a desktop secret helper (`secret-tool` / `security`) and returns
  /// its stdout. Throws [StateError] when the helper is missing, exits
  /// non-zero, or times out (30s, mirroring the Windows secret path); a hung
  /// helper is killed so it can never wedge the app.
  ///
  /// [args] follows the argv[0] convention: its first element is the
  /// executable name itself, exactly as the `*SecretArgs` builders return it.
  /// `Process.start`'s `arguments` already map to the child's argv[1..], so
  /// the duplicate is stripped here.
  static Future<String> _runDesktopSecretHelper(
    String executable,
    List<String> args, {
    String? stdinInput,
  }) async {
    assert(
      args.isNotEmpty && args.first == executable,
      'Desktop secret helper args must start with the executable name.',
    );
    late final Process process;
    try {
      // No shell: args are passed verbatim, so secret names cannot inject.
      // NB: pass args.sublist(1), NOT args — builders include the program
      // name as args[0], and passing it again would run e.g.
      // `secret-tool secret-tool store …` (unknown subcommand, exit 2).
      process = await Process.start(executable, args.sublist(1));
    } on ProcessException catch (error) {
      throw StateError(
        'Secret helper "$executable" is not available (${error.message}).',
      );
    }
    final String? input = stdinInput;
    if (input != null) {
      process.stdin.write(input);
    }
    await process.stdin.close();
    try {
      return await _collectHelperOutput(
        process,
        executable,
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      process.kill();
      throw StateError('Secret helper "$executable" timed out.');
    }
  }

  static Future<String> _collectHelperOutput(
    Process process,
    String executable,
  ) async {
    final Future<List<int>> stdoutBytes = process.stdout.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final Future<List<int>> stderrBytes = process.stderr.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final int exitCode = await process.exitCode;
    // Same policy as the Windows paths: never let one malformed byte mask the
    // real error behind a FormatException.
    final String stderrText = utf8.decode(
      await stderrBytes,
      allowMalformed: true,
    );
    if (exitCode != 0) {
      final String detail = stderrText.trim();
      throw StateError(
        'Secret helper "$executable" failed'
        '${detail.isNotEmpty ? ': $detail' : '.'}',
      );
    }
    return utf8.decode(await stdoutBytes, allowMalformed: true);
  }

  static Future<String?> _runWindowsDialog(
    String script, {
    void Function(WindowsPathNotice notice)? onWindowsNotice,
  }) async {
    // The dialog has no owner window and may open behind the app window;
    // let the UI warn the user to check the taskbar before showing it.
    onWindowsNotice?.call(WindowsPathNotice.dialogOpened);
    // Process.start (not Process.run) so we keep a handle: if the caller
    // gives up (its own 5-minute timeout), the modal dialog may still be
    // open, so kill PowerShell instead of leaving it lingering.
    final Process process = await Process.start('powershell', <String>[
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ]);
    try {
      final ProcessResult result = await _collectProcessResult(
        process,
      ).timeout(const Duration(minutes: 5));
      if (result.exitCode != 0) {
        final String stderr = _decodeWindowsDialogBytes(result.stderr).trim();
        throw StateError(
          stderr.isNotEmpty ? stderr : 'Windows file dialog failed.',
        );
      }

      return decodeWindowsDialogSelection(result.stdout);
    } on TimeoutException {
      process.kill();
      return null;
    }
  }

  /// Collects a [ProcessResult] from an already-started process, keeping
  /// stdout/stderr as raw bytes (same shape as `Process.run` with null
  /// encodings produced).
  static Future<ProcessResult> _collectProcessResult(Process process) async {
    final Future<List<int>> stdoutFuture = process.stdout.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final Future<List<int>> stderrFuture = process.stderr.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final int exitCode = await process.exitCode;
    return ProcessResult(
      process.pid,
      exitCode,
      await stdoutFuture,
      await stderrFuture,
    );
  }

  @visibleForTesting
  static Future<String?> runWindowsDialogScriptForTest(String script) {
    return _runWindowsDialog(script);
  }

  /// Fires [WindowsPathNotice]s for a path chosen on Windows. Best-effort:
  /// never throws, and skips the (slow) registry read unless the path
  /// actually exceeds MAX_PATH.
  static Future<void> _notifyWindowsPathObservations(
    String? selectedPath,
    void Function(WindowsPathNotice notice)? onWindowsNotice,
  ) async {
    if (onWindowsNotice == null ||
        selectedPath == null ||
        selectedPath.isEmpty) {
      return;
    }
    try {
      if (selectedPath.length > 260) {
        final bool? enabled = await _windowsLongPathsEnabled();
        // null = registry read failed: stay silent rather than nagging.
        if (enabled == false) {
          onWindowsNotice(WindowsPathNotice.longPathWithoutPolicy);
        }
      }
      if (selectedPath.toLowerCase().contains('onedrive')) {
        onWindowsNotice(WindowsPathNotice.oneDrivePlaceholder);
      }
    } catch (_) {
      // Observations must never break path selection.
    }
  }

  /// Best-effort read of the Windows long-path policy
  /// (HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled).
  /// Returns null when the query fails; a missing value counts as disabled.
  /// Cached per process: spawning PowerShell is slow.
  static bool? _windowsLongPathsEnabledCache;

  static Future<bool?> _windowsLongPathsEnabled() async {
    if (_windowsLongPathsEnabledCache != null) {
      return _windowsLongPathsEnabledCache;
    }
    try {
      final ProcessResult result =
          await Process.run('powershell', <String>[
            '-NoProfile',
            '-Command',
            r"(Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled",
          ]).timeout(const Duration(seconds: 30));
      _windowsLongPathsEnabledCache = parseLongPathsEnabledOutput(
        result.stdout.toString(),
      );
    } catch (_) {
      _windowsLongPathsEnabledCache = null;
    }
    return _windowsLongPathsEnabledCache;
  }

  /// Parses the LongPathsEnabled registry value as printed by PowerShell:
  /// '1' means enabled; anything else (including empty = missing value)
  /// means disabled.
  @visibleForTesting
  static bool parseLongPathsEnabledOutput(String output) {
    return output.trim() == '1';
  }

  /// Test hook for the desktop secret helpers: runs [executable] with
  /// builder-style [args] (first element is the executable name) exactly as
  /// the Linux/macOS secret paths do, without needing the real `secret-tool`
  /// or `security` installed.
  @visibleForTesting
  static Future<String> runDesktopSecretHelperForTest(
    String executable,
    List<String> args, {
    String? stdinInput,
  }) {
    return _runDesktopSecretHelper(
      executable,
      args,
      stdinInput: stdinInput,
    );
  }

  @visibleForTesting
  static String? decodeWindowsDialogSelection(Object? stdout) {
    final String selected = _decodeWindowsDialogBytes(stdout).trim();
    return selected.isEmpty ? null : path.normalize(selected);
  }

  static String _decodeWindowsDialogBytes(Object? output) {
    if (output is List<int>) {
      // Never let one malformed byte turn into a FormatException that masks
      // the real dialog error.
      return utf8.decode(output, allowMalformed: true);
    }
    return output?.toString() ?? '';
  }

  static bool _cleanedSecretTempFiles = false;

  static Future<File> _windowsSecretFile(String name) async {
    final String appDirectory =
        await appDocumentsDirectory() ?? Directory.current.path;
    final Directory secretsDir = Directory(path.join(appDirectory, 'secrets'));
    if (!_cleanedSecretTempFiles) {
      _cleanedSecretTempFiles = true;
      // Lazily GC `.tmp.*` files left behind by interrupted atomic writes,
      // once per process (not on every secret operation).
      unawaited(cleanStaleAtomicTempFiles(secretsDir));
    }
    final String safeName = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return File(path.join(secretsDir.path, '$safeName.dpapi'));
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
    try {
      return await _communicateWithSecretProcess(
        process,
        input,
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // Never leave a hung PowerShell behind; _readSecret already degrades a
      // failure to "no saved key", so timing out is safe.
      process.kill();
      throw StateError('Windows secret operation timed out.');
    }
  }

  static Future<String> _communicateWithSecretProcess(
    Process process,
    String input,
  ) async {
    // Dart's process stdin is UTF-8; the script reads raw stdin bytes and
    // decodes them as UTF-8 explicitly (see script header comment).
    process.stdin.write(input);
    await process.stdin.close();

    final Future<List<int>> stdoutBytes = process.stdout.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final Future<List<int>> stderrBytes = process.stderr.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    final int exitCode = await process.exitCode;
    // Never let one malformed byte turn into a FormatException that masks
    // the real script error (same policy as the dialog path).
    final String stdoutText = utf8.decode(
      await stdoutBytes,
      allowMalformed: true,
    );
    final String stderrText = utf8.decode(
      await stderrBytes,
      allowMalformed: true,
    );
    if (exitCode != 0) {
      final String error = stderrText.trim();
      throw StateError(
        error.isNotEmpty ? error : 'Windows secret operation failed.',
      );
    }
    return stdoutText;
  }
}
