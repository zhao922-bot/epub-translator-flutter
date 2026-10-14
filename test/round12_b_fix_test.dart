import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

// Regression tests for the B-area round-12 fixes (platform/export/UI).
//
// Conventions: worker-level guard tests build their fixtures with
// package:archive directly; controller tests drive the public
// inspection/translation flow with a configurable repository double.

ArchiveFile _zipEntry(String name, List<int> data, {bool compress = true}) {
  final file = ArchiveFile(name, data.length, data);
  file.compression = compress ? CompressionType.deflate : CompressionType.none;
  return file;
}

/// Minimal valid EPUB with [chapters] mapping entry name -> inflated text
/// size. Set [emptySpine] for an OPF whose spine resolves no chapters.
Future<String> _writeTestEpub(
  Directory dir,
  String name, {
  required Map<String, int> chapters,
  bool emptySpine = false,
}) async {
  const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';
  final manifest = chapters.keys
      .map(
        (c) => '<item id="$c" href="$c" media-type="application/xhtml+xml"/>',
      )
      .join();
  final spine = emptySpine
      ? ''
      : chapters.keys.map((c) => '<itemref idref="$c"/>').join();
  final opf =
      '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Round12</dc:title><dc:identifier id="uid">r12</dc:identifier><dc:language>en</dc:language></metadata>
<manifest>$manifest</manifest>
<spine>$spine</spine>
</package>''';
  final archive = Archive()
    ..addFile(
      _zipEntry(
        'mimetype',
        utf8.encode('application/epub+zip'),
        compress: false,
      ),
    )
    ..addFile(_zipEntry('META-INF/container.xml', utf8.encode(containerXml)))
    ..addFile(_zipEntry('OEBPS/content.opf', utf8.encode(opf)));
  for (final entry in chapters.entries) {
    final body = '<html><body><p>${'x' * entry.value}</p></body></html>';
    archive.addFile(_zipEntry('OEBPS/${entry.key}', utf8.encode(body)));
  }
  final file = File('${dir.path}/$name')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
  return file.path;
}

/// Minimal EPUB whose OPF inflates to ~[opfPadding] bytes past the XML
/// skeleton, for the title-read guard test.
Future<String> _writeTitleEpub(Directory dir, {required int opfPadding}) async {
  const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';
  // Incompressible padding (deterministic PRNG): highly compressible padding
  // would trip the header-level 100:1 compression-ratio guard instead of the
  // per-entry inflate cap this test targets.
  final random = Random(1234);
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final padding = String.fromCharCodes(
    List<int>.generate(
      opfPadding,
      (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ),
  );
  final opf =
      '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Round12</dc:title><dc:identifier id="uid">r12</dc:identifier><dc:language>en</dc:language></metadata>
<manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="c1"/></spine>
<!-- $padding -->
</package>''';
  final archive = Archive()
    ..addFile(
      _zipEntry(
        'mimetype',
        utf8.encode('application/epub+zip'),
        compress: false,
      ),
    )
    ..addFile(_zipEntry('META-INF/container.xml', utf8.encode(containerXml)))
    ..addFile(_zipEntry('OEBPS/content.opf', utf8.encode(opf)))
    ..addFile(
      _zipEntry(
        'OEBPS/c1.xhtml',
        utf8.encode('<html><body><p>Hi</p></body></html>'),
      ),
    );
  final file = File('${dir.path}/title.epub')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
  return file.path;
}

