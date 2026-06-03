import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../../domain/models/inspection_result.dart';
import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/job_resume_state.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/models/translation_run_result.dart';
import '../../domain/repositories/translation_repository.dart';
import '../translation_cache_store.dart';

class EpubTranslationRepository implements TranslationRepository {
  EpubTranslationRepository({TranslationCacheStore? cacheStore})
    : _cacheStore = cacheStore ?? TranslationCacheStore();

  final TranslationCacheStore _cacheStore;

  static const Set<String> _translatableTags = <String>{
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'td',
    'th',
    'blockquote',
    'dt',
    'dd',
    'figcaption',
    'caption',
    'summary',
  };

  static const Set<String> _nonTextAncestors = <String>{
    'script',
    'style',
    'img',
    'svg',
    'math',
    'head',
    'link',
    'meta',
    'pre',
    'code',
    'var',
    'kbd',
    'samp',
  };

  static const String _cacheSchemaVersion = 'v1';

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<String> testConnection({required TranslationConfig config}) async {
    if (config.apiBaseUrl.trim().isEmpty ||
        config.apiKey.trim().isEmpty ||
        config.model.trim().isEmpty) {
      throw const FormatException(
        'API base URL, API key, and model are required before testing the connection.',
      );
    }

    final Dio dio = _buildDio(config);
    try {
      final Map<String, dynamic> requestData = <String, dynamic>{
        'model': config.model,
        'temperature': 0,
        'max_tokens': 8,
        'messages': const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'Reply with OK only.'},
        ],
      };
      final Response<dynamic> response = await dio.post<dynamic>(
        '/chat/completions',
        data: requestData,
      );
      final String content = _extractMessageContent(response.data);
      final String host = Uri.parse(_normalizedBaseUrl(config.apiBaseUrl)).host;
      return 'Connected to $host successfully. Model responded: ${content.isEmpty ? 'OK' : content}';
    } on DioException catch (error) {
      if (error.error is HandshakeException) {
        final String host = Uri.parse(
          _normalizedBaseUrl(config.apiBaseUrl),
        ).host;
        throw StateError(
          'TLS handshake failed while connecting to $host. Check the endpoint, proxy/VPN, and whether this network intercepts certificates.',
        );
      }
      final int? statusCode = error.response?.statusCode;
      final String host = Uri.parse(_normalizedBaseUrl(config.apiBaseUrl)).host;
      throw StateError(
        'Connection test failed for $host${statusCode != null ? ' with HTTP $statusCode' : ''}: ${error.message}',
      );
    }
  }

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
  }) async {
    final Stopwatch inspectionStopwatch = Stopwatch()..start();
    final String jobId = DateTime.now().millisecondsSinceEpoch.toString();
    TranslationJob currentJob = TranslationJob(
      id: jobId,
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.running,
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
    }

    emit(currentJob, 'Opening EPUB: ${path.basename(inputPath)}');

    final Archive archive = await _openArchive(inputPath);
    final Map<String, ArchiveFile> files = <String, ArchiveFile>{
      for (final ArchiveFile file in archive) file.name: file,
    };

    final ArchiveFile? containerFile = files['META-INF/container.xml'];
    if (containerFile == null) {
      throw const FormatException(
        'Invalid EPUB: META-INF/container.xml is missing.',
      );
    }

    final XmlDocument containerDocument = XmlDocument.parse(
      utf8.decode(_fileContent(containerFile)),
    );
    final XmlElement rootFile = containerDocument.descendants
        .whereType<XmlElement>()
        .firstWhere((XmlElement element) => element.name.local == 'rootfile');
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

    final List<String> chapterPaths = _chapterPathsFromOpf(
      files: files,
      opfPath: opfPath,
    );

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
    int totalBlocks = 0;
    for (int index = 0; index < chapterPaths.length; index += 1) {
      final String chapterPath = chapterPaths[index];
      final ArchiveFile? chapterFile = files[chapterPath];
      if (chapterFile == null) {
        continue;
      }
      final InspectedChapter chapter = _inspectChapter(
        chapterPath: chapterPath,
        bytes: _fileContent(chapterFile),
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

    final TranslationJob completedJob = currentJob.copyWith(
      status: TranslationJobStatus.completed,
      progress: 1,
      currentChapter: 'Ready for translation',
      completedFiles: chapterPaths.length,
      totalFiles: chapterPaths.length,
      totalBlocks: totalBlocks,
    );
    inspectionStopwatch.stop();
    emit(
      completedJob,
      'EPUB inspection complete. Preview now shows ${chapters.length} real chapters with a basic translation filter.',
    );
    emit(
      completedJob,
      'Performance: EPUB inspection took ${_formatDuration(inspectionStopwatch.elapsed)} for ${chapters.length} chapters and $totalBlocks text blocks.',
    );
    return InspectionResult(job: completedJob, chapters: chapters);
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationProgressCallback? onProgress,
  }) async {
    final List<InspectedChapter> selectedChapters = chapters
        .where((InspectedChapter chapter) => chapter.includeInTranslation)
        .toList();
    final int totalBlocks = selectedChapters.fold<int>(
      0,
      (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
    );

    if (selectedChapters.isEmpty) {
      throw const FormatException(
        'No chapters are selected. Check at least one chapter before starting translation.',
      );
    }
    if (totalBlocks == 0) {
      throw const FormatException(
        'The selected chapters do not contain any translatable text blocks yet.',
      );
    }
    if (config.apiBaseUrl.trim().isEmpty ||
        config.apiKey.trim().isEmpty ||
        config.model.trim().isEmpty) {
      throw const FormatException(
        'API base URL, API key, and model are required before translation can start.',
      );
    }

    final Dio dio = _buildDio(config);
    final Stopwatch translationStopwatch = Stopwatch()..start();
    Duration totalApiElapsed = Duration.zero;
    Duration totalCacheWriteElapsed = Duration.zero;
    int apiTranslatedBlocks = 0;
    int cacheWriteCount = 0;
    DateTime lastResumeSaveAt = DateTime.now();
    int blocksSinceResumeSave = 0;

    final String jobId = DateTime.now().millisecondsSinceEpoch.toString();
    final String outputFilePath = _outputFilePath(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      suffix: config.outputSuffix,
    );
    final String inputFingerprint = await _inputFingerprint(inputPath);
    final String jobKey = _jobKey(
      inputFingerprint: inputFingerprint,
      config: config,
      chapters: selectedChapters,
    );
    final JobResumeState? previousState = await _cacheStore.loadJobState(
      jobKey,
    );
    TranslationJob currentJob = TranslationJob(
      id: jobId,
      inputPath: inputPath,
      outputPath: outputFilePath,
      status: TranslationJobStatus.running,
      progress: 0,
      currentChapter: 'Preparing translation run',
      completedFiles: 0,
      totalFiles: selectedChapters.length,
      completedBlocks: 0,
      totalBlocks: totalBlocks,
      cachedBlocks: 0,
      resumedBlocks: 0,
    );

    void emit(TranslationJob job, String logLine) {
      currentJob = job;
      onProgress?.call(job, logLine);
    }

    Future<void> saveResumeState(
      TranslationJob job, {
      bool force = false,
    }) async {
      final DateTime now = DateTime.now();
      if (!force &&
          blocksSinceResumeSave < 20 &&
          now.difference(lastResumeSaveAt) < const Duration(seconds: 10)) {
        return;
      }
      await _cacheStore.saveJobState(
        _resumeStateFromJob(
          jobKey: jobKey,
          inputFingerprint: inputFingerprint,
          job: job,
        ),
      );
      lastResumeSaveAt = now;
      blocksSinceResumeSave = 0;
    }

    if (previousState != null) {
      emit(
        currentJob,
        'Found a saved translation checkpoint from ${previousState.updatedAtIso8601}. Cached blocks will be reused before new API calls.',
      );
    }

    emit(
      currentJob,
      'Starting translation for ${selectedChapters.length} chapters and $totalBlocks extracted blocks.',
    );
    await saveResumeState(currentJob, force: true);

    final Map<String, InspectedChapter> updatedByPath =
        <String, InspectedChapter>{
          for (final InspectedChapter chapter in chapters)
            chapter.path: chapter,
        };

    int completedBlocks = 0;
    int completedFiles = 0;
    int cachedBlocks = 0;
    int resumedBlocks = 0;
    final bool resumingFromCheckpoint = previousState != null;
    try {
      for (
        int chapterIndex = 0;
        chapterIndex < selectedChapters.length;
        chapterIndex += 1
      ) {
        final InspectedChapter chapter = selectedChapters[chapterIndex];
        final Stopwatch chapterStopwatch = Stopwatch()..start();
        Duration chapterApiElapsed = Duration.zero;
        Duration chapterCacheWriteElapsed = Duration.zero;
        int chapterApiBlocks = 0;
        int chapterCacheWrites = 0;
        emit(
          currentJob.copyWith(
            currentChapter: chapter.title,
            currentBlock: null,
            completedFiles: completedFiles,
            completedBlocks: completedBlocks,
          ),
          'Translating chapter ${chapterIndex + 1}/${selectedChapters.length}: ${chapter.title}',
        );

        final Map<String, ExtractedBlock> translatedById =
            <String, ExtractedBlock>{};
        int chapterCacheHits = 0;
        final List<ExtractedBlock> pendingBlocks = <ExtractedBlock>[];
        for (final ExtractedBlock block in chapter.blocks) {
          final String cacheKey = _blockCacheKey(config, block);
          final String? cachedTranslation = await _cacheStore
              .getBlockTranslation(cacheKey);
          if (cachedTranslation == null || cachedTranslation.trim().isEmpty) {
            pendingBlocks.add(block);
            continue;
          }
          translatedById[block.id] = block.copyWith(
            translatedHtml: cachedTranslation,
          );
          chapterCacheHits += 1;
          cachedBlocks += 1;
          if (resumingFromCheckpoint) {
            resumedBlocks += 1;
          }
          completedBlocks += 1;
        }

        if (chapterCacheHits > 0) {
          final TranslationJob cachedJob = currentJob.copyWith(
            progress: completedBlocks / totalBlocks,
            currentChapter: chapter.title,
            currentBlock: null,
            completedFiles: completedFiles,
            totalFiles: selectedChapters.length,
            completedBlocks: completedBlocks,
            totalBlocks: totalBlocks,
            cachedBlocks: cachedBlocks,
            resumedBlocks: resumedBlocks,
          );
          emit(
            cachedJob,
            'Reused $chapterCacheHits cached blocks for ${chapter.title}.',
          );
          blocksSinceResumeSave += chapterCacheHits;
          await saveResumeState(cachedJob);
        }

        final List<_BlockBatch> batches = _buildBatches(
          pendingBlocks,
          config.chunkSize,
        );
        emit(
          currentJob.copyWith(
            currentChapter: chapter.title,
            completedFiles: completedFiles,
            completedBlocks: completedBlocks,
          ),
          'Prepared ${batches.length} batched requests for ${chapter.title}.',
        );

        for (
          int batchStart = 0;
          batchStart < batches.length;
          batchStart += config.maxConcurrent
        ) {
          final int batchEnd = min(
            batchStart + config.maxConcurrent,
            batches.length,
          );
          final List<_BlockBatch> batchWindow = batches.sublist(
            batchStart,
            batchEnd,
          );
          final List<_TimedBatchResult> translatedWindow =
              await Future.wait<_TimedBatchResult>(
                batchWindow.asMap().entries.map((entry) async {
                  final int batchNumber = batchStart + entry.key + 1;
                  final _BlockBatch batch = entry.value;
                  final Stopwatch apiStopwatch = Stopwatch()..start();
                  final List<String> translated = await _translateBlockBatch(
                    dio: dio,
                    config: config,
                    batch: batch,
                  );
                  apiStopwatch.stop();
                  return _TimedBatchResult(
                    batch: batch,
                    translatedBlocks: translated,
                    batchNumber: batchNumber,
                    elapsed: apiStopwatch.elapsed,
                  );
                }),
              );

          for (
            int batchIndex = 0;
            batchIndex < translatedWindow.length;
            batchIndex += 1
          ) {
            final _TimedBatchResult timedBatch = translatedWindow[batchIndex];
            final _BlockBatch batch = timedBatch.batch;
            final List<String> translatedBatch = timedBatch.translatedBlocks;
            chapterApiElapsed += timedBatch.elapsed;
            totalApiElapsed += timedBatch.elapsed;
            chapterApiBlocks += batch.blocks.length;
            apiTranslatedBlocks += batch.blocks.length;
            emit(
              currentJob.copyWith(
                currentChapter: chapter.title,
                completedFiles: completedFiles,
                completedBlocks: completedBlocks,
              ),
              'Performance: API batch ${timedBatch.batchNumber}/${batches.length} for ${chapter.title} (${batch.blocks.length} blocks) took ${_formatDuration(timedBatch.elapsed)}.',
            );
            for (int index = 0; index < batch.blocks.length; index += 1) {
              final ExtractedBlock sourceBlock = batch.blocks[index];
              final ExtractedBlock translatedBlock = sourceBlock.copyWith(
                translatedHtml: translatedBatch[index],
              );
              translatedById[sourceBlock.id] = translatedBlock;
              final Stopwatch cacheWriteStopwatch = Stopwatch()..start();
              await _cacheStore.putBlockTranslation(
                _blockCacheKey(config, sourceBlock),
                translatedBatch[index],
              );
              cacheWriteStopwatch.stop();
              chapterCacheWriteElapsed += cacheWriteStopwatch.elapsed;
              totalCacheWriteElapsed += cacheWriteStopwatch.elapsed;
              chapterCacheWrites += 1;
              cacheWriteCount += 1;
              completedBlocks += 1;
              blocksSinceResumeSave += 1;
              final TranslationJob nextJob = currentJob.copyWith(
                progress: completedBlocks / totalBlocks,
                currentChapter: chapter.title,
                currentBlock: _linePreview(sourceBlock.sourceText),
                completedFiles: completedFiles,
                totalFiles: selectedChapters.length,
                completedBlocks: completedBlocks,
                totalBlocks: totalBlocks,
                cachedBlocks: cachedBlocks,
                resumedBlocks: resumedBlocks,
              );
              currentJob = nextJob;
              await saveResumeState(nextJob);
            }
            emit(
              currentJob,
              'Translated $completedBlocks/$totalBlocks blocks after batch ${timedBatch.batchNumber}/${batches.length} for ${chapter.title}.',
            );
          }
        }

        completedFiles += 1;
        chapterStopwatch.stop();
        final List<ExtractedBlock> translatedBlocks = chapter.blocks
            .map((ExtractedBlock block) => translatedById[block.id] ?? block)
            .toList();
        updatedByPath[chapter.path] = chapter.copyWith(
          blocks: translatedBlocks,
          body: _previewBodyFromBlocks(
            translatedBlocks,
            fallback: chapter.body,
          ),
        );
        final TranslationJob chapterDoneJob = currentJob.copyWith(
          progress: completedBlocks / totalBlocks,
          currentChapter: chapter.title,
          currentBlock: null,
          completedFiles: completedFiles,
          totalFiles: selectedChapters.length,
          completedBlocks: completedBlocks,
          totalBlocks: totalBlocks,
          cachedBlocks: cachedBlocks,
          resumedBlocks: resumedBlocks,
        );
        emit(
          chapterDoneJob,
          'Completed chapter $completedFiles/${selectedChapters.length}: ${chapter.title}',
        );
        emit(
          chapterDoneJob,
          'Performance: Chapter ${chapterIndex + 1}/${selectedChapters.length} took ${_formatDuration(chapterStopwatch.elapsed)}. API time ${_formatDuration(chapterApiElapsed)} for $chapterApiBlocks new blocks; block cache writes ${_formatDuration(chapterCacheWriteElapsed)} across $chapterCacheWrites writes; throughput ${_formatBlocksPerMinute(chapterApiBlocks, chapterStopwatch.elapsed)} new blocks/min.',
        );
        await saveResumeState(chapterDoneJob, force: true);
      }
    } catch (error) {
      await _cacheStore.saveJobState(
        JobResumeState(
          jobKey: jobKey,
          inputFingerprint: inputFingerprint,
          inputPath: currentJob.inputPath,
          outputPath: currentJob.outputPath,
          status: 'failed',
          completedFiles: completedFiles,
          totalFiles: selectedChapters.length,
          completedBlocks: completedBlocks,
          totalBlocks: totalBlocks,
          cachedBlocks: cachedBlocks,
          resumedBlocks: resumedBlocks,
          currentChapter: currentJob.currentChapter ?? '',
          updatedAtIso8601: DateTime.now().toIso8601String(),
        ),
      );
      rethrow;
    }

    emit(
      currentJob.copyWith(
        progress: 0.98,
        currentChapter: 'Repacking EPUB',
        currentBlock: null,
        completedFiles: completedFiles,
        totalFiles: selectedChapters.length,
        completedBlocks: completedBlocks,
        totalBlocks: totalBlocks,
        cachedBlocks: cachedBlocks,
        resumedBlocks: resumedBlocks,
      ),
      'Writing translated XHTML back into the EPUB package.',
    );

    final List<InspectedChapter> updatedChapters = chapters
        .map(
          (InspectedChapter chapter) => updatedByPath[chapter.path] ?? chapter,
        )
        .toList();
    final Stopwatch repackStopwatch = Stopwatch()..start();
    await _writeTranslatedEpub(
      inputPath: inputPath,
      outputFilePath: outputFilePath,
      config: config,
      chapters: updatedChapters,
    );
    repackStopwatch.stop();

    final TranslationJob completedJob = currentJob.copyWith(
      status: TranslationJobStatus.completed,
      progress: 1,
      currentChapter: 'EPUB ready',
      currentBlock: null,
      completedFiles: completedFiles,
      totalFiles: selectedChapters.length,
      completedBlocks: completedBlocks,
      totalBlocks: totalBlocks,
      cachedBlocks: cachedBlocks,
      resumedBlocks: resumedBlocks,
    );
    translationStopwatch.stop();
    emit(
      completedJob,
      'Translation complete. Wrote translated EPUB to $outputFilePath',
    );
    emit(
      completedJob,
      'Performance: Final EPUB repack took ${_formatDuration(repackStopwatch.elapsed)}.',
    );
    emit(
      completedJob,
      'Performance: Translation run took ${_formatDuration(translationStopwatch.elapsed)}. Translated $apiTranslatedBlocks new blocks at ${_formatBlocksPerMinute(apiTranslatedBlocks, translationStopwatch.elapsed)} blocks/min on average, excluding cache and resume hits. Total API time ${_formatDuration(totalApiElapsed)}; block cache writes ${_formatDuration(totalCacheWriteElapsed)} across $cacheWriteCount writes.',
    );
    await _cacheStore.saveJobState(
      _resumeStateFromJob(
        jobKey: jobKey,
        inputFingerprint: inputFingerprint,
        job: completedJob,
        status: 'completed',
      ),
    );
    return TranslationRunResult(job: completedJob, chapters: updatedChapters);
  }

  Future<Archive> _openArchive(String inputPath) async {
    final File epubFile = File(inputPath);
    final List<int> bytes = await epubFile.readAsBytes();
    return ZipDecoder().decodeBytes(bytes);
  }

  List<String> _chapterPathsFromOpf({
    required Map<String, ArchiveFile> files,
    required String opfPath,
  }) {
    final ArchiveFile? opfFile = files[opfPath];
    if (opfFile == null) {
      throw FormatException(
        'Invalid EPUB: package document not found at $opfPath.',
      );
    }

    final XmlDocument opfDocument = XmlDocument.parse(
      utf8.decode(_fileContent(opfFile)),
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
      manifest[id] = path.posix.normalize(path.posix.join(opfDirectory, href));
    }

    final List<String> chapterPaths = <String>[];
    for (final XmlElement itemRef
        in opfDocument.descendants.whereType<XmlElement>()) {
      if (itemRef.name.local != 'itemref') {
        continue;
      }
      final String? idRef = itemRef.getAttribute('idref');
      final String? chapterPath = idRef == null ? null : manifest[idRef];
      if (chapterPath == null) {
        continue;
      }
      if (_isHtmlDocument(chapterPath)) {
        chapterPaths.add(chapterPath);
      }
    }
    return chapterPaths;
  }

  List<int> _fileContent(ArchiveFile file) {
    final Object content = file.content;
    if (content is List<int>) {
      return content;
    }
    if (content is Uint8List) {
      return content;
    }
    if (content is String) {
      return utf8.encode(content);
    }
    return file.readBytes()?.toList() ?? <int>[];
  }

  bool _isHtmlDocument(String filePath) {
    final String lower = filePath.toLowerCase();
    return lower.endsWith('.html') ||
        lower.endsWith('.xhtml') ||
        lower.endsWith('.htm');
  }

  InspectedChapter _inspectChapter({
    required String chapterPath,
    required List<int> bytes,
  }) {
    final String html = utf8.decode(bytes, allowMalformed: true);
    final dom.Document document = html_parser.parse(html);
    final String title =
        document.querySelector('title')?.text.trim().isNotEmpty == true
        ? document.querySelector('title')!.text.trim()
        : document
                  .querySelector('h1, h2, h3')
                  ?.text
                  .trim()
                  .replaceAll(RegExp(r'\s+'), ' ') ??
              path.basenameWithoutExtension(chapterPath);
    final List<ExtractedBlock> blocks = _extractBlocks(document);
    final String bodyText = blocks.isNotEmpty
        ? blocks
              .take(12)
              .map((ExtractedBlock block) => block.sourceText)
              .join('\n\n')
              .trim()
        : (document.body?.text ?? document.documentElement?.text ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

    final ChapterCategory category = _categorizeChapter(chapterPath, title);
    final bool recommendedForTranslation =
        category != ChapterCategory.ancillary;

    return InspectedChapter(
      path: chapterPath,
      title: title.isEmpty ? path.basenameWithoutExtension(chapterPath) : title,
      body: bodyText.isEmpty
          ? '(No readable text extracted from this chapter.)'
          : bodyText,
      originalHtml: html,
      blocks: blocks,
      category: category,
      recommendedForTranslation: recommendedForTranslation,
      includeInTranslation: recommendedForTranslation,
    );
  }

  List<ExtractedBlock> _extractBlocks(dom.Document document) {
    final List<ExtractedBlock> blocks = <ExtractedBlock>[];
    int index = 0;
    for (final dom.Element element in _extractTranslatableElements(document)) {
      final String sourceText = element.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (sourceText.isEmpty) {
        continue;
      }
      index += 1;
      blocks.add(
        ExtractedBlock(
          id: '${element.localName ?? 'node'}-$index',
          tagName: element.localName ?? 'node',
          sourceHtml: element.outerHtml,
          sourceText: sourceText,
        ),
      );
    }
    return blocks;
  }

  List<dom.Element> _extractTranslatableElements(dom.Document document) {
    return document
        .querySelectorAll(_translatableTags.join(', '))
        .where(
          (dom.Element element) =>
              !_hasTranslatableAncestor(element) &&
              !_isInsideSkippedAncestor(element),
        )
        .toList();
  }

  bool _hasTranslatableAncestor(dom.Element element) {
    dom.Node? current = element.parent;
    while (current is dom.Element) {
      if (_translatableTags.contains(current.localName)) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  bool _isInsideSkippedAncestor(dom.Element element) {
    dom.Node? current = element.parent;
    while (current is dom.Element) {
      if (_nonTextAncestors.contains(current.localName)) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  ChapterCategory _categorizeChapter(String chapterPath, String title) {
    final String token = '${chapterPath.toLowerCase()} ${title.toLowerCase()}';

    if (_matchesAny(token, <String>[
      'cover',
      'copyright',
      'credit',
      'signup',
      'advert',
      'ad_',
      'promo',
      'z-lib',
      '1lib',
    ])) {
      return ChapterCategory.ancillary;
    }

    if (_matchesAny(token, <String>[
      'index',
      'endnote',
      'notes',
      'bibliography',
      'reference',
    ])) {
      return ChapterCategory.reference;
    }

    if (_matchesAny(token, <String>[
      'ack',
      'acknowledg',
      'authorbio',
      'about the author',
      'epilogue',
      'appendix',
    ])) {
      return ChapterCategory.backMatter;
    }

    if (_matchesAny(token, <String>[
      'dedication',
      'prologue',
      'foreword',
      'preface',
      'title',
      'contents',
      'introduction',
      'fm0',
      'front',
    ])) {
      return ChapterCategory.frontMatter;
    }

    return ChapterCategory.content;
  }

  bool _matchesAny(String source, List<String> needles) {
    return needles.any(source.contains);
  }

  String _normalizedBaseUrl(String value) {
    String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    if (!trimmed.contains('://')) {
      trimmed = 'https://$trimmed';
    }
    trimmed = trimmed.replaceAll(RegExp(r'/+$'), '');

    final String lower = trimmed.toLowerCase();
    if (lower.endsWith('/chat/completions')) {
      trimmed = trimmed.substring(
        0,
        trimmed.length - '/chat/completions'.length,
      );
    }
    if (trimmed.toLowerCase().endsWith('/v1')) {
      return trimmed;
    }
    return '$trimmed/v1';
  }

  Dio _buildDio(TranslationConfig config) {
    final Dio dio = Dio(
      BaseOptions(
        baseUrl: _normalizedBaseUrl(config.apiBaseUrl),
        headers: <String, String>{
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
          'Connection': 'keep-alive',
          'User-Agent': 'epub-translator-flutter/1.0',
        },
        connectTimeout: Duration(seconds: config.timeoutSeconds),
        receiveTimeout: Duration(seconds: config.timeoutSeconds),
        sendTimeout: Duration(seconds: config.timeoutSeconds),
      ),
    );

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final HttpClient client = HttpClient()
          ..connectionTimeout = Duration(seconds: config.timeoutSeconds)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = max(4, config.maxConcurrent * 2)
          ..userAgent = 'epub-translator-flutter/1.0';
        return client;
      },
    );

    return dio;
  }

  Future<String> _translateBlock({
    required Dio dio,
    required TranslationConfig config,
    required ExtractedBlock block,
  }) async {
    Object? lastError;
    for (int attempt = 1; attempt <= config.maxRetries; attempt += 1) {
      try {
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. Preserve every HTML tag, attribute, inline emphasis, entity, and link target. Translate only human-readable text nodes. Return only the translated HTML fragment with no markdown fences and no explanation.',
            },
            <String, String>{'role': 'user', 'content': block.sourceHtml},
          ],
        };
        final Response<dynamic> response = await dio.post<dynamic>(
          '/chat/completions',
          data: requestData,
        );

        final dynamic rawContent =
            (response.data
                as Map<String, dynamic>)['choices']?[0]?['message']?['content'];
        final String translated = switch (rawContent) {
          String value => value,
          List<dynamic> value =>
            value
                .map<dynamic>(
                  (dynamic item) =>
                      item is Map<String, dynamic> ? item['text'] : item,
                )
                .whereType<String>()
                .join(),
          _ => '',
        };
        final String cleaned = translated.trim();
        if (cleaned.isEmpty) {
          throw const FormatException(
            'The translation API returned an empty block.',
          );
        }
        return cleaned;
      } catch (error) {
        lastError = error;
        if (attempt >= config.maxRetries) {
          break;
        }
        await Future<void>.delayed(
          Duration(seconds: max(1, config.retryDelaySeconds)),
        );
      }
    }
    if (lastError is DioException && lastError.error is HandshakeException) {
      final String host = Uri.parse(_normalizedBaseUrl(config.apiBaseUrl)).host;
      throw StateError(
        'TLS handshake failed while connecting to $host. The API endpoint may be blocked on this network, require a proxy/VPN, or be interrupted by certificate inspection.',
      );
    }
    throw StateError(
      'Translation failed after ${config.maxRetries} attempts: $lastError',
    );
  }

  List<_BlockBatch> _buildBatches(List<ExtractedBlock> blocks, int chunkSize) {
    final List<_BlockBatch> batches = <_BlockBatch>[];
    List<ExtractedBlock> current = <ExtractedBlock>[];
    int currentBudget = 0;

    for (final ExtractedBlock block in blocks) {
      final int blockBudget =
          max(block.sourceHtml.length, block.sourceText.length) + 96;
      final bool exceedsCurrent =
          current.isNotEmpty && currentBudget + blockBudget > chunkSize;
      if (exceedsCurrent) {
        batches.add(_BlockBatch(current));
        current = <ExtractedBlock>[];
        currentBudget = 0;
      }
      current.add(block);
      currentBudget += blockBudget;
    }

    if (current.isNotEmpty) {
      batches.add(_BlockBatch(current));
    }
    return batches;
  }

  Future<List<String>> _translateBlockBatch({
    required Dio dio,
    required TranslationConfig config,
    required _BlockBatch batch,
  }) async {
    final String payload = jsonEncode(<String, dynamic>{
      'blocks': batch.blocks
          .map(
            (ExtractedBlock block) => <String, String>{
              'id': block.id,
              'html': block.sourceHtml,
            },
          )
          .toList(),
    });

    try {
      final Map<String, dynamic> requestData = <String, dynamic>{
        'model': config.model,
        'temperature': 0.2,
        'messages': <Map<String, String>>[
          <String, String>{
            'role': 'system',
            'content':
                'You translate EPUB HTML fragments into ${config.targetLanguage}. Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain the original "id" and the translated HTML in "html". Do not omit any block and keep the same order.',
          },
          <String, String>{'role': 'user', 'content': payload},
        ],
      };
      final Response<dynamic> response = await dio.post<dynamic>(
        '/chat/completions',
        data: requestData,
      );

      final String parsedContent = _extractMessageContent(response.data);
      final Map<String, dynamic> jsonPayload = _decodeJsonObject(parsedContent);
      final List<dynamic> blocksJson =
          jsonPayload['blocks'] as List<dynamic>? ?? <dynamic>[];
      if (blocksJson.length != batch.blocks.length) {
        throw const FormatException(
          'Translated batch length does not match request length.',
        );
      }

      final Map<String, String> translatedById = <String, String>{};
      for (final dynamic item in blocksJson) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException(
            'Translated batch item is not a JSON object.',
          );
        }
        final String? id = item['id'] as String?;
        final String? html = item['html'] as String?;
        if (id == null || html == null || html.trim().isEmpty) {
          throw const FormatException(
            'Translated batch item is missing id or html.',
          );
        }
        translatedById[id] = html.trim();
      }

      return batch.blocks.map((ExtractedBlock block) {
        final String? translated = translatedById[block.id];
        if (translated == null || translated.isEmpty) {
          throw const FormatException(
            'A translated block is missing from the batch response.',
          );
        }
        return translated;
      }).toList();
    } on DioException catch (_) {
      return Future.wait<String>(
        batch.blocks.map(
          (ExtractedBlock block) =>
              _translateBlock(dio: dio, config: config, block: block),
        ),
      );
    } on FormatException catch (_) {
      // Recovery path: malformed batch JSON falls back to per-block calls.
      return Future.wait<String>(
        batch.blocks.map(
          (ExtractedBlock block) =>
              _translateBlock(dio: dio, config: config, block: block),
        ),
      );
    }
  }

  String _linePreview(String value) {
    final String collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 72) {
      return collapsed;
    }
    return '${collapsed.substring(0, 69)}...';
  }

  String _extractMessageContent(dynamic responseData) {
    final dynamic rawContent =
        (responseData
            as Map<String, dynamic>)['choices']?[0]?['message']?['content'];
    return switch (rawContent) {
      String value => value.trim(),
      List<dynamic> value =>
        value
            .map<dynamic>(
              (dynamic item) =>
                  item is Map<String, dynamic> ? item['text'] : item,
            )
            .whereType<String>()
            .join()
            .trim(),
      _ => '',
    };
  }

  Map<String, dynamic> _decodeJsonObject(String content) {
    final String normalized = content.trim();
    final Match? fenced = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
    ).firstMatch(normalized);
    final String candidate = fenced?.group(1)?.trim() ?? normalized;
    final Object? decoded = jsonDecode(candidate);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Model response is not a JSON object.');
    }
    return decoded;
  }

  String _outputFilePath({
    required String inputPath,
    required String outputDirectory,
    required String suffix,
  }) {
    final String safeSuffix = suffix.isEmpty ? '_translated' : suffix;
    return path.join(
      outputDirectory,
      '${path.basenameWithoutExtension(inputPath)}$safeSuffix.epub',
    );
  }

  Future<String> _inputFingerprint(String inputPath) async {
    final FileStat stat = await File(inputPath).stat();
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              inputPath,
              stat.size,
              stat.modified.millisecondsSinceEpoch,
            ].join('|'),
          ),
        )
        .toString();
  }

  String _jobKey({
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              inputFingerprint,
              config.apiBaseUrl,
              config.model,
              config.targetLanguage,
              config.bilingual,
              chapters
                  .map((InspectedChapter chapter) => chapter.path)
                  .join('|'),
            ].join('|'),
          ),
        )
        .toString();
  }

  String _blockCacheKey(TranslationConfig config, ExtractedBlock block) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              config.apiBaseUrl,
              config.model,
              config.targetLanguage,
              block.sourceHtml,
            ].join('|'),
          ),
        )
        .toString();
  }

  JobResumeState _resumeStateFromJob({
    required String jobKey,
    required String inputFingerprint,
    required TranslationJob job,
    String? status,
  }) {
    return JobResumeState(
      jobKey: jobKey,
      inputFingerprint: inputFingerprint,
      inputPath: job.inputPath,
      outputPath: job.outputPath,
      status: status ?? job.status.name,
      completedFiles: job.completedFiles,
      totalFiles: job.totalFiles,
      completedBlocks: job.completedBlocks,
      totalBlocks: job.totalBlocks,
      cachedBlocks: job.cachedBlocks,
      resumedBlocks: job.resumedBlocks,
      currentChapter: job.currentChapter ?? '',
      updatedAtIso8601: DateTime.now().toIso8601String(),
    );
  }

  String _previewBodyFromBlocks(
    List<ExtractedBlock> blocks, {
    required String fallback,
  }) {
    final Iterable<String> translated = blocks
        .map((ExtractedBlock block) => _plainTextFromHtml(block.translatedHtml))
        .whereType<String>()
        .map((String text) => text.trim())
        .where((String text) => text.isNotEmpty)
        .take(12);
    if (translated.isEmpty) {
      return fallback;
    }
    return translated.join('\n\n');
  }

  Future<void> _writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) async {
    final Archive sourceArchive = await _openArchive(inputPath);
    final Map<String, InspectedChapter> chaptersByPath =
        <String, InspectedChapter>{
          for (final InspectedChapter chapter in chapters)
            chapter.path: chapter,
        };
    final Archive repackedArchive = Archive();

    final ArchiveFile? mimetypeFile = sourceArchive.find('mimetype');
    if (mimetypeFile != null) {
      final List<int> mimetypeBytes = _fileContent(mimetypeFile);
      final ArchiveFile storedMimetype =
          ArchiveFile.noCompress(
              'mimetype',
              mimetypeBytes.length,
              mimetypeBytes,
            )
            ..lastModTime = mimetypeFile.lastModTime
            ..mode = mimetypeFile.mode;
      repackedArchive.add(storedMimetype);
    }

    for (final ArchiveFile sourceFile in sourceArchive) {
      if (sourceFile.name == 'mimetype') {
        continue;
      }

      final InspectedChapter? chapter = chaptersByPath[sourceFile.name];
      if (chapter != null && chapter.includeInTranslation) {
        final String renderedHtml = _renderTranslatedChapter(
          chapter: chapter,
          bilingual: config.bilingual,
        );
        final ArchiveFile translatedFile =
            ArchiveFile.string(sourceFile.name, renderedHtml)
              ..compression = sourceFile.compression
              ..lastModTime = sourceFile.lastModTime
              ..mode = sourceFile.mode;
        repackedArchive.add(translatedFile);
        continue;
      }

      if (!sourceFile.isFile) {
        final ArchiveFile directory = ArchiveFile.directory(sourceFile.name)
          ..lastModTime = sourceFile.lastModTime
          ..mode = sourceFile.mode;
        repackedArchive.add(directory);
        continue;
      }

      final List<int> originalBytes = _fileContent(sourceFile);
      final ArchiveFile copiedFile =
          ArchiveFile.bytes(sourceFile.name, originalBytes)
            ..compression = sourceFile.compression
            ..lastModTime = sourceFile.lastModTime
            ..mode = sourceFile.mode;
      repackedArchive.add(copiedFile);
    }

    final Uint8List encoded = ZipEncoder().encodeBytes(repackedArchive);
    final File outputFile = File(outputFilePath);
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(encoded, flush: true);
  }

  String _renderTranslatedChapter({
    required InspectedChapter chapter,
    required bool bilingual,
  }) {
    final dom.Document document = html_parser.parse(chapter.originalHtml);
    final List<dom.Element> targets = _extractTranslatableElements(document);
    final int count = min(targets.length, chapter.blocks.length);
    for (int index = 0; index < count; index += 1) {
      final dom.Element target = targets[index];
      final ExtractedBlock block = chapter.blocks[index];
      final String translatedHtml = block.translatedHtml?.trim() ?? '';
      if (translatedHtml.isEmpty) {
        continue;
      }
      final String replacement = bilingual
          ? '${target.outerHtml}\n${_sanitizeForBilingual(translatedHtml)}'
          : translatedHtml;
      _replaceNodeWithHtml(target, replacement);
    }
    return document.outerHtml;
  }

  void _replaceNodeWithHtml(dom.Element target, String replacementHtml) {
    final dom.Node? parentNode = target.parentNode;
    if (parentNode == null) {
      return;
    }
    final int index = parentNode.nodes.indexOf(target);
    if (index < 0) {
      return;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      replacementHtml,
      container: target.parent?.localName ?? 'body',
    );
    final List<dom.Node> replacementNodes = fragment.nodes.toList();
    if (replacementNodes.isEmpty) {
      return;
    }
    parentNode.nodes[index] = replacementNodes.first;
    for (int i = 1; i < replacementNodes.length; i += 1) {
      parentNode.nodes.insert(index + i, replacementNodes[i]);
    }
  }

  String _sanitizeForBilingual(String translatedHtml) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      translatedHtml,
    );
    for (final dom.Element element in fragment.querySelectorAll('[id]')) {
      element.attributes.remove('id');
      element.attributes['data-translation'] = 'true';
    }
    return fragment.outerHtml;
  }

  String? _plainTextFromHtml(String? html) {
    if (html == null || html.trim().isEmpty) {
      return null;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(html);
    return (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _formatDuration(Duration duration) {
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

  String _formatBlocksPerMinute(int blockCount, Duration elapsed) {
    if (blockCount <= 0 || elapsed.inMilliseconds <= 0) {
      return '0.0';
    }
    final double minutes =
        elapsed.inMilliseconds / Duration.millisecondsPerMinute;
    return (blockCount / minutes).toStringAsFixed(1);
  }
}

class _BlockBatch {
  const _BlockBatch(this.blocks);

  final List<ExtractedBlock> blocks;
}

class _TimedBatchResult {
  const _TimedBatchResult({
    required this.batch,
    required this.translatedBlocks,
    required this.batchNumber,
    required this.elapsed,
  });

  final _BlockBatch batch;
  final List<String> translatedBlocks;
  final int batchNumber;
  final Duration elapsed;
}
