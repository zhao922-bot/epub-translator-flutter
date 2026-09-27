import 'dart:convert';
import 'dart:io' show Platform;

import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
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

  test(
    'runs Windows dialog scripts with UTF-8 stdout',
    () async {
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
    },
    skip: Platform.isWindows ? null : 'Windows-only PowerShell process test.',
  );

  test(
    'round trips Windows secrets through DPAPI storage',
    () async {
      final String name = 'codex_test_${DateTime.now().microsecondsSinceEpoch}';
      addTearDown(() => NativePlatformBridge.deleteSecret(name));

      await NativePlatformBridge.writeSecret(name, 'sk-secret-value');
      final String? restored = await NativePlatformBridge.readSecret(name);
      await NativePlatformBridge.deleteSecret(name);

      expect(restored, 'sk-secret-value');
      expect(await NativePlatformBridge.readSecret(name), isNull);
    },
    skip: Platform.isWindows ? null : 'Windows-only DPAPI storage test.',
  );

  test('parses LongPathsEnabled registry output', () {
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('1\r\n'), isTrue);
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('1'), isTrue);
    // Missing value prints nothing; missing counts as disabled.
    expect(NativePlatformBridge.parseLongPathsEnabledOutput(''), isFalse);
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('0'), isFalse);
    expect(NativePlatformBridge.parseLongPathsEnabledOutput('nope'), isFalse);
  });

  test('builds Linux secret-tool arguments', () {
    expect(
      NativePlatformBridge.linuxSecretLookupArgs(
        'epub-translator',
        'api_key',
      ),
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
    expect(
      NativePlatformBridge.macosSecretStoreArgs(),
      <String>['security', '-i'],
    );

    expect(
      NativePlatformBridge.macosSecretLookupArgs(
        'epub-translator',
        'api_key',
      ),
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

  test(
    'returns null for a missing Linux secret without throwing',
    () async {
      // Whether or not secret-tool is installed, looking up a never-stored
      // key must degrade to null so desktop startup is never interrupted.
      final String name =
          'codex_test_missing_${DateTime.now().microsecondsSinceEpoch}';
      expect(await NativePlatformBridge.readSecret(name), isNull);
    },
    skip: Platform.isLinux ? null : 'Linux-only secret-tool lookup test.',
  );
}
