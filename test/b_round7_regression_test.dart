import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/preview/application/preview_recovery.dart';
import 'package:epub_translator_flutter/features/preview/domain/models/preview_chapter.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _StubRepository implements TranslationRepository {
  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) => throw UnimplementedError();

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
  }) => throw UnimplementedError();

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<String> testConnection({required TranslationConfig config}) =>
      throw UnimplementedError();

  @override
  Future<void> cancelJob(String jobId) async {}
}

TranslationJob _job(
  String id, {
  int runStartedAt = 0,
  TranslationJobStatus status = TranslationJobStatus.failed,
}) => TranslationJob(
  id: id,
  inputPath: '/books/$id.epub',
  outputPath: '/output',
  status: status,
  progress: 0,
  runStartedAt: runStartedAt,
);

/// A [JobHistoryStore] whose [saveMerged] waits on [gate] when set, so tests
/// can deterministically interleave another instance's write between a
/// queued save and its execution.
class _GateHistoryStore extends JobHistoryStore {
  _GateHistoryStore(File file) : super(historyFileProvider: () async => file);

  Completer<void>? gate;

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    final Completer<void>? current = gate;
    if (current != null) {
      await current.future;
    }
    return super.saveMerged(merge: merge, clearedAtEpochMs: clearedAtEpochMs);
  }
}

/// Minimal ZIP writer that (unlike `Archive.add`) allows duplicate entry
/// names, so decoder behavior on degenerate archives can be exercised.
class _RawZipBuilder {
  final BytesBuilder _out = BytesBuilder();
  final List<_RawZipEntry> _entries = <_RawZipEntry>[];

  static List<int> _u16(int v) => <int>[v & 0xff, (v >> 8) & 0xff];
  static List<int> _u32(int v) => <int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  void add(String name, List<int> data) {
    final List<int> nameBytes = utf8.encode(name);
    final int crc = getCrc32(data);
    final int offset = _out.length;
    _out.add(_u32(0x04034b50));
    _out.add(_u16(20));
    _out.add(_u16(0)); // flags
    _out.add(_u16(0)); // method: stored
    _out.add(_u16(0));
    _out.add(_u16(0)); // time/date
    _out.add(_u32(crc));
    _out.add(_u32(data.length));
    _out.add(_u32(data.length));
    _out.add(_u16(nameBytes.length));
    _out.add(_u16(0)); // extra length
    _out.add(nameBytes);
    _out.add(data);
    _entries.add(_RawZipEntry(name, crc, data.length, offset));
  }

  Uint8List build() {
    final int cdOffset = _out.length;
    for (final _RawZipEntry entry in _entries) {
      final List<int> nameBytes = utf8.encode(entry.name);
      _out.add(_u32(0x02014b50));
      _out.add(_u16(63));
      _out.add(_u16(20));
      _out.add(_u16(0)); // flags
      _out.add(_u16(0)); // method: stored
      _out.add(_u16(0));
      _out.add(_u16(0)); // time/date
      _out.add(_u32(entry.crc));
      _out.add(_u32(entry.size));
      _out.add(_u32(entry.size));
      _out.add(_u16(nameBytes.length));
      _out.add(_u16(0)); // extra
      _out.add(_u16(0)); // comment
      _out.add(_u16(0)); // disk
      _out.add(_u16(0)); // internal attrs
      _out.add(_u32(0)); // external attrs
      _out.add(_u32(entry.offset));
      _out.add(nameBytes);
    }
    final int cdSize = _out.length - cdOffset;
    _out.add(_u32(0x06054b50));
    _out.add(_u16(0));
    _out.add(_u16(0)); // disk numbers
    _out.add(_u16(_entries.length));
    _out.add(_u16(_entries.length));
    _out.add(_u32(cdSize));
    _out.add(_u32(cdOffset));
    _out.add(_u16(0)); // comment length
    return _out.takeBytes();
  }
}

