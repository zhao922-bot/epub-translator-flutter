import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pre-run path budget covers both EPUB recovery files and the longer
/// quality/diagnostic report atomic-write names. The former +26 budget
/// covered the recovery path but missed these derived artifacts.
void main() {
  const budget = EpubChapterTranslator.outputPathSuffixBudget;
  group('B-01 all-artifact suffix budget', () {
    test('longest usable path leaves room for every artifact', () {
      const length = 259 - budget;
      final String path = "C:\\${'a' * (length - 3)}";
      expect(path.length, length);
      expect(
        EpubChapterTranslator.outputPathExceedsWindowsMaxPath(path),
        isFalse,
      );
    });

    for (final int length in <int>[234, 235, 236, 237]) {
      test('$length-char path now exceeds (was admitted under +22)', () {
        final String path = "C:\\${'a' * (length - 3)}";
        expect(path.length, length);
        expect(
          EpubChapterTranslator.outputPathExceedsWindowsMaxPath(path),
          isTrue,
        );
      });
    }

    test(
      'throwIf* path check throws only when the long-path policy is off',
      () async {
        // The component fits exactly; only the whole-path rule fires.
        final String path = "C:\\d\\${'a' * (255 - budget - 5)}.epub";
        expect(path.length + budget, 260);
        await expectLater(
          EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
            path,
            longPathsEnabledReader: () async => false,
          ),
          throwsA(isA<WindowsLongPathException>()),
        );
        // Policy on / unknown: the precheck stays silent.
        await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
          path,
          longPathsEnabledReader: () async => true,
        );
        await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
          path,
          longPathsEnabledReader: () async => null,
        );
      },
    );

    test(
      'filename component check covers report and atomic-write suffixes',
      () async {
        final String ok = "C:\\${'a' * (255 - budget - 5)}.epub";
        await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
          ok,
          longPathsEnabledReader: () async => false,
        );
        // Component limits apply independently of the system long-path policy.
        final String tooLong = "C:\\${'a' * (256 - budget - 5)}.epub";
        await expectLater(
          EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
            tooLong,
            longPathsEnabledReader: () async => true,
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('documented suffix arithmetic matches the worker', () {
      // Mirrors epub_isolate_worker.dart: every temp/backup/recovery name
      // appends DateTime.now().microsecondsSinceEpoch (16 digits).
      const int digits = 16;
      expect('.tmp.'.length + digits, 21);
      expect('.bak.'.length + digits, 21);
      expect('.recovery.'.length + digits, 26);
    });

    test('AppStrings message still names the 260 limit', () {
      expect(
        const AppStrings(UiLanguage.english).outputPathTooLong('x'),
        contains('260'),
      );
    });
  });
}
