import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../../translation/domain/models/translation_config.dart';

class SettingsStore {
  Future<TranslationConfig> load() async {
    try {
      final File file = await _settingsFile();
      if (!await file.exists()) {
        return TranslationConfig.defaults();
      }
      final String raw = await file.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return TranslationConfig.defaults();
      }
      return TranslationConfig.fromJson(decoded);
    } catch (_) {
      return TranslationConfig.defaults();
    }
  }

  Future<void> save(TranslationConfig config) async {
    final File file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
  }

  Future<File> _settingsFile() async {
    final Directory appDirectory = Directory(
      await PlatformUtils.appDocumentsDirectory(),
    );
    return File(path.join(appDirectory.path, 'settings.json'));
  }
}
