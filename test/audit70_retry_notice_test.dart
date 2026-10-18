import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'support/audit70_translation_client.dart' as fixture;

class _FailedCache extends TranslationCacheStore {
  _FailedCache(Directory root) : super(cacheRoot: root);
  @override
  Future<void> putBlockTranslation(String key, String html) async =>
      throw FileSystemException('audit cache writes unavailable');
}

// Preserve a real rendered EPUB, then inject the same commit-time exception
// used for a late output lock. This does not manipulate Windows file handles.
class _LateLockOnce extends EpubRepacker {
  bool first = true;
  String? recovery;
  @override
  Future<void> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    Set<String> degradedBlockIds = const {},
    String? translatedTitle,
    void Function(int, int)? onProgress,
    Set<String> reviewChapterPaths = const {},
    Map<String, Object?>? reviewSnapshots,
  }) async {
    final fail = first;
    first = false;
    final destination = fail
        ? '$outputFilePath.audit-recovery'
        : outputFilePath;
    await super.writeTranslatedEpub(
      inputPath: inputPath,
      outputFilePath: destination,
      config: config,
      chapters: chapters,
      cancelToken: cancelToken,
      isCancelled: isCancelled,
      degradedBlockIds: degradedBlockIds,
      translatedTitle: translatedTitle,
      onProgress: onProgress,
      reviewChapterPaths: reviewChapterPaths,
      reviewSnapshots: reviewSnapshots,
    );
    if (fail) {
      recovery = destination;
      throw OutputFileLockedException(
        AppStrings(
          config.uiLanguage,
        ).outputFileLockedAtCommit(outputFilePath, destination),
        destination,
      );
    }
  }
}

void main() {
  test(
    'late output-lock retry cannot promise zero extra API calls when cache writes failed',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'audit-r21-lock-cost-',
      );
      final cache = _FailedCache(Directory('${temp.path}/cache'));
      addTearDown(() async {
        await cache.waitForMaintenanceForTest();
        await temp.delete(recursive: true);
      });
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<container><rootfile full-path="OPS/book.opf"/></container>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OPS/book.opf',
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Audit Book</dc:title></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OPS/c.xhtml',
            '<html><body><p>The morning was cold.</p></body></html>',
          ),
        );
      final input = await File(
        '${temp.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      final inspected = await EpubInspector().inspect(
        inputPath: input.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://offline.invalid',
        apiKey: 'offline-test',
        styleProfileEnabled: false,
        residualQualityCheck: false,
      );
      final api = fixture.AuditWrongWrapperClient();
      final repacker = _LateLockOnce();
      final translator = EpubChapterTranslator(
        cacheStore: cache,
        apiClient: api,
        repacker: repacker,
      );
      String failure = '';
      try {
        await translator.translateChapters(
          inputPath: input.path,
          outputDirectory: temp.path,
          config: config,
          chapters: inspected.chapters,
          cancelToken: CancelToken(),
        );
        fail('Expected injected late output lock');
      } on OutputFileLockedException catch (error) {
        failure = error.message;
      }
      expect(await File(repacker.recovery!).exists(), isTrue);
      final before = api.bodies;
      final retry = await translator.translateChapters(
        inputPath: input.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspected.chapters,
        cancelToken: CancelToken(),
      );
      final repeatedBody = api.bodies - before;
      final promise = failure.contains('no extra API cost');
      debugPrint(
        'AUDIT late lock/cache failure: promiseNoExtraCost=$promise retryCached=${retry.job.cachedBlocks}/${retry.job.totalBlocks} retryBodyCalls=$repeatedBody recoveryPreserved=true',
      );
      expect(repeatedBody, greaterThan(0));
      expect(
        promise,
        isFalse,
        reason:
            'A cache write failure must prevent a later lock message from promising a free retry',
      );
    },
  );
}
