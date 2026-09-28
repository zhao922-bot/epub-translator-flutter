import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:epub_translator_flutter/shared/platform/windows_elevation_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('timeout settles, kills process, and ignores late success', (
    tester,
  ) async {
    final process = _ProbeProcess();
    bool? cached;
    bool? result;
    final check = WindowsElevationCheck(
      start: () async => process,
      parseOutput: NativePlatformBridge.parseWindowsElevationResult,
      onSuccess: (value) => cached = value,
    );
    unawaited(check.result.then((value) => result = value));
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(result, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(result, isFalse);
    expect(process.killed, isTrue);
    expect(process.output.hasListener, isFalse);
    expect(process.errors.hasListener, isFalse);
    process.finish('True');
    await tester.pump();
    expect(result, isFalse);
    expect(cached, isNull);
  });

  for (final elevated in [false, true]) {
    testWidgets('completed $elevated probe caches result and removes timer', (
      tester,
    ) async {
      final process = _ProbeProcess();
      bool? cached;
      bool? result;
      final check = WindowsElevationCheck(
        start: () async => process,
        parseOutput: NativePlatformBridge.parseWindowsElevationResult,
        onSuccess: (value) => cached = value,
      );
      unawaited(check.result.then((value) => result = value));
      await tester.pump();
      process.finish(elevated ? 'True' : 'False');
      await tester.pump();
      expect(result, elevated);
      expect(cached, elevated);
      expect(process.killed, isFalse);
      // No 10s pump: Flutter also verifies that no pending timer survives.
    });
  }

  testWidgets('cancellation while starting kills a process arriving later', (
    tester,
  ) async {
    final startup = Completer<Process>();
    final process = _ProbeProcess();
    final check = WindowsElevationCheck(
      start: () => startup.future,
      parseOutput: NativePlatformBridge.parseWindowsElevationResult,
    );
    check.cancel();
    expect(await check.result, isFalse);
    startup.complete(process);
    await tester.pump();
    expect(process.killed, isTrue);
    process.finish('True');
    await tester.pump();
  });

  testWidgets('nonzero exit never caches a successful-looking stdout', (
    tester,
  ) async {
    final process = _ProbeProcess();
    bool? cached;
    bool? result;
    final check = WindowsElevationCheck(
      start: () async => process,
      parseOutput: NativePlatformBridge.parseWindowsElevationResult,
      onSuccess: (value) => cached = value,
    );
    unawaited(check.result.then((value) => result = value));
    await tester.pump();
    process.finish('True', code: 1);
    await tester.pump();
    expect(result, isFalse);
    expect(cached, isNull);
  });

  testWidgets('startup failure settles without leaving a timer', (
    tester,
  ) async {
    final check = WindowsElevationCheck(
      start: () async => throw const ProcessException('powershell', []),
      parseOutput: NativePlatformBridge.parseWindowsElevationResult,
    );
    bool? result;
    unawaited(check.result.then((value) => result = value));
    await tester.pump();
    expect(result, isFalse);
  });
}

class _ProbeProcess implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  bool killed = false;

  void finish(String text, {int code = 0}) {
    output.add(utf8.encode(text));
    unawaited(output.close());
    unawaited(errors.close());
    exited.complete(code);
  }

  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