class _RawZipEntry {
  _RawZipEntry(this.name, this.crc, this.size, this.offset);
  final String name;
  final int crc;
  final int size;
  final int offset;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#28 duplicate entry names poison the reused CRC', () {
    test('storedCrcMatchesPayload detects the decoder mismatch', () {
      // Note: Archive.add dedupes by name, so the degenerate archive is
      // built raw. The decoder keeps the first duplicate's payload but
      // overwrites crc32 with the last duplicate's value.
      final _RawZipBuilder builder = _RawZipBuilder()
        ..add('dup.xhtml', utf8.encode('first payload'))
        ..add('dup.xhtml', utf8.encode('second payload'))
        ..add('unique.xhtml', utf8.encode('unique'));
      final Archive decoded = ZipDecoder().decodeBytes(builder.build());
      final ArchiveFile dup = decoded.find('dup.xhtml')!;
      expect(utf8.decode(dup.content), 'first payload');
      expect(EpubIsolateWorker.storedCrcMatchesPayloadForTest(dup), isFalse);
      final ArchiveFile unique = decoded.find('unique.xhtml')!;
      expect(EpubIsolateWorker.storedCrcMatchesPayloadForTest(unique), isTrue);
    });

    test('repacked output carries valid CRCs for duplicate entries', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'b7_dup_crc_',
      );
      addTearDown(() => dir.delete(recursive: true));
      // Minimal EPUB with a duplicate entry name (degenerate but seen in
      // the wild); the duplicate is not a translated chapter.
      final _RawZipBuilder builder = _RawZipBuilder()
        ..add('mimetype', utf8.encode('application/epub+zip'))
        ..add(
          'META-INF/container.xml',
          utf8.encode(
            '<container><rootfile full-path="OPS/book.opf"/></container>',
          ),
        )
        ..add(
          'OPS/book.opf',
          utf8.encode(
            '<package xmlns="http://www.idpf.org/2007/opf"><metadata/>'
            '<manifest><item id="c0" href="c0.xhtml" '
            'media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="c0"/></spine></package>',
          ),
        )
        ..add(
          'OPS/c0.xhtml',
          utf8.encode('<html><body><p>Hello.</p></body></html>'),
        )
        ..add('OPS/dup.css', utf8.encode('p{color:red}'))
        ..add('OPS/dup.css', utf8.encode('p{color:blue}'));

