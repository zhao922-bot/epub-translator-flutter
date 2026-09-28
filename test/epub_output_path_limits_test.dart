import 'dart:io';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the Windows final-output-path precheck (Bug 2 of the
/// ninth review round): the longest write path the commit produces is
/// `outputFilePath + '.tmp.<16 hex>'`, so the run must fail before any paid
/// API work when that exceeds MAX_PATH (260) while the system long-path
/// policy is off.
void main() {
  group('outputPathExceedsWindowsMaxPath', () {
    test('boundary: 237 chars fits (237 + 22 == 259, the longest usable)', () {
      final String path = "C:\\${'a' * 234}";
      expect(path.length, 237);
      expect(
        EpubChapterTranslator.outputPathExceedsWindowsMaxPath(path),
        isFalse,
      );
    });

    test(
      'boundary: 238 chars exceeds (238 + 22 == 260, NUL no longer fits)',
      () {
        final String path = "C:\\${'a' * 235}";
        expect(path.length, 238);
        expect(
          EpubChapterTranslator.outputPathExceedsWindowsMaxPath(path),
          isTrue,
        );
      },
    );

    test('short path passes', () {
      expect(
        EpubChapterTranslator.outputPathExceedsWindowsMaxPath(
          r'C:\out\book.epub',
        ),
        isFalse,
      );
    });
  });

  group('throwIfOutputPathTooLongForWindows', () {
    final String longPath = "C:\\${'a' * 236}.epub";

    test('throws when the long-path policy is off', () async {
      await expectLater(
        EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
          longPath,
          longPathsEnabledReader: () async => false,
        ),
        throwsA(isA<WindowsLongPathException>()),
      );
    });

    test('does not throw when the long-path policy is on', () async {
      await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
        longPath,
        longPathsEnabledReader: () async => true,
      );
    });

    test('fails open when the policy cannot be determined', () async {
      // Blocking on a guess would be worse than the registry read failing
      // silently: the run proceeds and the OS error (if any) surfaces at
      // the commit instead of being mis-attributed.
      await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
        longPath,
        longPathsEnabledReader: () async => null,
      );
    });

    test('short path never consults the registry', () async {
      bool consulted = false;
      await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
        r'C:\out\book.epub',
        longPathsEnabledReader: () async {
          consulted = true;
          return false;
        },
      );
      expect(consulted, isFalse);
    });
  });

  group('outputPathTooLong message', () {
    test('Chinese message names the limit and the path', () {
      final String message = const AppStrings(
        UiLanguage.chinese,
      ).outputPathTooLong(r'C:\out\book.epub');
      expect(message, contains('260'));
      expect(message, contains(r'C:\out\book.epub'));
    });

    test('English message names the limit and the path', () {
      final String message = const AppStrings(
        UiLanguage.english,
      ).outputPathTooLong(r'C:\out\book.epub');
      expect(message, contains('260'));
      expect(message, contains(r'C:\out\book.epub'));
    });
  });

  group('repository mapping', () {
    test('WindowsLongPathException becomes the localized message', () async {
      final repository = EpubTranslationRepository(
        translator: _LongPathThrowingTranslator(),
      );
      for (final UiLanguage language in UiLanguage.values) {
        final TranslationConfig config = TranslationConfig.defaults().copyWith(
          uiLanguage: language,
        );
        try {
          await repository.translateChapters(
            inputPath: r'C:\in\book.epub',
            outputDirectory: r'C:\out',
            config: config,
            chapters: const <InspectedChapter>[],
          );
          fail('expected a StateError');
        } on StateError catch (error) {
          // Actionable localized message naming the failing path, not a
          // raw English OS error at ~98% of the run.
          expect(
            error.message,
            AppStrings(
              language,
            ).outputPathTooLong(_LongPathThrowingTranslator.failingPath),
          );
        }
      }
    });
  });
  group('preRunProbeErrorMessage', () {
    const AppStrings strings = AppStrings(UiLanguage.chinese);
    const String path = r'C:\out\book.epub';

    test('sharing violation (osError 32) reports "locked"', () {
      final String message = EpubChapterTranslator.preRunProbeErrorMessage(
        const FileSystemException(
          'Cannot create file',
          path,
          OSError('The process cannot access the file', 32),
        ),
        strings,
        path,
      );
      expect(message, contains('被其他程序占用'));
      expect(message, contains(path));
    });

    test('access denied (osError 5) reports "not writable", not "locked"', () {
      final String message = EpubChapterTranslator.preRunProbeErrorMessage(
        const FileSystemException(
          'Cannot create file',
          path,
          OSError('Access is denied', 5),
        ),
        strings,
        path,
      );
      expect(message, contains('无法写入输出文件'));
      expect(message, isNot(contains('被其他程序占用')));
    });
  });
}

class _LongPathThrowingTranslator extends EpubChapterTranslator {
  static const String failingPath = r'C:\very\long\output\book.epub';

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    throw WindowsLongPathException(failingPath);
  }
}
