import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'real_book_fix_regression_test.dart' as fixture;

void main() {
  test(
    'large book keeps resources, skips low-risk reviews and resumes from a fresh repository',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      const chapters = 80, paragraphs = 50;
      const sentence =
          'The quiet house stood beside a winding road surrounded by green trees and fragrant flowers beneath the bright summer sky. ';
      final paragraph = List.filled(4, sentence).join();
      final archive = Archive();
      void add(String name, String value) =>
          archive.addFile(ArchiveFile.string(name, value));
      add('mimetype', 'application/epub+zip');
      add(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
      );
      add(
        'content.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Large book</dc:title></metadata><manifest>${List.generate(chapters, (i) => '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>').join()}<item id="cover" href="cover.png" media-type="image/png"/></manifest><spine>${List.generate(chapters, (i) => '<itemref idref="c$i"/>').join()}</spine></package>',
      );
      for (var i = 0; i < chapters; i++) {
        add(
          'c$i.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Story</title></head><body>${List.generate(paragraphs, (_) => '<p>$paragraph</p>').join()}</body></html>',
        );
      }
      final resource = List<int>.generate(1024 * 1024, (i) => i % 251);
      archive.addFile(ArchiveFile('cover.png', resource.length, resource));
      await f.book.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final config = f.config.copyWith(
        chunkSize: 12000,
        maxConcurrent: 4,
        maxSemanticReviewRequests: 2,
        styleProfileEnabled: false,
      );
      final inspection = await f.repo.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
      );
      final clock = Stopwatch()..start();
      var released = 0;
      final cold = await f.repo.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
        chapters: inspection.chapters,
        onChapterSourcesReleased: (_) => released++,
      );
      final coldMs = clock.elapsedMilliseconds;
      expect(cold.job.completedBlocks, chapters * paragraphs);
      expect(cold.job.degradedBlockCount, 0);
      expect(released, chapters);
      final report =
          jsonDecode(await File(cold.qualityReportPath!).readAsString()) as Map;
      expect(report['requests'], 0);
      expect(report['skippedLowRiskBlocks'], chapters * paragraphs);
      final paid = f.requests.length;
      final fresh = EpubTranslationRepository(
        cacheStore: TranslationCacheStore(
          cacheRoot: Directory('${f.dir.path}/cache'),
        ),
      );
      final reinspection = await fresh.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
      );
      clock.reset();
      final warm = await fresh.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
        chapters: reinspection.chapters,
      );
      expect(warm.job.cachedBlocks, chapters * paragraphs);
      expect(f.requests.length, paid);
      final exported = ZipDecoder().decodeBytes(
        await File(warm.job.outputPath).readAsBytes(),
      );
      expect(exported.findFile('cover.png')!.content, resource);
      expect(
        exported.files.where((f) => f.name.endsWith('.xhtml')),
        hasLength(chapters),
      );
      final stats = {
        'chapters': chapters,
        'blocks': chapters * paragraphs,
        'englishWords':
            paragraph.trim().split(RegExp(r'\s+')).length *
            chapters *
            paragraphs,
        'coldLocalFixtureMs': coldMs,
        'warmMs': clock.elapsedMilliseconds,
        'coldRequests': paid,
        'warmRequests': warm.apiUsage['requests'],
        'reviewRequests': report['requests'],
        'peakProcessRssBytes': ProcessInfo.maxRss,
      };
      // Optional artifact for a manual stress run; normal CI leaves no outputs.
      final out = Platform.environment['REVIEW_STRESS_REPORT'];
      if (out != null) {
        await File(
          out,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(stats));
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'cancellation retains completed reviews and usage; restart only requests remaining work',
    () async {
      final f = fixture.Fixture();
      await f.init(blocks: 40, chunkSize: 1000);
      addTearDown(f.dispose);
      final config = f.config.copyWith(
        maxConcurrent: 1,
        styleProfileEnabled: false,
      );
      final inspection = await f.repo.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
      );
      var cancel = false;
      TranslationJob? snapshot;
      await expectLater(
        f.repo.translateChapters(
          inputPath: f.book.path,
          outputDirectory: f.dir.path,
          config: config,
          chapters: inspection.chapters,
          isCancelled: () => cancel,
          onProgress: (job, _) {
            snapshot = job;
            if (job.completedBlocks >= 6) cancel = true;
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(snapshot!.apiUsage['requests'] as int, greaterThan(0));
      final before = f.requests.length;
      final fresh = EpubTranslationRepository(
        cacheStore: TranslationCacheStore(
          cacheRoot: Directory('${f.dir.path}/cache'),
        ),
      );
      final reinspection = await fresh.startJob(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config,
      );
      final result = await fresh.translateChapters(
        inputPath: f.book.path,
        outputDirectory: f.dir.path,
        config: config.copyWith(
          maxSemanticReviewRequests: 64,
          maxSemanticReviewTokens: 1024000,
        ),
        chapters: reinspection.chapters,
      );
      expect(result.job.degradedBlockCount, 0);
      expect(result.job.completedBlocks, 40);
      expect(result.job.cachedBlocks, greaterThan(0));
      final report =
          jsonDecode(await File(result.qualityReportPath!).readAsString())
              as Map;
      expect(report['unreviewed'], isEmpty);
      expect(report['corrections'], hasLength(40));
      expect(f.requests.length, greaterThan(before));
    },
  );
}
