import 'dart:io';

import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bool liveEnabled = Platform.environment['LIVE_TRANSLATION_E2E'] == '1';

  test(
    'live connection + inspect + style profile',
    () async {
      final String apiKey =
          Platform.environment['LIVE_TRANSLATION_API_KEY'] ?? '';
      final String epubPath =
          Platform.environment['LIVE_TRANSLATION_EPUB_PATH'] ?? '';
      expect(apiKey, isNotEmpty);
      expect(await File(epubPath).exists(), isTrue);

      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl:
            Platform.environment['LIVE_TRANSLATION_API_BASE_URL'] ??
            'https://api.deepseek.com',
        apiKey: apiKey,
        model:
            Platform.environment['LIVE_TRANSLATION_MODEL'] ?? 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
      );
      final repo = EpubTranslationRepository();

      final connection = await repo.testConnection(config: config);
      expect(connection.trim(), isNotEmpty);

      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      expect(inspection.chapters, isNotEmpty);
      final int selected = inspection.chapters
          .where((c) => c.includeInTranslation)
          .length;
      final int blocks = inspection.chapters.fold<int>(
        0,
        (sum, c) => sum + c.blocks.length,
      );
      expect(selected, greaterThan(0));
      expect(blocks, greaterThan(0));

      final Stopwatch styleStopwatch = Stopwatch()..start();
      final profile = await repo.generateStyleProfile(
        config: config,
        chapters: inspection.chapters,
      );
      styleStopwatch.stop();
      expect(profile.isEmpty, isFalse);
      expect(profile.confidence.name, anyOf('high', 'medium', 'low'));
      // Print non-sensitive summary for operator visibility.
      // ignore: avoid_print
      print(
        'STYLE genre="${profile.primaryGenre}" conf=${profile.confidence.name} '
        'toneLen=${profile.tone.length} rules=${profile.translationConstraints.length} '
        'avoid=${profile.avoid.length} empty=${profile.isEmpty} '
        'chapters=${inspection.chapters.length} selected=$selected blocks=$blocks '
        'elapsedMs=${styleStopwatch.elapsedMilliseconds}',
      );
      // ignore: avoid_print
      print('STYLE_JSON=${jsonEncode(profile.toJson())}');
    },
    skip: liveEnabled ? false : 'Set LIVE_TRANSLATION_E2E=1',
  );
}
