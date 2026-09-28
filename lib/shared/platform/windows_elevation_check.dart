import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An elevation probe owned by its caller. Timeout and cancellation settle the
/// result, release stream listeners, and terminate a stalled PowerShell process.
class WindowsElevationCheck {
  WindowsElevationCheck({
    required Future<Process> Function() start,
    required this.parseOutput,
    this.onSuccess,
    Duration timeout = const Duration(seconds: 10),
  }) {
    _timer = Timer(timeout, cancel);
    unawaited(_start(start));
  }

  WindowsElevationCheck.completed(bool value)
    : parseOutput = null,
      onSuccess = null {
    _result.complete(value);
  }

  final Completer<bool> _result = Completer<bool>();
  final bool Function(String)? parseOutput;
  final void Function(bool)? onSuccess;
  final StringBuffer _output = StringBuffer();
  Timer? _timer;
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  bool _stdoutDone = false;
  bool _stderrDone = false;
  int? _exitCode;

  Future<bool> get result => _result.future;

  void cancel() => _finish(false);

  Future<void> _start(Future<Process> Function() start) async {
    try {
      final Process process = await start();
      _process = process;
      if (_result.isCompleted) {
        _killProcess();
        return;
      }
      // Drain both pipes concurrently; a full stderr pipe must not prevent
      // stdout/exit from completing.
      _stdout = process.stdout
          .transform(utf8.decoder)
          .listen(
            _output.write,
            onDone: () {
              _stdoutDone = true;
              _completeIfReady();
            },
            onError: (Object error) => cancel(),
          );
      _stderr = process.stderr.listen(
        (_) {},
        onDone: () {
          _stderrDone = true;
          _completeIfReady();
        },
        onError: (Object error) => cancel(),
      );
      final int code = await process.exitCode;
      _exitCode = code;
      if (code != 0) {
        cancel();
      } else {
        _completeIfReady();
      }
    } catch (_) {
      cancel();
    }
  }

  void _completeIfReady() {
    if (_result.isCompleted || !_stdoutDone || !_stderrDone || _exitCode != 0) {
      return;
    }
    try {
      final bool elevated = parseOutput!(_output.toString());
      _finish(elevated, successful: true);
    } catch (_) {
      cancel();
    }
  }

  void _finish(bool value, {bool successful = false}) {
    if (_result.isCompleted) return;
    _timer?.cancel();
    _timer = null;
    _result.complete(value);
    unawaited(_stdout?.cancel());
    unawaited(_stderr?.cancel());
    if (_exitCode == null) _killProcess();
    // Cancelled/failed probes must not poison the process-wide success cache.
    if (successful) onSuccess?.call(value);
  }

  void _killProcess() {
    try {
      _process?.kill();
    } on ProcessException {
      // The process may have exited between timeout and kill.
    }
  }
}
