import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/chapter_source_spool.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';

Set<String> _chapterOnly(Map<String, List<int>> files, String opfPath) => {
  'OPS/c.xhtml',
};

void main() {
  test(
    'missing source spool forwards cancellation during archive reload',
    () async {
      final temp = await Directory.systemTemp.createTemp('audit-r26-cancel-');
      final spoolDir = await Directory('${temp.path}/spool').create();
      final spool = ChapterSourceSpool(directory: spoolDir);
      addTearDown(() async {
        await spool.dispose();
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
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OPS/c.xhtml',
            '<html><head><title>Chapter</title></head><body><p>A small source paragraph.</p></body></html>',
          ),
        )
        ..addFile(
          ArchiveFile(
            'OPS/large-media.bin',
            128 * 1024 * 1024,
            Uint8List(128 * 1024 * 1024),
          )..compression = CompressionType.none,
        );
      final input = await File(
        '${temp.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      final inspected = await EpubInspector().inspect(
        inputPath: input.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      final released = await spool.release(inspected.chapters.single);
      for (final file in await spoolDir.list().toList()) {
        await file.delete();
      }
      var controlCancelled = false;
      final controlTimer = Timer(
        const Duration(milliseconds: 30),
        () => controlCancelled = true,
      );
      final controlWatch = Stopwatch()..start();
      await expectLater(
        EpubIsolateWorker.loadInspectionSnapshot(
          input.path,
          selectEntries: _chapterOnly,
          isCancelled: () => controlCancelled,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      controlWatch.stop();
      controlTimer.cancel();
      var checks = 0, cancelled = false, settled = false;
      Object? failure;
      final requested = Completer<void>();
      final cancelWatch = Stopwatch();
      Timer? cancelTimer;
      final operation = spool
          .restore(
            released,
            isCancelled: () {
              checks++;
              // The third parent check follows the missing snapshot read, immediately
              // before the real archive fallback. Cancel during its chunked read.
              if (checks == 3) {
                cancelTimer = Timer(const Duration(milliseconds: 30), () {
                  cancelled = true;
                  cancelWatch.start();
                  requested.complete();
                });
              }
              return cancelled;
            },
          )
          .then<void>(
            (_) {
              settled = true;
            },
            onError: (Object error) {
              failure = error;
              settled = true;
            },
          );
      await requested.future;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final settledWithin200ms = settled;
      await operation;
      cancelWatch.stop();
      cancelTimer?.cancel();
      debugPrint(
        'AUDIT missing-spool: bytes=${await input.length()} controlCancelMs=${controlWatch.elapsedMilliseconds} fallbackCancelMs=${cancelWatch.elapsedMilliseconds} settledWithin200ms=$settledWithin200ms checks=$checks failure=${failure.runtimeType}',
      );
      expect(failure, isA<TranslationCancelledException>());
      expect(
        settledWithin200ms,
        isTrue,
        reason:
            'The fallback should cancel its killable archive worker, as the direct control does.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
