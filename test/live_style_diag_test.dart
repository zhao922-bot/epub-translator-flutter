import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';

void main() {
  test(
    'diagnose style profile raw keys',
    () async {
      final apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final epubPath = Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: apiKey,
        model: 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
      );
      final repo = EpubTranslationRepository();
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      final memory = await repo.generateInitialBookMemoryForTest(
        dio: const TranslationApiClient().buildDio(config),
        config: config,
        chapters: inspection.chapters,
      );
      final keys = memory.keys.toList()..sort();
      // ignore: avoid_print
      print('MEMORY_KEYS=$keys');
      // ignore: avoid_print
      print('SUMMARY_LEN=${(memory['bookSummary'] as String? ?? '').length}');
      // ignore: avoid_print
      print('STYLE_GUIDE=${(memory['styleGuide'] as List?)?.length ?? 0}');
      // ignore: avoid_print
      print('GLOSSARY=${(memory['glossary'] as List?)?.length ?? 0}');
      final style = memory['styleProfile'];
      // ignore: avoid_print
      print('STYLE_RUNTIME=${style.runtimeType}');
      if (style is Map) {
        final styleKeys = style.keys.map((e) => e.toString()).toList()..sort();
        // ignore: avoid_print
        print('STYLE_KEYS=$styleKeys');
        // ignore: avoid_print
        print(
          'STYLE_GENRE_LEN=${'${style['primaryGenre'] ?? ''}'.trim().length}',
        );
        // ignore: avoid_print
        print('STYLE_CONF=${style['confidence']}');
        // ignore: avoid_print
        print('STYLE_JSON_LEN=${jsonEncode(style).length}');
      } else {
        // ignore: avoid_print
        print('STYLE_MISSING');
      }
      final profile = await repo.generateStyleProfile(
        config: config,
        chapters: inspection.chapters,
      );
      // ignore: avoid_print
      print(
        'PROFILE empty=${profile.isEmpty} genreLen=${profile.primaryGenre.length} conf=${profile.confidence.name} constraints=${profile.translationConstraints.length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: liveTestSkipReason(),
  );
}
