import 'dart:io';

import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the desktop secret helpers (`secret-tool` on Linux,
/// `security` on macOS) that do not need the real helpers installed: a fake
/// executable records exactly what argv and stdin it received.
void main() {
  group('desktop secret helper argv', () {
    test(
      'does not pass the executable name twice to the child process',
      () async {
        final File script = await _writeArgEchoScript('fake-secret-helper');
        addTearDown(() => script.parent.delete(recursive: true));

        // Builder-style args: the first element is the program name itself
        // (argv[0] convention), mirroring linuxSecretStoreArgs et al.
        final List<String> builderArgs = <String>[
          script.path,
          'store',
          '--label',
          'EPUB Translator (api_key)',
          'service',
          'epub-translator',
          'name',
          'api_key',
        ];

        final String output =
            await NativePlatformBridge.runDesktopSecretHelperForTest(
              script.path,
              builderArgs,
              stdinInput: 's3cr3t-value',
            );

        // The child must receive exactly argv[1..]: no duplicated program
        // name (the old bug ran `secret-tool secret-tool store …`).
        expect(_echoedArgs(output), builderArgs.sublist(1));
        expect(_echoedStdin(output), 's3cr3t-value');
      },
      skip: Platform.isWindows ? 'Needs a POSIX shell.' : null,
    );

    test('reports a non-zero helper exit as StateError', () async {
      final File script = await _writeFailingScript('fake-secret-helper');
      addTearDown(() => script.parent.delete(recursive: true));

      await expectLater(
        NativePlatformBridge.runDesktopSecretHelperForTest(
          script.path,
          <String>[script.path, 'lookup'],
        ),
        throwsA(isA<StateError>()),
      );
    }, skip: Platform.isWindows ? 'Needs a POSIX shell.' : null);

    test('throws StateError when the helper executable is missing', () async {
      await expectLater(
        NativePlatformBridge.runDesktopSecretHelperForTest(
          '/nonexistent/definitely-not-a-secret-helper',
          <String>['/nonexistent/definitely-not-a-secret-helper', 'lookup'],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('macos security -i command', () {
    test('store args target interactive mode', () {
      expect(NativePlatformBridge.macosSecretStoreArgs(), <String>[
        'security',
        '-i',
      ]);
    });

    test('builds the interactive command for a plain password', () {
      expect(
        NativePlatformBridge.macosSecretStoreCommand(
          'epub-translator',
          'api_key',
          'plain-value-123',
        ),
        "add-generic-password -a 'api_key' -s 'epub-translator' "
        "-U -w 'plain-value-123'",
      );
    });

    test('shell-quotes values containing spaces and shell metacharacters', () {
      expect(
        NativePlatformBridge.macosSecretStoreCommand(
          'epub-translator',
          'my key',
          "p'a ss\$x`y`\\z\"q",
        ),
        "add-generic-password -a 'my key' -s 'epub-translator' "
        "-U -w 'p'\\''a ss\$x`y`\\z\"q'",
      );
    });

    test('posixShellQuote wraps in single quotes and escapes quotes', () {
      expect(NativePlatformBridge.posixShellQuote('simple'), "'simple'");
      expect(NativePlatformBridge.posixShellQuote("it's"), r"'it'\''s'");
      expect(NativePlatformBridge.posixShellQuote(''), "''");
      // Everything else passes through untouched inside single quotes.
      expect(
        NativePlatformBridge.posixShellQuote('a b\$c`d`\\e"f'),
        "'a b\$c`d`\\e\"f'",
      );
    });

    test('rejects multiline secrets loudly', () {
      expect(
        () => NativePlatformBridge.rejectMultilineMacosSecret('a\nb'),
        throwsStateError,
      );
      expect(
        () => NativePlatformBridge.rejectMultilineMacosSecret('a\rb'),
        throwsStateError,
      );
      expect(
        () => NativePlatformBridge.rejectMultilineMacosSecret('ok-value'),
        returnsNormally,
      );
    });
  });
}

/// Writes an executable shell script that echoes each received argument as
/// `ARG <index> <value>` lines, then a `STDIN` marker line, then its stdin.
Future<File> _writeArgEchoScript(String name) async {
  final Directory dir = await Directory.systemTemp.createTemp(
    'desktop_secret_helper_test',
  );
  final File script = File('${dir.path}/$name');
  await script.writeAsString('''
#!/bin/sh
i=0
for a in "\$@"; do
  printf 'ARG %d %s\\n' "\$i" "\$a"
  i=\$((i + 1))
done
printf 'STDIN\\n'
cat
''');
  final ProcessResult chmod = await Process.run('chmod', <String>[
    '+x',
    script.path,
  ]);
  assert(chmod.exitCode == 0, 'chmod +x failed for ${script.path}');
  return script;
}

/// Writes an executable shell script that always exits non-zero.
Future<File> _writeFailingScript(String name) async {
  final Directory dir = await Directory.systemTemp.createTemp(
    'desktop_secret_helper_test',
  );
  final File script = File('${dir.path}/$name');
  await script.writeAsString('#!/bin/sh\necho boom >&2\nexit 3\n');
  final ProcessResult chmod = await Process.run('chmod', <String>[
    '+x',
    script.path,
  ]);
  assert(chmod.exitCode == 0, 'chmod +x failed for ${script.path}');
  return script;
}

/// Parses the `ARG <index> <value>` lines the echo script printed.
List<String> _echoedArgs(String output) {
  final List<String> args = <String>[];
  for (final String line in output.split('\n')) {
    if (!line.startsWith('ARG ')) {
      break;
    }
    final int valueStart = line.indexOf(' ', 4) + 1;
    args.add(line.substring(valueStart));
  }
  return args;
}

/// Returns everything the echo script printed after its `STDIN` marker.
String _echoedStdin(String output) {
  const String marker = 'STDIN\n';
  final int at = output.indexOf(marker);
  assert(at >= 0, 'echo script did not print the STDIN marker');
  return output.substring(at + marker.length);
}
