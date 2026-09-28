import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, ProcessException;

import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes Windows dialog output as UTF-8 for Unicode paths', () {
    const String selectedPath =
        r'C:\Users\Yang\Desktop\薬屋のひとりごと 15 (日向夏 ,しのとうこ) (z-library.sk, 1lib.sk, z-lib.sk).epub';

    final String? decoded = NativePlatformBridge.decodeWindowsDialogSelection(
      utf8.encode('$selectedPath\r\n'),
    );

    expect(decoded, selectedPath);
  });

  test('treats empty Windows dialog output as no selection', () {
    final String? decoded = NativePlatformBridge.decodeWindowsDialogSelection(
      utf8.encode('\r\n'),
    );

    expect(decoded, isNull);
  });

  test('runs Windows dialog scripts with UTF-8 stdout', () async {
    const String selectedPath =
        r'C:\Users\Yang\Desktop\薬屋のひとりごと 15 (日向夏 ,しのとうこ) (z-library.sk, 1lib.sk, z-lib.sk).epub';
    const String script = r'''
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
[Console]::Out.WriteLine('C:\Users\Yang\Desktop\薬屋のひとりごと 15 (日向夏 ,しのとうこ) (z-library.sk, 1lib.sk, z-lib.sk).epub')
''';

    final String? decoded =
        await NativePlatformBridge.runWindowsDialogScriptForTest(script);

    expect(decoded, selectedPath);
  }, skip: Platform.isWindows ? null : 'Windows-only PowerShell process test.');

  test('round trips Windows secrets through DPAPI storage', () async {
    final String name = 'codex_test_${DateTime.now().microsecondsSinceEpoch}';
    addTearDown(() => NativePlatformBridge.deleteSecret(name));

    await NativePlatformBridge.writeSecret(name, 'sk-secret-value');
    final String? restored = await NativePlatformBridge.readSecret(name);
    await NativePlatformBridge.deleteSecret(name);

    expect(restored, 'sk-secret-value');
    expect(await NativePlatformBridge.readSecret(name), isNull);
  }, skip: Platform.isWindows ? null : 'Windows-only DPAPI storage test.');

  test('parses LongPathsEnabled registry output', () {
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('1\r\n'), isTrue);
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('1'), isTrue);
    // Missing value prints nothing; missing counts as disabled.
    expect(NativePlatformBridge.parseLongPathsEnabledOutput(''), isFalse);
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('0'), isFalse);
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('nope'), isFalse);
  });

  test(
    'Android secret operations time out instead of hanging forever',
    () async {
      // The native secretExecutor is single-threaded: a wedged keystore
      // daemon would hang the settings page forever without this timeout.
      // Drive it through the public helper (bypasses Platform.isAndroid) with
      // a channel that never replies.
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel(
        'epub_translator_flutter/android_export',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (MethodCall call) => Completer<dynamic>().future,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        NativePlatformBridge.androidSecretTimeout = const Duration(minutes: 5);
      });
      NativePlatformBridge.androidSecretTimeout = const Duration(
        milliseconds: 50,
      );
      await expectLater(
        NativePlatformBridge.invokeAndroidSecret<String>(
          'readSecret',
          <String, Object?>{'name': 'x'},
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
  test('long-path policy resolution fails open on non-zero exit code', () {
    // A failed query (GPO execution policy, broken PowerShell, …) must
    // report "unknown" (null, fail open), not "disabled" — otherwise long
    // paths get a spurious longPathWithoutPolicy warning.
    expect(
      NativePlatformBridge.resolveLongPathsPolicy(exitCode: 1, stdout: ''),
      isNull,
    );
    expect(
      NativePlatformBridge.resolveLongPathsPolicy(exitCode: -1, stdout: '0'),
      isNull,
    );
    // Exit 0 with empty stdout = missing registry value = disabled.
    expect(
      NativePlatformBridge.resolveLongPathsPolicy(exitCode: 0, stdout: ''),
      isFalse,
    );
    expect(
      NativePlatformBridge.resolveLongPathsPolicy(exitCode: 0, stdout: '1\r\n'),
      isTrue,
    );
    expect(
      NativePlatformBridge.resolveLongPathsPolicy(exitCode: 0, stdout: '0'),
      isFalse,
    );
  });
  test(
    'decodes raw process stdout bytes before parsing the long-path policy',
    () {
      // Regression: _windowsLongPathsEnabled used to call
      // `result.stdout.toString()` on the raw List<int>, yielding "[49, 13, 10]"
      // which never parses as enabled. The wiring must decode the bytes.
      final List<int> rawStdout = <int>[49, 13, 10]; // "1\r\n"
      expect(rawStdout.toString(), isNot('1\r\n'));
      expect(
        NativePlatformBridge.parseLongPathsEnabledOutput(
          NativePlatformBridge.decodeWindowsDialogBytes(rawStdout),
        ),
        isTrue,
      );
    },
  );

  test('detects WinForms path-too-long dialog failures', () {
    expect(
      NativePlatformBridge.looksLikeLongPathFailure(
        'Exception calling "ShowDialog" with "0" argument(s): '
        '"System.IO.PathTooLongException: The specified path, file name, or '
        'both are too long."',
      ),
      isTrue,
    );
    expect(
      NativePlatformBridge.looksLikeLongPathFailure(
        'The fully qualified file name must be less than 260 characters',
      ),
      isTrue,
    );
    expect(
      NativePlatformBridge.looksLikeLongPathFailure(
        'Exception: System.UnauthorizedAccessException: Access to the path '
        'is denied.',
      ),
      isFalse,
    );
    expect(NativePlatformBridge.looksLikeLongPathFailure(''), isFalse);
  });

  test('long-path warning reserves headroom for app suffixes', () {
    // 260 - 48 headroom: a 213-char selection can overflow at commit time
    // once `.tmp.<digits>` / `.bak.<digits>` / `\name.epub` are appended.
    final String short = 'C:\\${'a' * 200}';
    final String risky = 'C:\\${'a' * 220}';
    final String over = 'C:\\${'a' * 270}';
    expect(NativePlatformBridge.isLongPathWarningCandidate(short), isFalse);
    expect(NativePlatformBridge.isLongPathWarningCandidate(risky), isTrue);
    expect(NativePlatformBridge.isLongPathWarningCandidate(over), isTrue);
  });

  test('builds Linux secret-tool arguments', () {
    expect(
      NativePlatformBridge.linuxSecretLookupArgs('epub-translator', 'api_key'),
      <String>[
        'secret-tool',
        'lookup',
        'service',
        'epub-translator',
        'name',
        'api_key',
      ],
    );
    expect(
      NativePlatformBridge.linuxSecretStoreArgs('epub-translator', 'api_key'),
      <String>[
        'secret-tool',
        'store',
        '--label',
        'EPUB Translator (api_key)',
        'service',
        'epub-translator',
        'name',
        'api_key',
      ],
    );
    expect(
      NativePlatformBridge.linuxSecretClearArgs('epub-translator', 'api_key'),
      <String>[
        'secret-tool',
        'clear',
        'service',
        'epub-translator',
        'name',
        'api_key',
      ],
    );
  });

  test('builds macOS security store args for interactive mode', () {
    // Writes go through `security -i`: the full command (with the
    // shell-quoted password) is fed via stdin, so the secret never appears in
    // argv (visible via `ps`) and never passes through readpassphrase(3),
    // which prefers /dev/tty over the pipe when a controlling terminal
    // exists.
    expect(NativePlatformBridge.macosSecretStoreArgs(), <String>[
      'security',
      '-i',
    ]);

    expect(
      NativePlatformBridge.macosSecretLookupArgs('epub-translator', 'api_key'),
      <String>[
        'security',
        'find-generic-password',
        '-a',
        'api_key',
        '-s',
        'epub-translator',
        '-w',
      ],
    );
    expect(
      NativePlatformBridge.macosSecretDeleteArgs('epub-translator', 'api_key'),
      <String>[
        'security',
        'delete-generic-password',
        '-a',
        'api_key',
        '-s',
        'epub-translator',
      ],
    );
  });

  test('returns null for a missing Linux secret without throwing', () async {
    // Whether or not secret-tool is installed, looking up a never-stored
    // key must degrade to null so desktop startup is never interrupted.
    final String name =
        'codex_test_missing_${DateTime.now().microsecondsSinceEpoch}';
    expect(await NativePlatformBridge.readSecret(name), isNull);
  }, skip: Platform.isLinux ? null : 'Linux-only secret-tool lookup test.');

  group('observeWindowsPath', () {
    test('OneDrive path fires the placeholder notice', () async {
      final List<WindowsPathNotice> notices = <WindowsPathNotice>[];
      await NativePlatformBridge.observeWindowsPath(
        r'C:\Users\me\OneDrive\Documents\book.epub',
        notices.add,
      );
      expect(notices, contains(WindowsPathNotice.oneDrivePlaceholder));
    });

    test('ordinary path fires no notices off Windows', () async {
      // On Linux the PowerShell registry read fails and is swallowed, so a
      // long path produces no notice instead of crashing the picker flow.
      final List<WindowsPathNotice> notices = <WindowsPathNotice>[];
      await NativePlatformBridge.observeWindowsPath(
        '/home/user/${'a' * 250}.epub',
        notices.add,
      );
      expect(notices, isEmpty);
    }, skip: Platform.isLinux ? null : 'Linux-only behavior test.');

    test('never throws for an empty path', () async {
      await NativePlatformBridge.observeWindowsPath('', (_) {});
    });
  });

  group('parseWindowsElevationResult', () {
    test('True means elevated', () {
      expect(
        NativePlatformBridge.parseWindowsElevationResult('True\r\n'),
        isTrue,
      );
    });

    test('False means not elevated', () {
      expect(
        NativePlatformBridge.parseWindowsElevationResult('False\r\n'),
        isFalse,
      );
    });

    test('unrecognized output fails closed', () {
      expect(NativePlatformBridge.parseWindowsElevationResult(''), isFalse);
      expect(
        NativePlatformBridge.parseWindowsElevationResult('garbage output'),
        isFalse,
      );
      // Extra whitespace around the token is tolerated; anything else
      // fails closed.
      expect(
        NativePlatformBridge.parseWindowsElevationResult('  TRUE  '),
        isTrue,
      );
    });
  });

  group('startWindowsSecretProcess', () {
    tearDown(() {
      NativePlatformBridge.debugWindowsProcessStarter = null;
    });

    test('maps ProcessException to a StateError', () async {
      String? seenExecutable;
      List<String>? seenArguments;
      NativePlatformBridge.debugWindowsProcessStarter =
          (String executable, List<String> arguments) async {
            seenExecutable = executable;
            seenArguments = arguments;
            throw const ProcessException('powershell', [
              '-NoProfile',
            ], 'not found');
          };
      await expectLater(
        NativePlatformBridge.startWindowsSecretProcess(const <String>[
          '-NoProfile',
        ]),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('PowerShell'),
          ),
        ),
      );
      expect(seenExecutable, 'powershell');
      expect(seenArguments, const <String>['-NoProfile']);
    });
  });

  group('protectedImportPathsFromJobs', () {
    test('drops blanks and de-duplicates, preserving order', () {
      expect(
        NativePlatformBridge.protectedImportPathsFromJobs(const <String>[
          '/a.epub',
          '',
          '/b.epub',
          '/a.epub',
          '/c.epub',
        ]),
        const <String>['/a.epub', '/b.epub', '/c.epub'],
      );
    });

    test('empty input stays empty', () {
      expect(
        NativePlatformBridge.protectedImportPathsFromJobs(const <String>[]),
        isEmpty,
      );
    });
  });
}
