import 'package:epub_translator_flutter/features/translation/infrastructure/session_path_store.dart';

class MemorySessionPathStore extends SessionPathStore {
  SessionPathResult _paths = const SessionPathResult(
    status: SessionPathStatus.missing,
  );

  @override
  Future<SessionPathResult> load() async => _paths;

  @override
  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {
    _paths = SessionPathResult(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
    );
  }
}
