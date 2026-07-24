import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';

void main() {
  test(
    'raw style profile API diagnosis',
    () async {
      final apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final epubPath = Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: apiKey,
        model: 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
        timeoutSeconds: 120,
      );
      final repo = EpubTranslationRepository();
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      final chapters = inspection.chapters;
      final selected = chapters.where((c) => c.includeInTranslation).toList();
      final sample = <Map<String, String>>[];
      for (final c in selected.take(4)) {
        final text = c.blocks
            .map((b) => b.sourceText)
            .where((t) => t.trim().isNotEmpty)
            .take(8)
            .join('\n');
        if (text.trim().isEmpty) continue;
        sample.add({
          'title': c.title,
          'category': c.category.name,
          'text': text.length > 1200 ? text.substring(0, 1200) : text,
        });
      }
      // ignore: avoid_print
      print('SAMPLE_CHAPTERS=${sample.length}');
      // ignore: avoid_print
      print(
        'SAMPLE_CHARS=${sample.fold<int>(0, (s, m) => s + (m['text']?.length ?? 0))}',
      );
      // ignore: avoid_print
      print(
        'CATEGORIES=${selected.map((c) => c.category.name).toSet().toList()}',
      );

      final client = const TranslationApiClient();
      final dio = client.buildDio(config);
      final payload = {
        'kind': 'styleProfile',
        'targetLanguage': 'Chinese',
        'chapters': sample,
      };
      final response = await dio.post<dynamic>(
        '/chat/completions',
        data: {
          'model': config.model,
          'temperature': 0.1,
          'max_tokens': 700,
          'messages': [
            {
              'role': 'system',
              'content':
                  'Return strict JSON only with keys: primaryGenre, secondaryGenres, tone, sentenceStyle, translationConstraints, avoid, confidence. confidence is high|medium|low.',
            },
            {'role': 'user', 'content': jsonEncode(payload)},
          ],
        },
      );
      final raw = client.extractMessageContent(response.data);
      // ignore: avoid_print
      print('RAW_LEN=${raw.length}');
      // ignore: avoid_print
      print('RAW_HEAD=${raw.length > 240 ? raw.substring(0, 240) : raw}');
      Map<String, dynamic>? decoded;
      try {
        decoded = client.decodeJsonObject(raw);
      } catch (e) {
        // ignore: avoid_print
        print('DECODE_ERROR=${e.runtimeType}');
      }
      // ignore: avoid_print
      print('DECODED_KEYS=${decoded?.keys.toList()}');
      // ignore: avoid_print
      print('PRIMARY=${decoded?['primaryGenre']}');
      // ignore: avoid_print
      print('CONF=${decoded?['confidence']}');

      final profile = await repo.generateStyleProfile(
        config: config,
        chapters: chapters,
      );
      // ignore: avoid_print
      print(
        'REPO_PROFILE empty=${profile.isEmpty} genre="${profile.primaryGenre}" conf=${profile.confidence.name} rules=${profile.translationConstraints.length}',
      );
      expect(sample, isNotEmpty);
      expect(raw.trim(), isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: liveTestSkipReason(),
  );
}
