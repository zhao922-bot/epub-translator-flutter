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
}
