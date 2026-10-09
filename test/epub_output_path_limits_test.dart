import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
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
  test(
    'output probe needs file creation but never subdirectory creation',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'direct_output_probe_',
      );
      addTearDown(() => temp.delete(recursive: true));
      // Model a destination where creating subdirectories is denied. This is
      // an I/O-path regression, not a claim to reproduce Windows ACLs on Linux.
      await IOOverrides.runZoned(
        () => EpubChapterTranslator.validateOutputDirectory(
          temp.path,
          UiLanguage.chinese,
        ),
        createDirectory: (path) =>
            throw FileSystemException('Subdirectories denied', path),
      );
      expect(temp.listSync(), isEmpty);
    },
  );

  group('output filename component limit', () {
    test('reserves the temporary suffix at the exact UTF-16 boundary', () {
      final name = EpubChapterTranslator.outputFileNameForTest(
        'a' * 228,
        '',
        windows: true,
      );
      expect(name.length + 22, 255);
      expect(name, '${'a' * 228}.epub');
      final shortened = EpubChapterTranslator.outputFileNameForTest(
        'a' * 229,
        '',
        windows: true,
      );
      expect(shortened.length + 22, lessThanOrEqualTo(255));
      expect(shortened, matches(RegExp(r'_[0-9a-f]{12}\.epub$')));
    });

    test(
      'shortens astral titles safely with a stable collision-resistant hash',
      () {
        final title = '😀' * 150;
        final name = EpubChapterTranslator.outputFileNameForTest(title, '_zh');
        expect(name.length + 22, lessThanOrEqualTo(255));
        expect(name, contains('_zh_'));
        expect(name.runes, isNot(contains(0xfffd)));
        expect(name, EpubChapterTranslator.outputFileNameForTest(title, '_zh'));
        expect(
          name,
          isNot(
            EpubChapterTranslator.outputFileNameForTest('${title}other', '_zh'),
          ),
        );
      },
    );

    test('long suffix also leaves room for the title and hash', () {
      final name = EpubChapterTranslator.outputFileNameForTest(
        'book',
        'x' * 300,
      );
      expect(name.length + 22, lessThanOrEqualTo(255));
      expect(name, startsWith('book'));
      expect(name, endsWith('.epub'));
    });

    test('component guard is independent of long-path policy', () async {
      for (final enabled in <bool?>[false, true, null]) {
        await expectLater(
          EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
            'C:\\out\\${'a' * 229}.epub',
            longPathsEnabledReader: () async => enabled,
          ),
          throwsA(isA<FileSystemException>()),
        );
      }
      final name = EpubChapterTranslator.outputFileNameForTest(
        'a' * 300,
        '_zh',
      );
      await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
        'C:\\${'directory\\' * 40}$name',
        longPathsEnabledReader: () async => true,
      );
    });
  });
  test(
    'Linux Chinese filenames fit the UTF-8 temporary component limit',
    () async {
      final title = '中' * 75;
      final name = EpubChapterTranslator.outputFileNameForTest(
        title,
        '_translated',
        windows: false,
      );
      expect(name, isNot('${title}_translated.epub'));
      expect(name, matches(RegExp(r'_[0-9a-f]{12}\.epub$')));
      expect(utf8.encode(name).length + 22, lessThanOrEqualTo(255));
      expect(
        EpubChapterTranslator.outputFileNameForTest(
          title,
          '_translated',
          windows: true,
        ),
        '${title}_translated.epub',
      );
      final emoji = EpubChapterTranslator.outputFileNameForTest(
        '😀' * 75,
        '_zh',
        windows: false,
      );
      expect(utf8.encode(emoji).length + 22, lessThanOrEqualTo(255));
      expect(emoji.runes, isNot(contains(0xfffd)));
      if (!Platform.isWindows) {
        final temp = await Directory.systemTemp.createTemp('utf8_filename_');
        addTearDown(() => temp.delete(recursive: true));
        await File(
          '${temp.path}/$name.tmp.1234567890123456',
        ).writeAsString('ok');
      }
    },
  );

  test(
    'invalid output directories fail before building the API client',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'output_directory_probe_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final regularFile = await File(
        '${temp.path}/not-a-directory',
      ).writeAsString('x');
      final client = _CountingApiClient();
      final translator = EpubChapterTranslator(apiClient: client);
      final chapter = const EpubHtmlExtractor()
          .inspectChapterBytes(
            chapterPath: 'chapter.xhtml',
            bytes: utf8.encode('<html><body><p>Hello world.</p></body></html>'),
          )
          .copyWith(includeInTranslation: true);
      for (final directory in [regularFile.path, '${temp.path}/missing']) {
        await expectLater(
          translator.translateChapters(
            inputPath: '${temp.path}/book.epub',
            outputDirectory: directory,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              uiLanguage: UiLanguage.chinese,
            ),
            chapters: [chapter],
            cancelToken: CancelToken(),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('输出目录'),
            ),
          ),
        );
      }
      expect(client.buildCount, 0);
      await EpubChapterTranslator.validateOutputDirectory(
        temp.path,
        UiLanguage.chinese,
      );
      expect(
        temp.listSync().where((e) => e.path.contains('epub-write-probe')),
        isEmpty,
      );
    },
  );
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
    final String longPath = "C:\\${'directory\\' * 25}book.epub";

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

class _CountingApiClient extends TranslationApiClient {
  int buildCount = 0;
  @override
  Dio buildDio(TranslationConfig config) {
    buildCount += 1;
    throw StateError('API client must not be built');
  }
}
