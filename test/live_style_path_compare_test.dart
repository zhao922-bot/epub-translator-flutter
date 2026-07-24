import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';

void main() {
  test(
    'style profile live path with timings',
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
      final client = const TranslationApiClient();

      final sw = Stopwatch()..start();
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      // ignore: avoid_print
      print(
        'INSPECT_MS=${sw.elapsedMilliseconds} chapters=${inspection.chapters.length}',
      );

      final selected = inspection.chapters
          .where((c) => c.includeInTranslation)
          .toList();
      final sample = <Map<String, String>>[];
      for (final c in selected.where((c) => c.blocks.isNotEmpty).take(4)) {
        final text = c.blocks
            .map((b) => b.sourceText)
            .where((t) => t.trim().isNotEmpty)
            .take(12)
            .join('\n');
        if (text.trim().isEmpty) continue;
        sample.add({
          'title': c.title,
          'category': c.category.name,
          'text': text.length > 1500 ? text.substring(0, 1500) : text,
        });
      }
      // ignore: avoid_print
      print(
        'SAMPLE=${sample.length} chars=${sample.fold<int>(0, (s, m) => s + m['text']!.length)}',
      );

      final dio = client.buildDio(config);
      final t1 = sw.elapsedMilliseconds;
      final response = await dio.post<dynamic>(
        '/chat/completions',
        data: {
          'model': config.model,
          'temperature': 0.1,
          'max_tokens': 900,
          'messages': [
            {
              'role': 'system',
              'content':
                  'Return strict JSON only with keys: primaryGenre, secondaryGenres, tone, sentenceStyle, translationConstraints, avoid, confidence. confidence is high|medium|low.',
            },
            {
              'role': 'user',
              'content': jsonEncode({
                'kind': 'styleProfile',
                'targetLanguage': 'Chinese',
                'chapters': sample,
              }),
            },
          ],
        },
      );
      final raw = client.extractMessageContent(response.data);
      // ignore: avoid_print
      print('RAW_MS=${sw.elapsedMilliseconds - t1} RAW_LEN=${raw.length}');
      // ignore: avoid_print
      print('RAW_HEAD=${raw.length > 300 ? raw.substring(0, 300) : raw}');
      final decoded = client.decodeJsonObject(raw);
      // ignore: avoid_print
      print(
        'DECODED_KEYS=${decoded.keys.toList()} PRIMARY=${decoded['primaryGenre']} CONF=${decoded['confidence']}',
      );

      final t2 = sw.elapsedMilliseconds;
      final profile = await repo.generateStyleProfile(
        config: config,
        chapters: inspection.chapters,
      );
      // ignore: avoid_print
      print(
        'REPO_MS=${sw.elapsedMilliseconds - t2} empty=${profile.isEmpty} genre="${profile.primaryGenre}" conf=${profile.confidence.name} '
        'toneLen=${profile.tone.length} rules=${profile.translationConstraints.length} avoid=${profile.avoid.length}',
      );
      // ignore: avoid_print
      print('REPO_JSON=${jsonEncode(profile.toJson())}');

      expect(sample, isNotEmpty);
      expect(raw.trim(), isNotEmpty);
      expect(
        profile.isEmpty,
        isFalse,
        reason: 'repo style profile should not be empty when raw API works',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: liveTestSkipReason(),
  );
}
