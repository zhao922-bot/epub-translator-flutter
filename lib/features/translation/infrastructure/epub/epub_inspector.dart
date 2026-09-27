import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../../../../shared/logging/app_logger.dart';
import '../../domain/models/inspection_result.dart';
import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub_isolate_worker.dart';
import 'epub_html_extractor.dart';
import 'epub_text_decoder.dart';

/// Loads an EPUB (via isolate) and extracts chapter/block inventory.
class EpubInspector {
  EpubInspector({EpubHtmlExtractor? extractor})
    : _extractor = extractor ?? const EpubHtmlExtractor();

  final EpubHtmlExtractor _extractor;

  Future<InspectionResult> inspect({
    required String inputPath,
    required String outputDirectory,
    required CancelToken cancelToken,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final Stopwatch inspectionStopwatch = Stopwatch()..start();
    final String jobId = DateTime.now().millisecondsSinceEpoch.toString();
    TranslationJob currentJob = TranslationJob(
      id: jobId,
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.inspection,
      progress: 0,
      currentChapter: 'Opening archive',
      completedFiles: 0,
      totalFiles: 0,
      completedBlocks: 0,
      totalBlocks: 0,
      cachedBlocks: 0,
      resumedBlocks: 0,
    );

    void emit(TranslationJob job, String logLine) {
      currentJob = job;
      onProgress?.call(job, logLine);
      AppLogger.debug(logLine, tag: 'inspect');
    }

    void throwIfCancelled() {
      if (cancelToken.isCancelled || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
    }

    emit(currentJob, 'Opening EPUB: ${path.basename(inputPath)}');
    throwIfCancelled();

    final Map<String, List<int>> files = await openArchiveFiles(inputPath);
    throwIfCancelled();

    final List<int>? containerBytes = files['META-INF/container.xml'];
    if (containerBytes == null) {
      throw const FormatException(
        'Invalid EPUB: META-INF/container.xml is missing.',
      );
    }

    final XmlDocument containerDocument = XmlDocument.parse(
      decodeEpubText(
        bytes: containerBytes,
        filePath: 'META-INF/container.xml',
        strict: true,
      ),
    );
    final XmlElement? rootFile = containerDocument.descendants
        .whereType<XmlElement>()
        .cast<XmlElement?>()
        .firstWhere(
          (XmlElement? element) => element?.name.local == 'rootfile',
          orElse: () => null,
        );
    if (rootFile == null) {
      throw const FormatException(
        'Invalid EPUB: META-INF/container.xml is missing a rootfile entry.',
      );
    }
    final String? opfPath = rootFile.getAttribute('full-path');
    if (opfPath == null || opfPath.isEmpty) {
      throw const FormatException(
        'Invalid EPUB: package document path is empty.',
      );
    }

    emit(
      currentJob.copyWith(
        progress: 0.1,
        currentChapter: path.basename(opfPath),
      ),
      'Located package document: $opfPath',
    );

    final ({List<String> chapterPaths, List<String> unresolvedIdRefs})
    spine = chapterPathsFromOpfBytes(files: files, opfPath: opfPath);
    final List<String> chapterPaths = spine.chapterPaths;

    if (chapterPaths.isEmpty) {
      emit(
        currentJob.copyWith(
          status: TranslationJobStatus.failed,
          progress: 1,
          currentChapter: 'No chapters found',
        ),
        'No spine HTML/XHTML chapters were found in the EPUB.',
      );
      return InspectionResult(
        job: currentJob,
        chapters: const <InspectedChapter>[],
        warnings: <String>[
          for (final String idRef in spine.unresolvedIdRefs)
            'Spine itemref "$idRef" has no matching manifest item; skipped.',
        ],
      );
    }

    emit(
      currentJob.copyWith(
        progress: 0.2,
        currentChapter: 'Spine ready',
        totalFiles: chapterPaths.length,
      ),
      'Found ${chapterPaths.length} chapters in the spine.',
    );

    final List<InspectedChapter> chapters = <InspectedChapter>[];
    final List<String> missingChapterFiles = <String>[];
    int totalBlocks = 0;
    for (int index = 0; index < chapterPaths.length; index += 1) {
      throwIfCancelled();
      final String chapterPath = chapterPaths[index];
      final List<int>? chapterBytes = files[chapterPath];
      if (chapterBytes == null) {
        // A damaged EPUB may list spine entries whose files are absent from
        // the archive. Skip them but remember them for the completion
        // warning below; the remaining chapters are still translatable.
        missingChapterFiles.add(chapterPath);
        continue;
      }
      final InspectedChapter chapter = _extractor.inspectChapterBytes(
        chapterPath: chapterPath,
        bytes: chapterBytes,
      );
      chapters.add(chapter);
      totalBlocks += chapter.blocks.length;
      final double progress = (index + 1) / chapterPaths.length;
      final TranslationJob nextJob = currentJob.copyWith(
        progress: progress,
        currentChapter: path.basename(chapterPath),
        completedFiles: index + 1,
        totalFiles: chapterPaths.length,
        totalBlocks: totalBlocks,
        status: TranslationJobStatus.running,
      );
      emit(
        nextJob,
        'Indexed chapter ${index + 1}/${chapterPaths.length}: $chapterPath',
      );
    }

    final List<String> warnings = <String>[
      for (final String idRef in spine.unresolvedIdRefs)
        'Spine itemref "$idRef" has no matching manifest item; skipped.',
      for (final String missing in missingChapterFiles)
        'Chapter file missing from archive, skipped: $missing.',
    ];
    final TranslationJob inspectedJob = currentJob.copyWith(
      status: TranslationJobStatus.inspected,
      progress: 1,
      currentChapter: 'Ready for translation',
      completedFiles: chapterPaths.length,
      totalFiles: chapterPaths.length,
      totalBlocks: totalBlocks,
    );
    inspectionStopwatch.stop();
    emit(
      inspectedJob,
      'EPUB inspection complete. Preview now shows ${chapters.length} real chapters with a basic translation filter.',
    );
    if (warnings.isNotEmpty) {
      const int maxShown = 8;
      final String shown = warnings.take(maxShown).join(' ');
      final String overflow = warnings.length > maxShown
          ? ' (+${warnings.length - maxShown} more)'
          : '';
      AppLogger.warn(
        'Inspection skipped ${warnings.length} spine entr${warnings.length == 1 ? 'y' : 'ies'} '
        'with missing files: $shown$overflow',
        tag: 'inspect',
      );
      emit(
        inspectedJob,
        'Warning: skipped ${warnings.length} chapter(s) referenced by the spine '
        'but missing from the archive: $shown$overflow. '
        'The remaining chapters can still be translated. / '
        '警告：spine 引用的 ${warnings.length} 个章节文件在 EPUB 中缺失，已跳过：$shown$overflow。'
        '其余章节仍可正常翻译。',
      );
    }
    emit(
      inspectedJob,
      'Performance: EPUB inspection took ${_formatDuration(inspectionStopwatch.elapsed)} for ${chapters.length} chapters and $totalBlocks text blocks.',
    );
    return InspectionResult(
      job: inspectedJob,
      chapters: chapters,
      warnings: warnings,
    );
  }

  /// Public for stress tests and reuse by translator fingerprinting paths.
  static Future<Map<String, List<int>>> openArchiveFiles(
    String inputPath,
  ) async {
    final loaded = await EpubIsolateWorker.loadArchiveFiles(inputPath);
    return <String, List<int>>{
      for (final entry in loaded.entries)
        entry.key: List<int>.from(entry.value),
    };
  }

  /// Resolves spine itemrefs to archive paths. Returns both the resolved
  /// chapter paths and the idrefs that had no matching manifest item, so
  /// callers can warn about damaged books instead of silently dropping
  /// chapters.
  static ({List<String> chapterPaths, List<String> unresolvedIdRefs})
  chapterPathsFromOpfBytes({
    required Map<String, List<int>> files,
    required String opfPath,
  }) {
    final List<int>? opfBytes = files[opfPath];
    if (opfBytes == null) {
      throw FormatException(
        'Invalid EPUB: package document not found at $opfPath.',
      );
    }

    final XmlDocument opfDocument = XmlDocument.parse(
      decodeEpubText(bytes: opfBytes, filePath: opfPath, strict: true),
    );
    final String opfDirectory = path.posix.dirname(opfPath);

    final Map<String, String> manifest = <String, String>{};
    for (final XmlElement item
        in opfDocument.descendants.whereType<XmlElement>()) {
      if (item.name.local != 'item') {
        continue;
      }
      final String? id = item.getAttribute('id');
      final String? href = item.getAttribute('href');
      if (id == null || href == null) {
        continue;
      }
      manifest[id] = _resolveManifestHref(opfDirectory, href);
    }

    final List<String> chapterPaths = <String>[];
    final List<String> unresolvedIdRefs = <String>[];
    for (final XmlElement itemRef
        in opfDocument.descendants.whereType<XmlElement>()) {
      if (itemRef.name.local != 'itemref') {
        continue;
      }
      final String? idRef = itemRef.getAttribute('idref');
      final String? chapterPath = idRef == null ? null : manifest[idRef];
      if (chapterPath == null) {
        if (idRef != null) {
          unresolvedIdRefs.add(idRef);
        }
        continue;
      }
      if (_isHtmlDocument(chapterPath)) {
        chapterPaths.add(chapterPath);
      }
    }
    return (chapterPaths: chapterPaths, unresolvedIdRefs: unresolvedIdRefs);
  }

  static bool _isHtmlDocument(String filePath) {
    final String lower = filePath.toLowerCase();
    return lower.endsWith('.html') ||
        lower.endsWith('.xhtml') ||
        lower.endsWith('.htm');
  }

  static String _resolveManifestHref(String opfDirectory, String href) {
    final String hrefPath = href.split('#').first.split('?').first;
    String decodedHref;
    try {
      decodedHref = Uri.decodeFull(hrefPath);
    } catch (_) {
      // A literal '%' (e.g. "100%.xhtml") is not a valid escape sequence;
      // keep the original href instead of failing the whole inspection.
      decodedHref = hrefPath;
    }
    return path.posix.normalize(path.posix.join(opfDirectory, decodedHref));
  }

  static String _formatDuration(Duration duration) {
    final int milliseconds = duration.inMilliseconds;
    if (milliseconds < 1000) {
      return '${milliseconds}ms';
    }
    if (milliseconds < 60000) {
      return '${(milliseconds / 1000).toStringAsFixed(2)}s';
    }
    final int minutes = duration.inMinutes;
    final int seconds = duration.inSeconds.remainder(60);
    return '${minutes}m ${seconds}s';
  }
}
