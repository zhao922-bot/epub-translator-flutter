import 'dart:convert';
import 'dart:io';

Future<void> repair(List<String> arguments) => _run('repair', arguments);
Future<void> rebuild(List<String> arguments) => _run('rebuild', arguments);

Future<void> _run(String operation, List<String> arguments) async {
  if (arguments.length != 2) {
    final script = operation == 'repair'
        ? 'repair_epub_xhtml'
        : 'rebuild_translated_epub';
    stderr.writeln(
      'Usage: dart run tool/$script.dart <input.epub> <output.epub>',
    );
    exitCode = 64;
    return;
  }
  final toolDirectory = File.fromUri(Platform.script).parent;
  final runner = File.fromUri(
    toolDirectory.uri.resolve('src/epub_maintenance_runner.dart'),
  );
  final sdkBin = File(Platform.resolvedExecutable).parent.parent.parent.parent;
  final candidate = File.fromUri(
    sdkBin.uri.resolve(Platform.isWindows ? 'flutter.bat' : 'flutter'),
  );
  final root = Platform.environment['FLUTTER_ROOT'];
  final flutter = candidate.existsSync()
      ? candidate.path
      : root != null
      ? File.fromUri(
          Directory(
            root,
          ).uri.resolve(Platform.isWindows ? 'bin/flutter.bat' : 'bin/flutter'),
        ).path
      : Platform.isWindows
      ? 'flutter.bat'
      : 'flutter';
  // User paths travel as JSON in the child environment, never as shell text.
  final request = jsonEncode({
    'operation': operation,
    'arguments': arguments.map((p) => File(p).absolute.path).toList(),
  });
  final process = await Process.start(
    flutter,
    ['test', '--no-pub', '--reporter', 'expanded', runner.path],
    workingDirectory: toolDirectory.parent.path,
    environment: {
      'FOLIOFERRY_MAINTENANCE_REQUEST': request,
      'LIVE_TRANSLATION_E2E': '0',
    },
    runInShell: Platform.isWindows,
  );
  await Future.wait([
    stdout.addStream(process.stdout),
    stderr.addStream(process.stderr),
  ]);
  exitCode = await process.exitCode;
}
