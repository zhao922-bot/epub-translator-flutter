import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_test_gate.dart';

void main() {
  test(
    'repo style profile only',
    () async {
      final out = File(
        r'F:\vibe coding\epub-translator-flutter-clean\work\repo_style_only.txt',
      );
      Future<void> log(String msg) async {
        // ignore: avoid_print
        print(msg);
        await out.writeAsString(
          '${DateTime.now().toIso8601String()} $msg\n',
          mode: FileMode.append,
        );
      }

      await out.writeAsString('');
      final apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final epubPath = Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: apiKey,
        model: 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
        timeoutSeconds: 90,
        maxRetries: 2,
      );
      final repo = EpubTranslationRepository();
      final sw = Stopwatch()..start();
      await log('START');
      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: Directory.systemTemp.path,
        config: config,
      );
      await log(
        'INSPECT_MS=${sw.elapsedMilliseconds} chapters=${inspection.chapters.length}',
      );
      try {
        final profile = await repo.generateStyleProfile(
          config: config,
          chapters: inspection.chapters,
        );
        await log(
          'PROFILE empty=${profile.isEmpty} genre="${profile.primaryGenre}" conf=${profile.confidence.name} '
          'tone="${profile.tone}" sentence="${profile.sentenceStyle}" '
          'rules=${profile.translationConstraints.length} avoid=${profile.avoid.length} ms=${sw.elapsedMilliseconds}',
        );
        await log('JSON=${jsonEncode(profile.toJson())}');
        expect(profile.isEmpty, isFalse);
        expect(
          profile.primaryGenre.toLowerCase(),
          anyOf(
            contains('business'),
            contains('nonfiction'),
            contains('entrepreneur'),
          ),
        );
      } catch (e, st) {
        await log('ERROR ${e.runtimeType}: $e');
        await log(st.toString().split('\n').take(12).join(' || '));
        fail('generateStyleProfile threw: $e');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: liveTestSkipReason(),
  );
}