void _sparsify(File file, int size) {
  final raf = file.openSync(mode: FileMode.write);
  try {
    raf.truncateSync(size);
  } finally {
    raf.closeSync();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -----------------------------------------------------------------------
  // P1-#1: the chunked inflate guard aborts mid-stream.
  // -----------------------------------------------------------------------
  group('P1-#1 chunked inflate guard', () {
    test('aborts mid-stream: reported bytes stay near the cap', () {
      // Deterministic pseudo-random payload: deflate cannot exploit it, so
      // ~200KB of compressed input inflates to ~200KB and must cross
      // several 64KB guard chunks before the cap trips.
      final random = Random(42);
      final data = Uint8List.fromList(
        List<int>.generate(200 * 1024, (_) => random.nextInt(256)),
      );
      final compressed = ZLibCodec(raw: true).encode(data);
      expect(
        compressed.length,
        greaterThan(data.length ~/ 2),
        reason: 'fixture must not be highly compressible',
      );
      final entry = ArchiveFile('bomb.bin', data.length, data)
        ..compression = CompressionType.deflate;
      final archive = Archive()..addFile(entry);
      final zipBytes = ZipEncoder().encode(archive) as Uint8List;
      final file = ZipDecoder().decodeBytes(zipBytes).find('bomb.bin')!;
      try {
        EpubIsolateWorker.inflateZipFileGuardedForTest(
          file: file,
          inputPath: 'bomb.epub',
          limitBytes: 1024,
        );
        fail('expected EpubDecompressionLimitException');
      } on EpubDecompressionLimitException catch (error) {
        // Mid-stream abort: the guard tripped on an early chunk, long
        // before the full payload materialized.
        expect(error.uncompressedBytes, lessThan(data.length));
        expect(error.limitBytes, 1024);
      }
      // Under the cap the payload inflates intact.
      final inflated = EpubIsolateWorker.inflateZipFileGuardedForTest(
        file: file,
        inputPath: 'bomb.epub',
        limitBytes: 300 * 1024,
      );
      expect(inflated, data);
    });
  });

  // -----------------------------------------------------------------------
  // P1-#2: the formal inspection path enforces the cross-entry total.
  // -----------------------------------------------------------------------
  group('P1-#2 inspection cumulative cap', () {
    test(
      'many small entries exceeding the total fail the inspection',
      () async {
        final dir = await Directory.systemTemp.createTemp('r12_p1_2_');
        addTearDown(() => dir.delete(recursive: true));
        final epubPath = await _writeTestEpub(
          dir,
          'many.epub',
          chapters: {'c1.xhtml': 40000, 'c2.xhtml': 40000, 'c3.xhtml': 40000},
        );
        // Each entry inflates to ~40 KiB (no per-entry trip), but the ~120 KiB
        // total exceeds the 100 KiB test cap.
        await expectLater(
          EpubIsolateWorker.loadInspectionSnapshot(
            epubPath,
            selectEntries: EpubInspector.inspectionEntryPaths,
            totalInflatedLimitOverrideForTest: 100 * 1024,
          ),
          throwsA(isA<EpubDecompressionLimitException>()),
        );
        // The same book inspects fine without the shrunken cap.
        final snapshot = await EpubIsolateWorker.loadInspectionSnapshot(
          epubPath,
          selectEntries: EpubInspector.inspectionEntryPaths,
        );
        expect(
          snapshot.files.keys,
          containsAll(['OEBPS/c1.xhtml', 'OEBPS/c2.xhtml', 'OEBPS/c3.xhtml']),
        );
      },
    );
  });

  // -----------------------------------------------------------------------
  // P2-#14: the title read fails loudly on the decompression guard.
  // -----------------------------------------------------------------------
  group('P2-#14 title-read guard', () {
    test('rethrows the limit instead of degrading to "no title"', () async {
      final dir = await Directory.systemTemp.createTemp('r12_p2_14_');
      addTearDown(() => dir.delete(recursive: true));
      final epubPath = await _writeTitleEpub(dir, opfPadding: 20000);
      await expectLater(
        EpubIsolateWorker.readBookTitleForTest(epubPath, limitBytes: 1024),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
      // A generous cap reads the title normally.
      expect(
        await EpubIsolateWorker.readBookTitleForTest(
          epubPath,
          limitBytes: 10 * 1024 * 1024,
        ),
        'Round12',
      );
    });
  });

  // -----------------------------------------------------------------------
  // P2-#15: the ledger follows actual deletions, not the plan.
  // -----------------------------------------------------------------------
  group('P2-#15 ledger follows actual deletions', () {
    test('failed payload delete keeps the ledger', () async {
      final dir = await Directory.systemTemp.createTemp('r12_p2_15_');
      addTearDown(() => dir.delete(recursive: true));
      final finalFile = File('${dir.path}/book.epub')..createSync();
      // Indexed fallback payload (100 MiB, complete) + a complete spare
      // (200 MiB) + a 400 MiB ledger: 700 MiB total. The pure plan is
      // [tmp.1, ledger] — the tmp is the only deletable complete payload
      // and the remainder still exceeds the 512 MiB budget.
      final index = File('${dir.path}/book.epub.recovery-index');
      await index.writeAsString('book.epub.tmp.1\n');
      final tmp = File('${dir.path}/book.epub.tmp.1')..createSync();
      _sparsify(tmp, 100 * 1024 * 1024);
      final spare = File('${dir.path}/book.epub.recovery.2')..createSync();
      _sparsify(spare, 200 * 1024 * 1024);
      // Grow the ledger to 400 MiB without disturbing its registered-tmp
      // content at the head (truncate would destroy it).
      final indexRaf = index.openSync(mode: FileMode.append);
      try {
        indexRaf.setPositionSync(400 * 1024 * 1024 - 1);
        indexRaf.writeByteSync(0);
      } finally {
        indexRaf.closeSync();
      }

      await EpubIsolateWorker.enforceRecoveryBudgetForTest(
        finalFile,
        deleteForTest: (file) async {
          if (EpubIsolateWorker.sameFilesystemPath(file.path, tmp.path)) {
            throw const FileSystemException('simulated stuck delete');
          }
          await file.delete();
        },
      );

      expect(
        tmp.existsSync(),
        isTrue,
        reason: 'failed delete leaves the payload',
      );
      expect(
        index.existsSync(),
        isTrue,
        reason:
            'P2-#15: the ledger is re-evaluated against the disk — the '
            'planned payload delete did not land, so the ledger stays',
      );
      expect(spare.existsSync(), isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // P-#43: STORED entries skip the guard-stream copy.
  // -----------------------------------------------------------------------
  group('P-#43 STORED zero-copy', () {
    test('returns correct bytes without the guard stream', () {
      final data = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
      final entry = ArchiveFile('s.bin', data.length, data)
        ..compression = CompressionType.none;
      final archive = Archive()..addFile(entry);
      final zipBytes = ZipEncoder().encode(archive) as Uint8List;
      final file = ZipDecoder().decodeBytes(zipBytes).find('s.bin')!;
      final inflated =
          EpubIsolateWorker.inflateZipFileGuardedForTest(
                file: file,
                inputPath: 's.epub',
                limitBytes: 1024 * 1024,
              )
              as Uint8List;
      expect(inflated, data);
      // Zero-copy: the STORED fast path hands back the source stream's view
      // directly instead of copying through _GuardedInflateStream's
      // growable buffer. The view sits at the entry's offset inside the
      // decoded archive buffer (a guard-stream copy would start at 0).
      expect(inflated.offsetInBytes, greaterThan(0));
    });

    test('STORED entries over the cap still throw', () {
      final data = Uint8List(2048);
      final entry = ArchiveFile('big.bin', data.length, data)
        ..compression = CompressionType.none;
      final archive = Archive()..addFile(entry);
      final zipBytes = ZipEncoder().encode(archive) as Uint8List;
      final file = ZipDecoder().decodeBytes(zipBytes).find('big.bin')!;
      expect(
        () => EpubIsolateWorker.inflateZipFileGuardedForTest(
          file: file,
          inputPath: 'big.epub',
          limitBytes: 1024,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
    });
  });

  // -----------------------------------------------------------------------
  // P-#44: the CRC check and the repair share one inflation.
  // -----------------------------------------------------------------------
  group('P-#44 inflate cache', () {
    test('second inflation of one entry reuses the cached bytes', () {
      final data = Uint8List.fromList(
        List<int>.generate(5000, (i) => (i * 31 + 7) % 251),
      );
      final entry = ArchiveFile('d.bin', data.length, data)
        ..compression = CompressionType.deflate;
      final archive = Archive()..addFile(entry);
      final zipBytes = ZipEncoder().encode(archive) as Uint8List;
      final file = ZipDecoder().decodeBytes(zipBytes).find('d.bin')!;
      final cache = <ArchiveFile, List<int>>{};
      final first = EpubIsolateWorker.fileBytesForTest(file, bytesCache: cache);
      final second = EpubIsolateWorker.fileBytesForTest(
        file,
        bytesCache: cache,
      );
      expect(first, data);
      expect(
        identical(first, second),
        isTrue,
        reason: 'P-#44: CRC verification and repair share one inflation',
      );
      // Without a cache each call inflates anew.
      final third = EpubIsolateWorker.fileBytesForTest(file);
      expect(third, data);
      expect(identical(first, third), isFalse);
    });
  });

  group('controller', _r12ControllerTests);
  group('history', () {
    _r12HistoryTests();
    _r12HistoryTests2();
  });
  group('inspector', _r12InspectorTests);
  group('extractor', _r12ExtractorTests);
}

// ---------------------------------------------------------------------------
// Controller tests: P1-#3, P2-#18, P2-#19, P2-#20, P2-#25, P2-#26.
// ---------------------------------------------------------------------------

InspectedChapter _r12Chapter(
  String path, {
  bool include = true,
  int blocks = 60,
}) => InspectedChapter(
  path: path,
  title: path,
  body: '',
  originalHtml: '<p>Source book text</p>',
  blocks: List<ExtractedBlock>.generate(
    blocks,
    (index) => ExtractedBlock(
      id: 'block-$index',
      tagName: 'p',
      sourceHtml: 'source $index',
      sourceText: 'source $index',
    ),
  ),
  category: ChapterCategory.content,
  recommendedForTranslation: true,
  includeInTranslation: include,
);

InspectedChapter _r12Released(InspectedChapter chapter) => chapter.copyWith(
  originalHtml: '',
  body: '',
  blocks: [
    for (final block in chapter.blocks)
      block.copyWith(sourceHtml: '', sourceText: ''),
  ],
);

/// Configurable repository double for the round-12 controller tests.
class _R12Repository implements TranslationRepository {
  _R12Repository({List<InspectedChapter>? inspectionChapters})
    : inspectionChapters = inspectionChapters ?? [_r12Chapter('chapter.xhtml')];

  final List<InspectedChapter> inspectionChapters;
  static const TranslationJobStatus terminalStatus =
      TranslationJobStatus.completed;
  static const bool releaseTerminalSources = true;

  final List<TranslationProgressCallback?> progressCallbacks = [];
  int translateCalls = 0;
  int inspectCalls = 0;
  Future<void> Function()? afterSourcesReleased;

  TranslationJob _job(String id, String inputPath, String outputPath) =>
      TranslationJob(
        id: id,
        inputPath: inputPath,
        outputPath: outputPath,
        status: TranslationJobStatus.inspected,
        progress: 1,
        totalBlocks: 60,
      );

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    inspectCalls += 1;
    return InspectionResult(
      job: _job('inspect$inspectCalls', inputPath, outputDirectory),
      chapters: inspectionChapters,
    );
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
    void Function(String chapterPath)? onChapterSourcesReleased,
  }) async {
    translateCalls += 1;
    final runId = 'run$translateCalls';
    progressCallbacks.add(onProgress);
    if (afterSourcesReleased != null) {
      onChapterSourcesReleased?.call(inspectionChapters.first.path);
      await afterSourcesReleased!();
    }
    final running = _job(
      runId,
      inputPath,
      '$outputDirectory/book.epub',
    ).copyWith(status: TranslationJobStatus.running);
    onProgress?.call(running, 'run $translateCalls running');
    final terminalChapters = releaseTerminalSources
        ? [
            for (final chapter in chapters)
              chapter.includeInTranslation ? _r12Released(chapter) : chapter,
          ]
        : chapters;
    return TranslationRunResult(
      job: running.copyWith(status: terminalStatus),
      chapters: terminalChapters,
    );
  }

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<String> testConnection({required TranslationConfig config}) async =>
      'OK';

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async => TranslationStyleProfile.empty;
}

TranslationDashboardController _r12Controller({
  _R12Repository? repository,
  JobHistoryStore? historyStore,
}) {
  final controller = TranslationDashboardController(
    repository: repository ?? _R12Repository(),
    historyStore: historyStore,
  );
  addTearDown(controller.dispose);
  controller.syncSettings(
    TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
  );
  controller.setInputPath('/books/book.epub');
  controller.setOutputDirectory('/output');
  return controller;
}

void _r12ControllerTests() {
  test('P1-#3 stale run progress cannot overwrite a newer run', () async {
    final repository = _R12Repository();
    final controller = _r12Controller(repository: repository);
    await controller.startInspection();

    // Run 1 completes; capture its progress callback.
    expect(await controller.startTranslation(), isTrue);
    expect(repository.translateCalls, 1);
    final staleProgress = repository.progressCallbacks.single;
    final run1JobId = controller.state.job!.id;

    // Run 2 starts. While it is active, run 1's wind-down emits again
    // (terminal emit + post-saveJobState emits racing the new run).
    final run2 = controller.startTranslation();
    while (repository.translateCalls < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    final run2JobId = controller.state.job!.id;
    staleProgress?.call(
      TranslationJob(
        id: 'run1-stale',
        inputPath: '/books/book.epub',
        outputPath: '/output/book.epub',
        status: TranslationJobStatus.completed,
        progress: 1,
        totalBlocks: 60,
      ),
      'stale wind-down emit',
    );
    await Future<void>.delayed(Duration.zero);
    // The stale emit is dropped: the new run's state survives.
    expect(run1JobId, isNot('run1-stale'));
    expect(controller.state.job!.id, run2JobId);
    expect(await run2, isTrue);
  });

  test('P2-#18 post-terminal chunk change rescales from the anchor', () async {
    final controller = _r12Controller();
    await controller.startInspection();
    final frozen = controller.debugStaticEstimateCache!;
    expect(frozen.estimatedSourceChars, greaterThan(0));

    expect(await controller.startTranslation(), isTrue);
    final oldChunkSize = controller.state.config.chunkSize;

    // The first post-terminal chunk-size change must rescale the batch
    // count from the anchor — not keep the stale count (the pre-fix P2-#7
    // "selection changed" branch) and not zero the totals.
    controller.syncSettings(controller.state.config.copyWith(chunkSize: 200));
    final updated = controller.debugStaticEstimateCache!;
    expect(
      updated.estimatedApiBatches,
      max(1, (frozen.estimatedApiBatches * oldChunkSize / 200).ceil()),
    );
    expect(updated.estimatedSourceChars, frozen.estimatedSourceChars);
    expect(updated.estimatedInputTokens, frozen.estimatedInputTokens);
    expect(updated.selectedChapters, frozen.selectedChapters);
    expect(updated.totalBlocks, frozen.totalBlocks);
  });

  test(
    'P2-#19 unselected chapters with sources do not un-freeze the estimate',
    () async {
      final repository = _R12Repository(
        inspectionChapters: [
          _r12Chapter('ch1.xhtml', include: true),
          _r12Chapter('ch2.xhtml', include: false),
        ],
      );
      final controller = _r12Controller(repository: repository);
      await controller.startInspection();
      final frozen = controller.debugStaticEstimateCache!;
      final frozenChunkSize = controller.state.config.chunkSize;
      expect(frozen.estimatedSourceChars, greaterThan(0));

      // Terminal: ch1 released, ch2 (unselected) keeps its sources — the
      // real worker never touches unselected chapters.
      expect(await controller.startTranslation(), isTrue);
      final terminal = controller.state.inspectedChapters;
      expect(
        terminal
            .firstWhere((c) => c.path == 'ch1.xhtml')
            .blocks
            .every((b) => b.sourceText.isEmpty),
        isTrue,
      );
      expect(
        terminal
            .firstWhere((c) => c.path == 'ch2.xhtml')
            .blocks
            .every((b) => b.sourceText.isNotEmpty),
        isTrue,
      );

      controller.syncSettings(controller.state.config.copyWith(chunkSize: 200));
      final updated = controller.debugStaticEstimateCache!;
      // Frozen totals preserved, batches rescaled — not rebuilt to zeros.
      expect(updated.estimatedSourceChars, frozen.estimatedSourceChars);
      expect(updated.estimatedInputTokens, frozen.estimatedInputTokens);
      final oldChunkSize = frozenChunkSize;
      expect(
        updated.estimatedApiBatches,
        max(1, (frozen.estimatedApiBatches * oldChunkSize / 200).ceil()),
      );
    },
  );

  test('P2-#20 batch count always scales from the anchor', () async {
    final repository = _R12Repository();
    final controller = _r12Controller(repository: repository);
    controller.syncSettings(controller.state.config.copyWith(chunkSize: 6000));
    await controller.startInspection();
    final frozen = controller.debugStaticEstimateCache!;
    expect(frozen.estimatedApiBatches, greaterThan(0));

    // Release the sources mid-run, then move the chunk size around.
    final entered = Completer<void>();
    final resume = Completer<void>();
    repository.afterSourcesReleased = () async {
      entered.complete();
      await resume.future;
    };
    final translating = controller.startTranslation();
    await entered.future;
    try {
      controller.syncSettings(
        controller.state.config.copyWith(chunkSize: 4000),
      );
      expect(
        controller.debugStaticEstimateCache!.estimatedApiBatches,
        max(1, (frozen.estimatedApiBatches * 6000 / 4000).ceil()),
      );
      // Back to the anchor: the chained pre-fix math gave 1 -> 2 -> 2;
      // scaling from the anchor always recovers the original count.
      controller.syncSettings(
        controller.state.config.copyWith(chunkSize: 6000),
      );
      expect(
        controller.debugStaticEstimateCache!.estimatedApiBatches,
        frozen.estimatedApiBatches,
      );
    } finally {
      resume.complete();
      await translating;
    }
  });
}

// ---------------------------------------------------------------------------
// P2-#25: a refused save drops only the snapshot's entries.
// ---------------------------------------------------------------------------

TranslationJob _r12Job(String id, {int runStartedAt = 0}) => TranslationJob(
  id: id,
  inputPath: '/books/$id.epub',
  outputPath: '/output/$id.epub',
  status: TranslationJobStatus.completed,
  progress: 1,
  totalBlocks: 10,
  runStartedAt: runStartedAt,
);

/// Simulates another instance clearing the history while our save is in
/// flight: the first saveMerged blocks on [release], then reports the write
/// refused with a fresh tombstone.
class _TombstoneStore extends JobHistoryStore {
  _TombstoneStore({required this.jobsToLoad});

  final List<TranslationJob> jobsToLoad;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool failNextWrite = true;

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: jobsToLoad, clearedAt: 0);

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    if (failNextWrite) {
      failNextWrite = false;
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return (
        written: false,
        fileClearedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return (written: true, fileClearedAt: 0);
  }
}

/// Captures the clear's merge callback so the test can check which jobs the
/// deletion watermark covers.
class _WatermarkProbeStore extends JobHistoryStore {
  _WatermarkProbeStore({required this.jobsToLoad});

  final List<TranslationJob> jobsToLoad;
  final loadGate = Completer<void>();
  List<TranslationJob> Function(List<TranslationJob>, int)? capturedMerge;

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async {
    await loadGate.future;
    return (jobs: jobsToLoad, clearedAt: 0);
  }

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    capturedMerge = merge;
    return (written: true, fileClearedAt: clearedAtEpochMs);
  }
}

void _r12HistoryTests() {
  test(
    'P2-#25 tombstone during save keeps jobs appended while saving',
    () async {
      final store = _TombstoneStore(jobsToLoad: [_r12Job('jobA')]);
      final repository = _R12Repository();
      final controller = _r12Controller(
        repository: repository,
        historyStore: store,
      );
      await controller.startInspection();

      // Start a persist pass: it snapshots the current history and blocks
      // in saveMerged.
      final save = controller.debugPersistJobHistoryNow();
      await store.entered.future;
      final snapshotIds = controller.state.jobHistory
          .map((job) => job.id)
          .toSet();

      // While the save is in flight, a new inspection appends a fresh job
      // (a distinct history id the snapshot does not contain).
      controller.setInputPath('/books/other.epub');
      await controller.startInspection();
      final appendedId = controller.state.job!.id;
      expect(snapshotIds.contains(appendedId), isFalse);

      // The refused save lands: only the snapshot's entries are dropped.
      store.release.complete();
      await save;
      // Settle the chained persist passes.
      await controller.debugPersistJobHistoryNow();

      final ids = controller.state.jobHistory.map((job) => job.id).toSet();
      expect(ids, contains(appendedId));
      for (final snapshotId in snapshotIds) {
        expect(ids, isNot(contains(snapshotId)));
      }
    },
  );
}

void _r12HistoryTests2() {
  test('P2-#26 clearJobHistory waits for the initial history load', () async {
    // Clock-rollback shape: the stored job's timestamp is an hour in the
    // future relative to the clear instant. A watermark derived before the
    // load completes would leave it uncovered ("leaked" past the clear).
    final futureUs =
        DateTime.now().microsecondsSinceEpoch +
        const Duration(hours: 1).inMicroseconds;
    final store = _WatermarkProbeStore(
      jobsToLoad: [_r12Job('jobOld', runStartedAt: futureUs)],
    );
    final controller = _r12Controller(historyStore: store);
    // The initial load is still gated; clear now.
    final cleared = controller.clearJobHistory();
    // Give the (unfixed) synchronous watermark derivation a chance to run
    // before releasing the load: without the fix the watermark is already
    // frozen here; with the fix the clear is still awaiting the load.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    store.loadGate.complete();
    expect(await cleared, isTrue);

    final merge = store.capturedMerge;
    expect(merge, isNotNull);
    expect(
      merge!([_r12Job('jobOld', runStartedAt: futureUs)], 0),
      isEmpty,
      reason:
          'P2-#26: the watermark must be derived after the initial load '
          'observed the stored job, or a clock rollback leaks it past the clear',
    );
    expect(controller.state.jobHistory, isEmpty);
  });
}

// ---------------------------------------------------------------------------
// P2-#21: manifest matching is namespace- and parent-qualified.
// ---------------------------------------------------------------------------
void _r12InspectorTests() {
  test('P2-#21 foreign-namespace items cannot shadow manifest chapters', () {
    const opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title><dc:identifier id="uid">u</dc:identifier><dc:language>en</dc:language></metadata>
<manifest>
<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
<foreign><item xmlns="http://example.com/evil" id="ch1" href="evil.xhtml"/></foreign>
</manifest>
<spine><itemref idref="ch1"/></spine>
</package>''';
    // The pre-fix lookup walked all descendants by local name: the later
    // foreign item overwrote the real manifest entry (last-wins).
    final result = EpubInspector.chapterPathsFromOpfBytes(
      files: {'OEBPS/content.opf': utf8.encode(opf)},
      opfPath: 'OEBPS/content.opf',
    );
    expect(result.chapterPaths, ['OEBPS/ch1.xhtml']);
    expect(result.unresolvedIdRefs, isEmpty);
  });

  test('P-#47 inspectionEntryPaths shares one OPF parse', () {
    const opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title><dc:identifier id="uid">u</dc:identifier><dc:language>en</dc:language></metadata>
<manifest>
<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
</manifest>
<spine toc="ncx"><itemref idref="ch1"/></spine>
</package>''';
    final files = {'OEBPS/content.opf': utf8.encode(opf)};
    // Spine chapters, the NCX and the nav doc resolve from the shared
    // single parse (previously each re-parsed the OPF).
    expect(EpubInspector.inspectionEntryPaths(files, 'OEBPS/content.opf'), {
      'OEBPS/ch1.xhtml',
      'OEBPS/toc.ncx',
      'OEBPS/nav.xhtml',
    });
  });

  test(
    'P2-#24 cancel after the 0.1 progress surfaces as cancellation',
    () async {
      final dir = await Directory.systemTemp.createTemp('r12_p2_24_');
      addTearDown(() => dir.delete(recursive: true));
      final epubPath = await _writeTestEpub(
        dir,
        'empty.epub',
        chapters: {},
        emptySpine: true,
      );
      final token = CancelToken();
      final inspector = EpubInspector();
      await expectLater(
        inspector.inspect(
          inputPath: epubPath,
          outputDirectory: dir.path,
          cancelToken: token,
          onProgress: (job, line) {
            if (job.progress >= 0.1) token.cancel();
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
        reason:
            'P2-#24: a cancel landing after the progress callback must not '
            'degrade into a "no chapters" failure',
      );
    },
  );

  test('P2-#24 empty spine without cancel still reports failure', () async {
    final dir = await Directory.systemTemp.createTemp('r12_p2_24b_');
    addTearDown(() => dir.delete(recursive: true));
    final epubPath = await _writeTestEpub(
      dir,
      'empty.epub',
      chapters: {},
      emptySpine: true,
    );
    final result = await EpubInspector().inspect(
      inputPath: epubPath,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
    );
    expect(result.job.status, TranslationJobStatus.failed);
    expect(result.chapters, isEmpty);
  });

  test('P-#49 multi-batch inspection returns every chapter', () async {
    final dir = await Directory.systemTemp.createTemp('r12_p49_');
    addTearDown(() => dir.delete(recursive: true));
    // Six chapters force two batches (batch size 4): dropping processed
    // bytes must not lose chapters from later batches.
    final epubPath = await _writeTestEpub(
      dir,
      'six.epub',
      chapters: {for (int i = 1; i <= 6; i++) 'c$i.xhtml': 100},
    );
    final result = await EpubInspector().inspect(
      inputPath: epubPath,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
    );
    expect(result.job.status, TranslationJobStatus.inspected);
    expect(result.chapters.map((c) => c.path).toSet(), {
      for (int i = 1; i <= 6; i++) 'OEBPS/c$i.xhtml',
    });
    expect(result.warnings.where((w) => w.contains('missing')).isEmpty, isTrue);
  });
}

// ---------------------------------------------------------------------------
// P2-#22: tag matching strips namespace prefixes.
// P2-#23: DOM recursion has a depth cap.
// P-#48: author-signature detection scans siblings once.
// ---------------------------------------------------------------------------
void _r12ExtractorTests() {
  const extractor = EpubHtmlExtractor();

  test('P2-#22 prefixed XHTML elements match by stripped tag name', () {
    final document = html_parser.parse(
      '<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:head>'
      '<x:title>T</x:title></x:head><x:body>'
      '<x:p>one</x:p><x:blockquote>two</x:blockquote>'
      '</x:body></x:html>',
    );
    final elements = extractor.extractTranslatableElements(document);
    expect(elements.map((e) => e.text.trim()).toList(), ['one', 'two']);
    expect(extractor.elementText(elements.first), 'one');
  });

  test('P2-#22 title lookup works in prefixed documents', () {
    final document = html_parser.parse(
      '<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:head>'
      '<x:title>Prefixed Title</x:title></x:head>'
      '<x:body><x:p>Hi</x:p></x:body></x:html>',
    );
    final chapter = extractor.inspectChapterBytes(
      chapterPath: 'c.xhtml',
      bytes: utf8.encode(document.outerHtml),
    );
    expect(chapter.title, 'Prefixed Title');
  });

  test('P2-#23 pathological nesting degrades instead of overflowing', () {
    const depth = 50000;
    // Isolate the DOM guard from the parser's quadratic handling of extreme
    // nesting. The inspection entry-point has a separate pre-parser rejection.
    final document = html_parser.parse('<html><body></body></html>');
    final div = dom.Element.tag('div');
    document.body!.append(div);
    var parent = div;
    for (int i = 1; i < depth; i++) {
      final child = dom.Element.tag('div');
      parent.append(child);
      parent = child;
    }
    parent.append(dom.Text('deep'));
    // Extraction and text computation must return (degraded past the cap),
    // not throw a StackOverflowError.
    expect(
      () => extractor.extractTranslatableElements(document),
      returnsNormally,
    );
    expect(() => extractor.elementText(div), returnsNormally);
  });

  test('P-#48 signature detection still flags the author row', () {
    final document = html_parser.parse('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The translated preface prose ends here with a complete final sentence.</p>
  <p class="sig">Peter Thiel</p>
  <p class="sig">January 6, 2020</p>
  <p class="sig">Los Angeles</p>
</section>
</body></html>
''');
    final blocks = extractor.extractBlocks(
      document,
      chapterPath: 'preface.xhtml',
      detectAuthorSignatures: true,
    );
    final byText = {for (final block in blocks) block.sourceText: block};
    // The single-pass rewrite must not change detection outcomes.
    expect(byText['Peter Thiel']?.isAuthorSignature, isTrue);
    expect(byText['January 6, 2020']?.isAuthorSignature, isFalse);
    expect(byText['Los Angeles']?.isAuthorSignature, isFalse);
  });

  test('P-#48 many signature candidates complete without blowup', () {
    final buffer = StringBuffer('<html><body><section epub:type="preface">');
    for (int i = 0; i < 400; i++) {
      buffer.write('<p class="sig">Peter Thiel</p>');
    }
    buffer.write('</section></body></html>');
    final document = html_parser.parse(buffer.toString());
    final stopwatch = Stopwatch()..start();
    final blocks = extractor.extractBlocks(
      document,
      chapterPath: 'preface.xhtml',
      detectAuthorSignatures: true,
    );
    stopwatch.stop();
    expect(blocks, hasLength(400));
    // 400 candidates x 400 siblings with per-candidate sibling re-scans
    // would be far slower; the single-pass shape stays in the seconds.
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 20)),
      reason: 'P-#48: sibling texts are computed once per scan',
    );
  });
}
