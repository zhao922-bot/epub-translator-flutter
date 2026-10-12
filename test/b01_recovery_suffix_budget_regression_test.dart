import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// B-01 regression: the Windows pre-run path budget must reserve the
/// longest suffix the app actually writes — `.recovery.<16 digits>` (+26,
/// from the lock-conflict recovery path) — not the old +22 estimate.
///
/// The old comment claimed the longest form was `.tmp.<16>` (+22) and
/// `.bak.<13>` (+18), but every suffix uses
/// [DateTime.microsecondsSinceEpoch] (16 digits):
/// - `.tmp.` + 16 digits = 21
/// - `.bak.` + 16 digits = 21
/// - `.recovery.` + 16 digits = 26  (the true longest)
///
/// A 234–237-char output path passed the old precheck (234 + 22 < 260) yet
/// the commit would then write a 260–263-char `.recovery.*` path — failing
/// at ~98% after every API call was already billed.
void main() {
  group('B-01 recovery-suffix budget (+26)', () {
    test('233-char path still fits (233 + 26 == 259)', () {
      final String path = "C:\\${'a' * 230}";
      expect(path.length, 233);
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

    test('throwIf* path check throws only when the long-path policy is off',
        () async {
      // 234-char path with a 229-char filename: only the whole-path rule
      // fires (the component rule passes at exactly 229 + 26 == 255).
      final String path = "C:\\d\\${'a' * 224}.epub";
      expect(path.length, 234);
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
    });

    test('filename component check reserves +26 (229 ok, 230 throws)', () async {
      // 224 a's + '.epub' = 229 chars: 229 + 26 == 255, fits exactly.
      // Short directory keeps the whole-path check (232 + 26 < 260) out.
      final String ok = "C:\\${'a' * 224}.epub";
      await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
        ok,
        longPathsEnabledReader: () async => false,
      );
      // 225 a's + '.epub' = 230 chars: 230 + 26 == 256 > 255, throws even
      // when the long-path policy is on (component limit is independent).
      final String tooLong = "C:\\${'a' * 225}.epub";
      await expectLater(
        EpubChapterTranslator.throwIfOutputPathTooLongForWindows(
          tooLong,
          longPathsEnabledReader: () async => true,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

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