      final File input = File(path.join(dir.path, 'in.epub'))
        ..writeAsBytesSync(builder.build());
      final String output = path.join(dir.path, 'out.epub');
      expect(
        await EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output,
          translatedHtmlByPath: const <String, String>{},
        ),
        isTrue,
      );
      final Archive repacked = ZipDecoder().decodeBytes(
        File(output).readAsBytesSync(),
      );
      for (final ArchiveFile file in repacked) {
        if (!file.isFile) continue;
        final int? stored = file.crc32;
        expect(stored, isNotNull, reason: 'CRC missing for ${file.name}');
        expect(
          getCrc32(file.content),
          stored,
          reason: 'CRC mismatch for ${file.name}',
        );
      }
    });
  });

  group('#46 chunked read keeps a single buffer', () {
    test('assembles chunks and enforces the limit', () {
      final List<List<int>> chunks = <List<int>>[
        List<int>.filled(70000, 1),
        List<int>.filled(70000, 2),
        List<int>.filled(1000, 3),
      ];
      int next = 0;
      final Uint8List bytes = EpubIsolateWorker.readChunksGuardedForTest(
        inputPath: 'in.epub',
        nextChunk: () => next < chunks.length ? chunks[next++] : <int>[],
        limitBytes: 256 * 1024 * 1024,
      );
      expect(bytes.length, 141000);
      expect(bytes.sublist(0, 70000).every((b) => b == 1), isTrue);
      expect(bytes.sublist(70000, 140000).every((b) => b == 2), isTrue);
      expect(bytes.sublist(140000).every((b) => b == 3), isTrue);

      int over = 0;
      expect(
        () => EpubIsolateWorker.readChunksGuardedForTest(
          inputPath: 'in.epub',
          nextChunk: () => over++ == 0 ? List<int>.filled(11, 0) : <int>[],
          limitBytes: 10,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );

      // Empty input yields an empty buffer without throwing.
      expect(
        EpubIsolateWorker.readChunksGuardedForTest(
          inputPath: 'in.epub',
          nextChunk: () => <int>[],
          limitBytes: 10,
        ),
        isEmpty,
      );
    });
  });

  group('#49 recovery spares are budgeted and reclaimed', () {
    test('preserve enforces the count budget oldest-first', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'b7_recovery_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File finalFile = File(path.join(dir.path, 'book.epub'));
      for (int i = 0; i < 7; i++) {
        final File temp = File(path.join(dir.path, 't$i.tmp'))
          ..writeAsStringSync('payload $i');
        await EpubIsolateWorker.preserveRecoveryTempForTest(temp, finalFile);
        // Distinct microsecond timestamps order the spares chronologically.
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final List<File> spares = dir
          .listSync()
          .whereType<File>()
          .where((f) => path.basename(f.path).contains('.recovery.'))
          .toList();
      expect(spares.length, lessThanOrEqualTo(5));
      expect(spares.length, greaterThan(0));
    });

    test('successful commit reclaims recovery spares', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'b7_reclaim_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File finalFile = File(path.join(dir.path, 'book.epub'))
        ..writeAsStringSync('old');
      final File tempFile = File(path.join(dir.path, 'book.epub.tmp.1'))
        ..writeAsStringSync('new');
      for (int i = 0; i < 3; i++) {
        File('${finalFile.path}.recovery.$i').writeAsStringSync('spare $i');
      }
      expect(
        await EpubIsolateWorker.commitTempFile(tempFile, finalFile),
        isTrue,
      );
      expect(finalFile.readAsStringSync(), 'new');
      expect(
        dir.listSync().where((e) => e.path.contains('.recovery.')),
        isEmpty,
      );
    });
  });

  group('#29 clear watermark semantics', () {
    test('predicate uses strict microsecond comparison', () {
      const int clearUs = 1700000000000500;
      // Same millisecond, before the clear instant: deleted.
      expect(
        TranslationDashboardController.isJobNewerThanClearUsForTest(
          _job('a', runStartedAt: 1700000000000400),
          clearUs,
        ),
        isFalse,
      );
      // Same millisecond, after the clear instant: preserved.
      expect(
        TranslationDashboardController.isJobNewerThanClearUsForTest(
          _job('b', runStartedAt: 1700000000000600),
          clearUs,
        ),
        isTrue,
      );
      // Exactly at the watermark: not newer.
      expect(
        TranslationDashboardController.isJobNewerThanClearUsForTest(
          _job('c', runStartedAt: clearUs),
          clearUs,
        ),
        isFalse,
      );
    });

    test('runStartedAt=0 inspection jobs are ordered by ID creation time', () {
      const int clearUs = 1700000000000000;
      // Fresh inspection job (ID carries wall-ms after the clear).
      final String freshId = '${clearUs ~/ 1000 + 5000}-1';
      expect(
        TranslationDashboardController.isJobNewerThanClearUsForTest(
          _job(freshId),
          clearUs,
        ),
        isTrue,
      );
      // Legacy zero-timestamp row (no parsable ID prefix).
      expect(
        TranslationDashboardController.isJobNewerThanClearUsForTest(
          _job('legacy'),
          clearUs,
        ),
        isFalse,
      );
      // Old inspection job created before the clear.
      final String oldId = '${clearUs ~/ 1000 - 5000}-1';
      expect(
        TranslationDashboardController.isJobNewerThanClearUsForTest(
          _job(oldId),
          clearUs,
        ),
        isFalse,
      );
    });

    test(
      'clear preserves a fresh inspection job from another instance',
      () async {
        final Directory dir = await Directory.systemTemp.createTemp(
          'b7_clear_inspect_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final File file = File(path.join(dir.path, 'history.json'));
        final JobHistoryStore plain = JobHistoryStore(
          historyFileProvider: () async => file,
        );
        await plain.save(<TranslationJob>[_job('old', runStartedAt: 1)]);
        final _GateHistoryStore store = _GateHistoryStore(file);
        final controller = TranslationDashboardController(
          repository: _StubRepository(),
          historyStore: store,
        );
        addTearDown(controller.debugDispose);
        await controller.debugPersistJobHistoryNow();

        // Stall the clear's save inside the store so another instance's write
        // deterministically lands first (plain.save takes no lock).
        store.gate = Completer<void>();
        final Future<bool> clearing = controller.clearJobHistory();
        // Another instance inspects a book after our clear began: the job has
        // runStartedAt == 0 and a fresh ID. The microsecond watermark cannot
        // order it, so the ID creation time must protect it.
        final int futureMs = DateTime.now().millisecondsSinceEpoch + 60000;
        await plain.save(<TranslationJob>[
          _job('$futureMs-7'),
          _job('old', runStartedAt: 1),
        ]);
        store.gate!.complete();
        expect(await clearing, isTrue);
        final List<String> ids = (await plain.load()).map((j) => j.id).toList();
        expect(ids, contains('$futureMs-7'));
        expect(ids, isNot(contains('old')));
      },
    );
  });

  group('#30 ordinary save queued across a clear', () {
    test(
      'preserves another instance\'s late job instead of wiping it',
      () async {
        final Directory dir = await Directory.systemTemp.createTemp(
          'b7_clear_race_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final File file = File(path.join(dir.path, 'history.json'));
        final JobHistoryStore plain = JobHistoryStore(
          historyFileProvider: () async => file,
        );
        await plain.save(<TranslationJob>[_job('old', runStartedAt: 1)]);
        final _GateHistoryStore store = _GateHistoryStore(file);
        final controller = TranslationDashboardController(
          repository: _StubRepository(),
          historyStore: store,
        );
        addTearDown(controller.debugDispose);
        // Hydrate so memory holds the old job.
        await controller.debugPersistJobHistoryNow();
        expect(controller.state.jobHistory.map((j) => j.id), contains('old'));

        // Queue an ordinary save, then stall it inside the store.
        store.gate = Completer<void>();
        final Future<void> queued = controller.debugPersistJobHistoryNow();
        // The clear runs while the ordinary save is stalled: memory is
        // emptied and the clear's save queues behind it.
        final Future<bool> clearing = controller.clearJobHistory();
        // Another instance appends a job after our clear began.
        final int futureUs =
            DateTime.now().microsecondsSinceEpoch + 3600 * 1000000;
        await plain.save(<TranslationJob>[
          _job('job-new', runStartedAt: futureUs),
        ]);
        store.gate!.complete();
        await queued;
        expect(await clearing, isTrue);

        final List<String> ids = (await plain.load()).map((j) => j.id).toList();
        expect(ids, contains('job-new'));
        expect(ids, isNot(contains('old')));
      },
    );
  });

  group('#31 history sort unifies time units', () {
    test('a fresh inspection record outranks an older translation record', () {
      // runStartedAt is microseconds; the ID prefix is wall milliseconds.
      final TranslationJob oldTranslation = _job(
        't1',
        runStartedAt: 1000 * 1000,
      );
      final TranslationJob newInspection = _job('2000-1');
      final List<TranslationJob> sorted =
          TranslationDashboardController.mergeHistorySnapshotsForTest(
            <TranslationJob>[oldTranslation],
            <TranslationJob>[newInspection],
          );
      // With mixed units the 2000ms key would sort below the 1000000µs key
      // and the new record would be truncated by the 20-item cap.
      expect(sorted.first.id, '2000-1');
    });
  });

  group('#32 class attribute boundary', () {
    test('ignores class= inside another attribute value', () {
      final EpubRepacker repacker = EpubRepacker();
      expect(
        repacker.debugHasTocClassToken('<p title="class=\'toc\'">x</p>'),
        isFalse,
      );
      expect(
        repacker.debugHasTocClassToken('<p title=\'class="toc"\'>x</p>'),
        isFalse,
      );
      expect(
        repacker.debugHasTocClassToken('<div class="toc">x</div>'),
        isTrue,
      );
      expect(
        repacker.debugHasTocClassToken('<div class=\'toc entry\'>x</div>'),
        isTrue,
      );
      expect(
        repacker.debugHasTocClassToken('<div data-class="toc">x</div>'),
        isFalse,
      );
      expect(
        repacker.debugHasTocClassToken('<div class="toc-entry">x</div>'),
        isFalse,
      );
      expect(
        repacker.debugHasTocClassToken('<DIV CLASS="toc">x</DIV>'),
        isTrue,
      );
      expect(
        repacker.debugHasTocClassToken('<p title="a>b" class="toc">x</p>'),
        isTrue,
      );
      expect(repacker.debugHasTocClassToken('<div class=toc>x</div>'), isTrue);
    });
  });

  group('#47 share no-space mapping', () {
    test('SHARE_NO_SPACE maps to the localized notice', () async {
      final Directory dir = await Directory.systemTemp.createTemp('b7_share_');
      addTearDown(() => dir.delete(recursive: true));
      final controller = TranslationDashboardController(
        repository: _StubRepository(),
        historyStore: JobHistoryStore(
          historyFileProvider: () async =>
              File(path.join(dir.path, 'history.json')),
        ),
      );
      addTearDown(controller.debugDispose);
      final PlatformException noSpace = PlatformException(
        code: 'SHARE_NO_SPACE',
        message: 'Not enough free space',
      );
      expect(
        controller.debugShareErrorLogLine(noSpace),
        isNot(contains('Not enough free space')),
      );
      final PlatformException other = PlatformException(
        code: 'SHARE_FAILED',
        message: 'boom',
      );
      expect(controller.debugShareErrorLogLine(other), contains('boom'));
      expect(
        controller.debugOpenJobOutputErrorLogLine(noSpace),
        controller.debugShareErrorLogLine(noSpace),
      );
    });
  });

  group('#50 recovery failure surfaces with retry', () {
    InspectedChapter chapterNeedingRecovery() => InspectedChapter(
      path: 'c0.xhtml',
      title: 'Chapter',
      body: 'source body',
      originalHtml: '',
      blocks: const <ExtractedBlock>[
        ExtractedBlock(
          id: 'b1',
          tagName: 'p',
          sourceHtml: '<p>source</p>',
          sourceText: 'source',
          translatedHtml: '<p>translated</p>',
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );

    test('failure surfaces through prepare and a later prepare retries',
        () async {
      int calls = 0;
      final PreviewRecoveryCache cache = PreviewRecoveryCache(
        runner: (List<InspectedChapter> chapters) async {
          calls++;
          if (calls == 1) {
            throw StateError('isolate died');
          }
          return chapters
              .map(
                (c) => PreviewChapter(
                  title: c.title,
                  body: 'recovered',
                  path: c.path,
                  category: '',
                  recommendedForTranslation: false,
                  includeInTranslation: false,
                  blockCount: 1,
                  translatedBlockCount: 1,
                ),
              )
              .toList();
        },
      );
      final InspectedChapter chapter = chapterNeedingRecovery();
      expect(needsPreviewRecovery(chapter), isTrue);

      await expectLater(
        cache.prepare(<InspectedChapter>[chapter]),
        throwsStateError,
      );
      // Failed entries are dropped, so the UI must not project stale data.
      // (The failure itself surfaces through the provider's AsyncValue, not
      // a cache field.)
      expect(cache.lookup(chapter), isNull);

      // Retry re-runs the runner.
      await cache.prepare(<InspectedChapter>[chapter]);
      expect(calls, 2);
      expect(cache.lookup(chapter), isNotNull);
      expect(cache.lookup(chapter)!.body, 'recovered');
    });
  });
}
