import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart' as xml;

import '../../../shared/logging/app_logger.dart';
import 'epub/epub_text_decoder.dart';
import 'epub/epub_navigation.dart';
import 'epub/epub_dom.dart';
import 'epub/epub_source_guard.dart';
import '../domain/repositories/translation_repository.dart';
import '../domain/models/inspected_chapter.dart';
import 'epub/epub_html_extractor.dart';
import 'epub/xhtml_html_compatibility.dart';
import 'epub_output_recovery.dart';
import 'epub_streaming_zip.dart';

export 'epub_output_recovery.dart'
    show
        OutputFileLockedException,
        OutputFileRecoveryException,
        OutputFileRecoveryTimeoutException,
        RecoveryBudgetEntry,
        RecoveryBudgetKind,
        recoveryBudgetDeletions;
export 'epub_streaming_zip.dart'
    show
        DecodedEpubArchive,
        EpubDecompressionLimitException,
        InputFileLockedException;

/// Navigation only looks up container, OPF and manifest-selected nav/NCX
/// entries. Indexing names must not inflate unrelated chapter/media payloads.
class _LazyArchiveView extends MapBase<String, List<int>> {
  _LazyArchiveView(Archive archive, {required this.inputPath})
    : _entries = {
        for (final file in archive)
          if (file.isFile) file.name: file,
      };

  /// Carried for the streaming zip-bomb guard: entry inflation counts actual
  /// decompressed bytes and reports over-limit entries against this path.
  final String inputPath;
  final Map<String, ArchiveFile> _entries;
  final Map<String, List<int>> _bytes = {};

  @override
  List<int>? operator [](Object? key) {
    final file = _entries[key];
    if (file == null) return null;
    // Reading via the guarded inflate leaves ArchiveFile.isCompressed intact
    // (nothing is memoized into .content), even for container.xml, which is
    // read for navigation but copied unchanged.
    return _bytes.putIfAbsent(
      file.name,
      () => EpubIsolateWorker._fileBytes(file, inputPath: inputPath),
    );
  }

  @override
  bool containsKey(Object? key) => _entries.containsKey(key);

  @override
  Iterable<String> get keys => _entries.keys;

  @override
  void operator []=(String key, List<int> value) =>
      throw UnsupportedError('Read-only archive view');

  @override
  void clear() => throw UnsupportedError('Read-only archive view');

  @override
  List<int>? remove(Object? key) =>
      throw UnsupportedError('Read-only archive view');
}

class _ProgressWork<T> {
  const _ProgressWork(this.operation, this.messages);
  final T Function(void Function(int, int)) operation;
  final SendPort messages;
}

void _progressWorkEntry<T>(_ProgressWork<T> work) {
  try {
    final result = work.operation((done, total) {
      work.messages.send(['progress', done, total]);
    });
    Isolate.exit(work.messages, ['result', result]);
  } catch (error, stack) {
    work.messages.send(['error', error, stack]);
  }
}

class _CancellableAsyncWork<T> {
  const _CancellableAsyncWork(this.operation, this.messages);
  final Future<T> Function(
    void Function(int, int) onProgress,
    bool Function() isCancelled,
  )
  operation;
  final SendPort messages;
}

Future<void> _cancellableAsyncWorkEntry<T>(
  _CancellableAsyncWork<T> work,
) async {
  bool cancelled = false;
  final ReceivePort control = ReceivePort();
  control.listen((dynamic message) {
    if (message == 'cancel') {
      cancelled = true;
    }
  });
  work.messages.send(<Object>['control', control.sendPort]);
  try {
    final T result = await work.operation((int done, int total) {
      work.messages.send(<Object>['progress', done, total]);
    }, () => cancelled);
    work.messages.send(<Object?>['result', result]);
  } catch (error, stack) {
    work.messages.send(<Object>['error', error, stack]);
  } finally {
    control.close();
  }
}

/// [EpubDecompressionLimitException] the moment the total exceeds
/// the configured uncompressed safety limit.
class _GuardedInflateStream extends OutputMemoryStream {
  _GuardedInflateStream({
    required this.inputPath,
    required this.entryName,
    required this.compressedBytes,
    required this.limitBytes,
  });

  final String inputPath;
  final String entryName;
  final int compressedBytes;
  final int limitBytes;

  Never _overflow(int incoming) => throw EpubDecompressionLimitException(
    inputPath: '$inputPath!$entryName',
    compressedBytes: compressedBytes,
    uncompressedBytes: length + incoming,
    limitBytes: limitBytes,
  );

  @override
  void writeByte(int value) {
    if (length + 1 > limitBytes) _overflow(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final int count = length ?? bytes.length;
    if (this.length + count > limitBytes) _overflow(count);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    // Stored (uncompressed) entries arrive whole via writeStream; the cap
    // must apply here too, not just to the incremental inflate writes.
    if (length + stream.length > limitBytes) _overflow(stream.length);
    super.writeStream(stream);
  }
}

/// Forwards each decompressed chunk from the native chunked ZLib decoder
/// straight into the guard stream, so the byte cap is enforced per chunk
/// instead of after the whole payload materialized (see P1-#1).
class _GuardedChunkSink implements ChunkedConversionSink<List<int>> {
  _GuardedChunkSink(this.output);

  final _GuardedInflateStream output;

  @override
  void add(List<int> chunk) => output.writeBytes(chunk);

  @override
  void close() {}
}

/// Heavy ZIP work off the UI isolate (Windows/Android).
class EpubIsolateWorker {
  const EpubIsolateWorker._();

  static const String _opfNamespaceUri = 'http://www.idpf.org/2007/opf';

  /// Mirrors `EpubInspector._isOpfManifestChild`: only matches OPF-manifest
  /// `<item>` elements, so a foreign-namespace `<item>` cannot hijack the
  /// nav/NCX lookup during repack (B-1).
  static bool _isOpfManifestChild(xml.XmlElement element, String localName) {
    if (element.name.local != localName) return false;
    final String? ns = element.name.namespaceUri;
    if (ns != null && ns != _opfNamespaceUri) return false;
    final xml.XmlNode? parent = element.parent;
    if (parent is! xml.XmlElement || parent.name.local != 'manifest') {
      return false;
    }
    final String? parentNs = parent.name.namespaceUri;
    return parentNs == null || parentNs == _opfNamespaceUri;
  }

  /// Runs CPU-only preparation with progress messages. Cancellation sends an
  /// immediate isolate control message, so even a single huge DOM parse can
  /// be stopped. File-producing work must reserve its temp path in the parent
  /// and clean it after termination (as writeTranslatedEpub does); killing an
  /// isolate cannot run its finally blocks or report a newly created path.
  /// [finishBeforeCancellation] lets file-producing operations finish their
  /// synchronous work and close native handles before cancellation returns.
  static Future<T> prepareWithProgress<T>({
    required T Function(void Function(int, int)) operation,
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
    bool finishBeforeCancellation = false,
  }) async {
    if (isCancelled()) throw const TranslationCancelledException();
    final messages = ReceivePort();
    final completed = Completer<T>();
    final exited = Completer<void>();
    Isolate? worker;
    Timer? cancellationPoll;
    final subscription = messages.listen((dynamic message) {
      if (message == null && !exited.isCompleted) exited.complete();
      if (completed.isCompleted) return;
      try {
        if (isCancelled()) throw const TranslationCancelledException();
        if (message == null) {
          throw StateError('EPUB preparation worker exited without a result.');
        }
        final values = message as List<dynamic>;
        switch (values[0]) {
          case 'progress':
            onProgress?.call(values[1] as int, values[2] as int);
          case 'result':
            completed.complete(values[1] as T);
          case 'error':
            completed.completeError(
              values[1] as Object,
              values[2] as StackTrace,
            );
          default:
            // Uncaught isolate errors use the VM's [error, stack] envelope.
            completed.completeError(
              StateError(values[0].toString()),
              StackTrace.fromString(values[1].toString()),
            );
        }
      } catch (error, stack) {
        completed.completeError(error, stack);
      }
    });
    try {
      worker = await Isolate.spawn<_ProgressWork<T>>(
        _progressWorkEntry<T>,
        _ProgressWork(operation, messages.sendPort),
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
      cancellationPoll = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (completed.isCompleted) return;
        try {
          if (isCancelled()) throw const TranslationCancelledException();
        } catch (error, stack) {
          completed.completeError(error, stack);
        }
      });
      return await completed.future;
    } finally {
      cancellationPoll?.cancel();
      // Synchronous file operations cannot receive a cooperative port message
      // while encoding. Let file-producing workers unwind and close handles
      // before termination; CPU-only workers remain immediately killable.
      if (finishBeforeCancellation && worker != null) await exited.future;
      worker?.kill(priority: Isolate.immediate);
      // Await termination, not just the kill request. File-producing callers
      // can then clean their owned temp without racing a still-running writer.
      if (worker != null) await exited.future;
      await subscription.cancel();
      messages.close();
    }
  }

  static Future<T> _prepareWithCooperativeCancel<T>({
    required Future<T> Function(
      void Function(int, int) emitProgress,
      bool Function() isCancelled,
    )
    operation,
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
  }) async {
    if (isCancelled()) throw const TranslationCancelledException();
    final messages = ReceivePort();
    final completed = Completer<T>();
    final exited = Completer<void>();
    SendPort? controlSendPort;
    bool stopRequested = false;
    void requestStop() {
      stopRequested = true;
      controlSendPort?.send('cancel');
    }

    Isolate? worker;
    Timer? cancellationPoll;
    final subscription = messages.listen((dynamic message) {
      if (message == null && !exited.isCompleted) exited.complete();
      if (message is List && message.firstOrNull == 'control') {
        controlSendPort = message[1] as SendPort;
        if (stopRequested) controlSendPort!.send('cancel');
        return;
      }
      if (completed.isCompleted) return;
      try {
        if (isCancelled()) throw const TranslationCancelledException();
        if (message == null) {
          throw StateError('EPUB preparation worker exited without a result.');
        }
        final values = message as List<dynamic>;
        switch (values[0]) {
          case 'progress':
            onProgress?.call(values[1] as int, values[2] as int);
          case 'result':
            completed.complete(values[1] as T);
          case 'error':
            completed.completeError(
              values[1] as Object,
              values[2] as StackTrace,
            );
          default:
            completed.completeError(
              StateError(values[0].toString()),
              StackTrace.fromString(values[1].toString()),
            );
        }
      } catch (error, stack) {
        requestStop();
        completed.completeError(error, stack);
      }
    });
    try {
      worker = await Isolate.spawn<_CancellableAsyncWork<T>>(
        _cancellableAsyncWorkEntry<T>,
        _CancellableAsyncWork(operation, messages.sendPort),
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
      cancellationPoll = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (completed.isCompleted) return;
        try {
          if (isCancelled()) throw const TranslationCancelledException();
        } catch (error, stack) {
          requestStop();
          completed.completeError(error, stack);
        }
      });
      return await completed.future;
    } finally {
      cancellationPoll?.cancel();
      // This worker owns a native file handle. Its cooperative operation
      // closes the archive before exit, including on cancellation.
      if (worker != null) await exited.future;
      await subscription.cancel();
      messages.close();
    }
  }

  /// Reads and decodes an EPUB into a name -> bytes map on a background isolate.
  static Future<Map<String, Uint8List>> loadArchiveFiles(String inputPath) {
    return Isolate.run(() => _loadArchiveSnapshotSync(inputPath).files);
  }

  /// Hash and decoded entries come from the same read, so an external save
  /// cannot associate an old inspection with a newer file's hash.
  static Future<({Map<String, Uint8List> files, String fingerprint})>
  loadArchiveSnapshot(String inputPath) {
    return Isolate.run(() => _loadArchiveSnapshotSync(inputPath));
  }

  /// Inflate only package metadata and the entries selected from its OPF.
  /// The selector runs in the worker; binary resources never cross isolates.
  static Future<({Map<String, Uint8List> files, String fingerprint})>
  loadInspectionSnapshot(
    String inputPath, {
    required Set<String> Function(Map<String, List<int>> files, String opfPath)
    selectEntries,
    bool Function()? isCancelled,
    // Test-only: shrinks the cross-entry actual-inflated-bytes cap (P1-#2)
    // so the cumulative enforcement is exercisable without a 512 MiB bomb.
    int? totalInflatedLimitOverrideForTest,
  }) async {
    final cancelled = isCancelled ?? () => false;
    if (cancelled()) throw const TranslationCancelledException();
    return _prepareWithCooperativeCancel(
      operation: _inspectionOperation(
        inputPath,
        selectEntries,
        totalInflatedLimitOverrideForTest,
      ),
      isCancelled: cancelled,
    );
  }

  // Build sendable closures in scopes containing only worker data, never UI
  // cancellation callbacks/tokens (which can capture unsendable state).
  static Future<({Map<String, Uint8List> files, String fingerprint})> Function(
    void Function(int, int),
    bool Function(),
  )
  _inspectionOperation(
    String inputPath,
    Set<String> Function(Map<String, List<int>>, String) selectEntries,
    // Test-only: shrinks the cross-entry actual-inflated-bytes cap (P1-#2)
    // so the cumulative enforcement is exercisable without a 512 MiB bomb.
    // A positional (not optional-named) parameter: this signature's
    // function-typed parameter trips a Dart parser quirk when `{` follows
    // it and the body is a block.
    int? totalInflatedLimitOverride,
  ) {
    return (
      void Function(int, int) emitProgress,
      bool Function() workerCancelled,
    ) async {
      final OpenedEpubArchive opened = await openStreamingEpubArchiveAsync(
        inputPath: inputPath,
        isFileLockError: EpubOutputRecovery.isFileLockError,
        isCancelled: workerCancelled,
        buildCancelledError: () => const TranslationCancelledException(),
        onHashProgress: emitProgress,
      );
      try {
        final Archive archive = opened.archive;
        final files = <String, Uint8List>{};
        int totalInflatedBytes = 0;
        // Guard cumulative actual-inflated bytes across selected entries.
        final int totalLimit =
            totalInflatedLimitOverride ?? _kMaxEpubUncompressedBytes;
        void read(String name) {
          if (files.containsKey(name)) return;
          final file = archive.find(name);
          if (file == null || !file.isFile) return;
          final content = _fileBytes(file, inputPath: inputPath);
          totalInflatedBytes += content.length;
          if (totalInflatedBytes > totalLimit) {
            throw EpubDecompressionLimitException(
              inputPath: inputPath,
              compressedBytes: opened.compressedBytes,
              uncompressedBytes: totalInflatedBytes,
              limitBytes: totalLimit,
            );
          }
          files[name] = Uint8List.fromList(content);
        }

        read('META-INF/container.xml');
        final containerBytes = files['META-INF/container.xml'];
        if (containerBytes == null) {
          throw const FormatException(
            'Invalid EPUB: META-INF/container.xml is missing.',
          );
        }
        final container = xml.XmlDocument.parse(
          decodeEpubText(
            bytes: containerBytes,
            filePath: 'META-INF/container.xml',
            strict: true,
          ),
        );
        final rootfile = container.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local == 'rootfile')
            .firstOrNull;
        if (rootfile == null) {
          throw const FormatException(
            'Invalid EPUB: META-INF/container.xml is missing a rootfile entry.',
          );
        }
        final opfPath = rootfile.getAttribute('full-path');
        if (opfPath == null || opfPath.isEmpty) {
          throw const FormatException(
            'Invalid EPUB: rootfile entry has an empty full-path attribute.',
          );
        }
        read(opfPath);
        final Set<String> selected = await prepareWithProgress(
          operation: _inspectionSelection(selectEntries, files, opfPath),
          isCancelled: workerCancelled,
        );
        final Stopwatch slice = Stopwatch()..start();
        for (final name in selected) {
          if (workerCancelled()) throw const TranslationCancelledException();
          read(name);
          if (slice.elapsedMilliseconds >= 8) {
            await Future<void>.delayed(Duration.zero);
            slice.reset();
          }
        }
        return (files: files, fingerprint: opened.fingerprint);
      } finally {
        opened.closeSync();
      }
    };
  }

  // Keep the potentially expensive selector interruptible without killing the
  // isolate that owns the open archive. Only the inspected metadata crosses
  // into the selector worker.
  static Set<String> Function(void Function(int, int)) _inspectionSelection(
    Set<String> Function(Map<String, List<int>>, String) selectEntries,
    Map<String, List<int>> files,
    String opfPath,
  ) =>
      (_) => selectEntries(files, opfPath);

  /// Same synchronous extractor semantics, but the outer isolate is killable;
  /// nesting the extractor's Isolate.run would leave that child unmanaged.
  static Future<
    ({List<InspectedChapter> chapters, Map<String, String> sourceDigests})
  >
  inspectChapterBatchCancellable({
    required Map<String, List<int>> chapters,
    required EpubHtmlExtractor extractor,
    required bool Function() isCancelled,
    bool fingerprintChapters = false,
  }) => prepareWithProgress(
    operation: _chapterOperation(chapters, extractor, fingerprintChapters),
    isCancelled: isCancelled,
  );

  static ({List<InspectedChapter> chapters, Map<String, String> sourceDigests})
  Function(void Function(int, int))
  _chapterOperation(
    Map<String, List<int>> chapters,
    EpubHtmlExtractor extractor,
    bool fingerprintChapters,
  ) =>
      (_) => (
        chapters: [
          for (final entry in chapters.entries)
            extractor.inspectChapterBytes(
              chapterPath: entry.key,
              bytes: entry.value,
            ),
        ],
        sourceDigests: {
          if (fingerprintChapters)
            for (final entry in chapters.entries)
              entry.key: sha256.convert(entry.value).toString(),
        },
      );

  /// Only the small title crosses the isolate boundary. ZIP limits and source
  /// identity still apply, but only container.xml and its OPF are inflated.
  static Future<String?> readBookTitle(
    String inputPath, {
    String? expectedSourceFingerprint,
  }) {
    return Isolate.run(
      () => _readBookTitleSync(
        inputPath,
        expectedSourceFingerprint: expectedSourceFingerprint,
      ),
    );
  }

  /// Visible for testing: [readBookTitle] with a shrunk inflate cap, so the
  /// P2-#14 loud-failure path is exercisable without a 512 MiB bomb.
  @visibleForTesting
  static Future<String?> readBookTitleForTest(
    String inputPath, {
    required int limitBytes,
  }) => Isolate.run(
    () => _readBookTitleSync(inputPath, limitBytesOverride: limitBytes),
  );

  static String? _readBookTitleSync(
    String inputPath, {
    String? expectedSourceFingerprint,
    int? limitBytesOverride,
  }) {
    final OpenedEpubArchive opened = _openEpubArchive(
      inputPath,
      expectedSourceFingerprint,
    );
    try {
      final archive = opened.archive;
      final containerFile = archive.find('META-INF/container.xml');
      if (containerFile == null || !containerFile.isFile) return null;
      final container = xml.XmlDocument.parse(
        decodeEpubText(
          bytes: _fileBytes(
            containerFile,
            inputPath: inputPath,
            limitBytesOverride: limitBytesOverride,
          ),
          filePath: 'META-INF/container.xml',
          strict: true,
        ),
      );
      final opfPath = container.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local == 'rootfile')
          .firstOrNull
          ?.getAttribute('full-path');
      if (opfPath == null || opfPath.isEmpty) return null;
      final opfFile = archive.find(opfPath);
      if (opfFile == null || !opfFile.isFile) return null;
      final opf = xml.XmlDocument.parse(
        decodeEpubText(
          bytes: _fileBytes(
            opfFile,
            inputPath: inputPath,
            limitBytesOverride: limitBytesOverride,
          ),
          filePath: opfPath,
          strict: true,
        ),
      );
      final title = opf.descendants
          .whereType<xml.XmlElement>()
          .where(
            (e) =>
                e.name.local == 'title' &&
                e.name.namespaceUri == 'http://purl.org/dc/elements/1.1/',
          )
          .firstOrNull
          ?.innerText
          .trim();
      return title == null || title.isEmpty ? null : title;
    } on EpubDecompressionLimitException {
      // P2-#14: a zip-bomb guard tripping while reading the title must
      // fail loudly, not degrade into "the book has no title" — swallowing
      // it here would let a malicious archive continue into translation.
      rethrow;
    } catch (_) {
      return null;
    } finally {
      opened.closeSync();
    }
  }

  /// Read only package language declarations; XHTML quotations are not book
  /// languages. Keep the original order for subsequent review conversions.
  static List<String> bookLanguages(Map<String, List<int>> files) {
    final containerBytes = files['META-INF/container.xml'];
    if (containerBytes == null) return [];
    final container = xml.XmlDocument.parse(
      decodeEpubText(
        bytes: containerBytes,
        filePath: 'META-INF/container.xml',
        strict: true,
      ),
    );
    final opfPath = container.descendants
        .whereType<xml.XmlElement>()
        .where((e) => e.name.local == 'rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    final bytes = files[opfPath];
    if (bytes == null || opfPath == null) return [];
    final opf = xml.XmlDocument.parse(
      decodeEpubText(bytes: bytes, filePath: opfPath, strict: true),
    );
    final metadata = opf.rootElement.childElements
        .where(
          (e) =>
              e.name.local == 'metadata' &&
              (e.namespaceUri == 'http://www.idpf.org/2007/opf' ||
                  e.namespaceUri == null),
        )
        .firstOrNull;
    return (metadata?.childElements ?? const <xml.XmlElement>[])
        .where(
          (e) =>
              e.name.local == 'language' &&
              e.namespaceUri == 'http://purl.org/dc/elements/1.1/',
        )
        .map((e) => e.innerText.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  static Future<List<String>> readBookLanguages(
    String inputPath, {
    String? expectedSourceFingerprint,
  }) => Isolate.run(() {
    final opened = _openEpubArchive(inputPath, expectedSourceFingerprint);
    try {
      return bookLanguages(
        _LazyArchiveView(opened.archive, inputPath: inputPath),
      );
    } finally {
      opened.closeSync();
    }
  });

  /// Repacks an EPUB, replacing selected XHTML payloads, on a background isolate.
  ///
  /// Writes to a same-directory temp file first, then commits to [outputFilePath]
  /// only after encoding succeeds. [shouldCommit] is also polled during ZIP
  /// work; refusal waits for handle closure and cleans its temp. Legacy shouldCommit
  /// callers receive false (the repacker converts it to cancellation); explicit
  /// [isCancelled] callers receive [TranslationCancelledException].
  ///
  /// [navigationLabelsByPath] / [navigationLanguageTag] let the isolate render
  /// OPF/NCX navigation metadata from the same decoded archive in one pass, so
  /// callers never have to load the whole book into the main isolate just to
  /// read three small XML files.
  ///
  /// When [shouldCommit] returns false after the isolate finishes (e.g. cancel),
  /// the temp file is deleted and the existing final output is left untouched.
  /// Returns `true` when the final file was committed, `false` when
  /// [shouldCommit] refused the commit (temp cleaned; final path untouched).
  ///
  /// [lockedMessage] builds the localized error for a locked output file; see
  /// [OutputFileLockedException]. When omitted, a plain English message is
  /// used.
  static Future<bool> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    List<String>? sourceLanguageTags,
    bool bilingual = false,
    bool Function()? shouldCommit,
    bool Function()? isCancelled,
    String Function(String outputPath, String tempPath)? lockedMessage,
    String? expectedSourceFingerprint,
    String? translatedTitle,
    Map<String, String>? outputHtmlHashes,
  }) async {
    // Reserve a unique path in the parent before spawning. A killed worker
    // cannot report its path or run finally; parent ownership enables cleanup.
    final String tempPath =
        '$outputFilePath.tmp.${DateTime.now().microsecondsSinceEpoch}';
    final File tempFile = File(tempPath);
    try {
      final hashes = await prepareWithProgress(
        operation: _exportOperation(
          inputPath,
          outputFilePath,
          tempPath,
          translatedHtmlByPath,
          navigationLabelsByPath,
          navigationLanguageTag,
          bilingual,
          expectedSourceFingerprint,
          translatedTitle,
          sourceLanguageTags,
          outputHtmlHashes != null,
        ),
        isCancelled: () =>
            (isCancelled?.call() ?? false) ||
            (shouldCommit != null && !shouldCommit()),
        finishBeforeCancellation: true,
      );
      if (isCancelled?.call() ?? false) {
        throw const TranslationCancelledException();
      }
      if (shouldCommit != null && !shouldCommit()) {
        await EpubOutputRecovery.deleteQuietly(tempFile);
        return false;
      }
      final committed = await commitTempFile(
        tempFile,
        File(outputFilePath),
        shouldCommit: () =>
            !(isCancelled?.call() ?? false) && (shouldCommit?.call() ?? true),
        lockedMessage: lockedMessage,
      );
      if (committed) outputHtmlHashes?.addAll(hashes);
      return committed;
    } catch (error) {
      // A failed commit keeps its temp file by design (see
      // OutputFileRecoveryException): deleting it here would destroy the
      // recovery path commitTempFile just preserved.
      if (error is! OutputFileRecoveryException) {
        await EpubOutputRecovery.deleteQuietly(tempFile);
      }
      // Keep the established bool contract for commit-veto-only callers;
      // the repacker already turns false into TranslationCancelledException.
      if (error is TranslationCancelledException && isCancelled == null) {
        return false;
      }
      rethrow;
    }
  }

  static Map<String, String> Function(void Function(int, int)) _exportOperation(
    String inputPath,
    String outputFilePath,
    String tempPath,
    Map<String, String> html,
    Map<String, String> labels,
    String? language,
    bool bilingual,
    String? fingerprint,
    String? title,
    List<String>? sourceLanguages,
    bool collectHashes,
  ) => (_) {
    final hashes = <String, String>{};
    _writeTranslatedEpubToTempSync(
      inputPath: inputPath,
      outputFilePath: outputFilePath,
      translatedHtmlByPath: html,
      navigationLabelsByPath: labels,
      navigationLanguageTag: language,
      bilingual: bilingual,
      expectedSourceFingerprint: fingerprint,
      translatedTitle: title,
      sourceLanguageTags: sourceLanguages,
      ownedTempPath: tempPath,
      outputHtmlHashes: collectHashes ? hashes : null,
    );
    return hashes;
  };

  /// Test seam: write only the temp payload without committing.
  static Future<String> writeTranslatedEpubToTempForTest({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    bool bilingual = false,
  }) {
    return Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
        navigationLabelsByPath: navigationLabelsByPath,
        navigationLanguageTag: navigationLanguageTag,
        bilingual: bilingual,
      ),
    );
  }

  /// Renders OPF/NCX navigation metadata replacements (target language tag +
  /// translated chapter labels) from already-decoded archive bytes. Pure
  /// function: safe to call on a background isolate or in tests.
  static Map<String, String> renderNavigationMetadata({
    required Map<String, List<int>> archiveFiles,
    required Map<String, String> labelsByPath,
    required String? languageTag,
    bool bilingual = false,
    Map<String, String> renderedHtmlByPath = const <String, String>{},
    String? translatedTitle,
    List<String>? sourceLanguageTags,
  }) {
    // Unknown language only prevents language annotations, not already-paid
    // title/label translations. Preserve existing language metadata verbatim.
    final List<int>? containerBytes = archiveFiles['META-INF/container.xml'];
    if (containerBytes == null) {
      return const <String, String>{};
    }
    final xml.XmlDocument container = xml.XmlDocument.parse(
      decodeEpubText(
        bytes: containerBytes,
        filePath: 'META-INF/container.xml',
        strict: true,
      ),
    );
    final xml.XmlElement rootFile = container.descendants
        .whereType<xml.XmlElement>()
        .firstWhere(
          (xml.XmlElement element) => element.name.local == 'rootfile',
          orElse: () => xml.XmlElement(xml.XmlName('missing')),
        );
    final String opfPath = rootFile.getAttribute('full-path') ?? '';
    final List<int>? opfBytes = archiveFiles[opfPath];
    if (opfPath.isEmpty || opfBytes == null) {
      return const <String, String>{};
    }

    final xml.XmlDocument opf = xml.XmlDocument.parse(
      decodeEpubText(bytes: opfBytes, filePath: opfPath, strict: true),
    );
    final metadata = opf.rootElement.childElements
        .where(
          (element) =>
              element.name.local == 'metadata' &&
              (element.namespaceUri == 'http://www.idpf.org/2007/opf' ||
                  element.namespaceUri == null),
        )
        .firstOrNull;
    final List<xml.XmlElement> languages =
        (metadata?.childElements ?? const <xml.XmlElement>[])
            .where(
              (element) =>
                  element.name.local == 'language' &&
                  element.namespaceUri == 'http://purl.org/dc/elements/1.1/',
            )
            .toList();
    if (languageTag != null) {
      if (bilingual && sourceLanguageTags != null) {
        // A monolingual baseline has overwritten the source declarations.
        // Restore their values before applying the usual bilingual policy.
        // Reuse nodes where possible to retain IDs and metadata attributes.
        for (var i = 0; i < sourceLanguageTags.length; i++) {
          if (i < languages.length) {
            languages[i].innerText = sourceLanguageTags[i];
          } else if (metadata != null) {
            final element = _dcLanguageElement(opf, sourceLanguageTags[i]);
            metadata.children.add(element);
            languages.add(element);
          }
        }
        for (var i = sourceLanguageTags.length; i < languages.length; i++) {
          languages[i].innerText = languageTag;
        }
      }
      if (bilingual && languages.isNotEmpty) {
        final seen = <String>{};
        for (final language in languages) {
          final value = language.innerText.trim().toLowerCase();
          if (value.isEmpty || !seen.add(value)) {
            language.parent?.children.remove(language);
          }
        }
        if (!seen.contains(languageTag.toLowerCase())) {
          metadata?.children.add(_dcLanguageElement(opf, languageTag));
        }
      } else if (languages.isEmpty) {
        // No dc:language present: append one instead of skipping, so the
        // finished book still carries the target language.
        if (metadata != null) {
          metadata.children.add(_dcLanguageElement(opf, languageTag));
        }
      } else {
        for (final xml.XmlElement language in languages) {
          language.innerText = languageTag;
        }
        // A bilingual baseline has an extra target declaration. Retain one
        // target entry when converting back, as a direct monolingual export
        // does. Preserve metadata refinements attached to removed IDs.
        final first = languages.first;
        for (final duplicate in languages.skip(1)) {
          final id = duplicate.getAttribute('id');
          if (id != null) {
            final retainedId = first.getAttribute('id') ?? id;
            first.setAttribute('id', retainedId);
            for (final element in opf.descendants.whereType<xml.XmlElement>()) {
              if (element.getAttribute('refines') == '#$id') {
                element.setAttribute('refines', '#$retainedId');
              }
            }
          }
          duplicate.parent?.children.remove(duplicate);
        }
      }
    }

    // Translated book title: update OPF dc:title so e-readers show the
    // target-language title in the library. Fail-safe: any problem leaves
    // the original title untouched.
    final String? newTitle = translatedTitle?.trim();
    if (newTitle != null && newTitle.isNotEmpty && metadata != null) {
      try {
        final xml.XmlElement? titleElement = metadata.childElements
            .where(
              (xml.XmlElement e) =>
                  e.name.local == 'title' &&
                  e.name.namespaceUri == 'http://purl.org/dc/elements/1.1/',
            )
            .firstOrNull;
        if (titleElement != null) {
          titleElement.innerText = newTitle;
          if (languageTag != null) {
            titleElement.setAttribute('xml:lang', languageTag);
          }
        }
      } catch (_) {
        // Keep the original title on any XML manipulation failure.
      }
    }

    final Map<String, String> replacements = <String, String>{
      opfPath: opf.toXmlString(),
    };
    if (opf.rootElement.getAttribute('version') == '2.0') {
      // XHTML 1.1 in EPUB 2 does not allow HTML5 data-* attributes. Keep the
      // generated bilingual marker as a class, after TOC synchronization, so
      // styles and later review exports still identify translated blocks.
      for (final entry in renderedHtmlByPath.entries) {
        if (!entry.value.contains('data-translation=')) continue;
        final document = xml.XmlDocument.parse(entry.value);
        var changed = false;
        for (final element
            in document.descendants.whereType<xml.XmlElement>()) {
          if (element.getAttribute('data-translation') != 'true') continue;
          element.removeAttribute('data-translation');
          final classes =
              (element.getAttribute('class') ?? '')
                  .split(RegExp(r'\s+'))
                  .where((c) => c.isNotEmpty)
                  .toSet()
                ..add('epub-translator-translation');
          element.setAttribute('class', classes.join(' '));
          changed = true;
        }
        if (changed) replacements[entry.key] = document.toXmlString();
      }
    }
    for (final item in opf.descendants.whereType<xml.XmlElement>().where(
      (element) =>
          _isOpfManifestChild(element, 'item') &&
          (element.getAttribute('properties') ?? '')
              .split(RegExp(r'\s+'))
              .contains('nav'),
    )) {
      final href = item.getAttribute('href') ?? '';
      final uri = Uri.tryParse(href);
      if (href.isEmpty || uri == null || uri.hasScheme || uri.hasAuthority) {
        continue;
      }
      // Manifest hrefs may carry a "#fragment" (seen in the wild, though
      // unusual); archive keys never contain it. Strip it from the raw href
      // before lookup — mirroring EpubInspector.validateNavigationEncodings
      // — so the nav document is not silently skipped. (Stripping the raw
      // href, not the decoded key, keeps a literal %23 in filenames intact.)
      // A bare "#fragment" with no path cannot resolve to a content
      // document; skip it instead of matching the OPF itself.
      final String hrefPath = href.split('#').first;
      if (hrefPath.isEmpty) {
        continue;
      }
      final navPath = navigationTargetKey(opfPath, hrefPath);
      if (!archiveFiles.containsKey(navPath)) continue;
      // Use rendered content when navigation is also a translated chapter,
      // preserving translated prose outside its toc rather than restoring it.
      final markup =
          renderedHtmlByPath[navPath] ??
          decodeEpubText(
            bytes: archiveFiles[navPath]!,
            filePath: navPath,
            strict: true,
          );
      replacements[navPath] = _synchronizeNavigation(
        markup: markup,
        documentPath: navPath,
        labelsByPath: labelsByPath,
        languageTag: languageTag,
        preserveSourceLabels:
            bilingual && renderedHtmlByPath.containsKey(navPath),
      );
      xml.XmlDocument.parse(replacements[navPath]!);
    }
    final xml.XmlElement? spine = opf.descendants
        .whereType<xml.XmlElement>()
        .where((xml.XmlElement element) => element.name.local == 'spine')
        .firstOrNull;
    final String ncxId = spine?.getAttribute('toc') ?? '';
    final items = opf.descendants.whereType<xml.XmlElement>().where(
      (item) => _isOpfManifestChild(item, 'item'),
    );
    final explicit = items
        .where(
          (item) =>
              ncxId.isNotEmpty &&
              item.getAttribute('id') == ncxId &&
              (item.getAttribute('href') ?? '').isNotEmpty,
        )
        .firstOrNull;
    final fallback = items
        .where(
          (item) =>
              item.getAttribute('media-type') == 'application/x-dtbncx+xml' &&
              (item.getAttribute('href') ?? '').isNotEmpty,
        )
        .firstOrNull;
    final ncxItem = explicit ?? fallback;
    final String ncxHref = ncxItem?.getAttribute('href') ?? '';
    if (ncxHref.isEmpty) {
      return replacements;
    }
    final String ncxPath = path.posix.normalize(
      path.posix.join(
        path.posix.dirname(opfPath),
        // Manifest hrefs are URI-encoded while archive entry names are
        // decoded; decode defensively (falling back to the raw href) so an
        // encoded NCX file name still resolves, mirroring the `content src`
        // handling via _decodeNcxSrc below.
        _decodeNcxSrc(ncxHref),
      ),
    );
    final List<int>? ncxBytes = archiveFiles[ncxPath];
    if (ncxBytes == null) {
      return replacements;
    }

    final xml.XmlDocument ncx = xml.XmlDocument.parse(
      decodeEpubText(bytes: ncxBytes, filePath: ncxPath, strict: true),
    );
    if (languageTag != null) {
      ncx.rootElement.setAttribute('xml:lang', languageTag);
    }
    // Translated book title: keep NCX docTitle in sync with OPF dc:title.
    final String? ncxTitle = translatedTitle?.trim();
    if (ncxTitle != null && ncxTitle.isNotEmpty) {
      try {
        final xml.XmlElement? docTitleText = ncx.descendants
            .whereType<xml.XmlElement>()
            .where((xml.XmlElement e) => e.name.local == 'docTitle')
            .firstOrNull
            ?.descendants
            .whereType<xml.XmlElement>()
            .where((xml.XmlElement e) => e.name.local == 'text')
            .firstOrNull;
        if (docTitleText != null) {
          docTitleText.innerText = ncxTitle;
          if (languageTag != null) {
            // NCX text only permits id/class. Language belongs on docTitle/root.
            docTitleText.removeAttribute('xml:lang');
            (docTitleText.parent as xml.XmlElement).setAttribute(
              'xml:lang',
              languageTag,
            );
          }
        }
      } catch (_) {
        // Keep the original docTitle on any XML manipulation failure.
      }
    }
    for (final xml.XmlElement navPoint
        in ncx.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'navPoint',
        )) {
      final xml.XmlElement? content = navPoint.children
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'content')
          .firstOrNull;
      final String source = content?.getAttribute('src') ?? '';
      if (source.isEmpty) {
        continue;
      }
      final chapterPath = navigationTargetKey(ncxPath, source);
      final String? label = labelsByPath[chapterPath];
      if (label == null) {
        continue;
      }
      final navLabel = navPoint.children
          .whereType<xml.XmlElement>()
          .where((element) => element.name.local == 'navLabel')
          .firstOrNull;
      final xml.XmlElement? text = navLabel?.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'text')
          .firstOrNull;
      if (text != null) {
        text.innerText = label;
      }
    }
    replacements[ncxPath] = ncx.toXmlString();
    return replacements;
  }

  // The shared EPUB 3 helper requires a known tag. For unknown targets use
  // its same TOC/link protections and nullable label primitive, without
  // inventing a tag or removing source language attributes.
  static String _synchronizeNavigation({
    required String markup,
    required String documentPath,
    required Map<String, String> labelsByPath,
    required String? languageTag,
    required bool preserveSourceLabels,
  }) {
    if (languageTag != null) {
      return synchronizeEpub3Navigation(
        markup: markup,
        documentPath: documentPath,
        labelsByPath: labelsByPath,
        languageTag: languageTag,
        preserveSourceLabels: preserveSourceLabels,
      );
    }
    final document = XhtmlHtmlCompatibility.parseDocument(markup);
    var changed = false;
    for (final nav in epubTags(document, const {'nav'})) {
      if (!isEpubTocElement(nav)) continue;
      for (final anchor in epubTags(nav, const {
        'a',
      }).where((a) => a.attributes.containsKey('href'))) {
        if (preserveSourceLabels && !isTranslatedNavigationAnchor(anchor)) {
          continue;
        }
        final href = anchor.attributes['href'] ?? '';
        final uri = Uri.tryParse(href);
        if (href.isEmpty || uri == null || uri.hasScheme || uri.hasAuthority) {
          continue;
        }
        final label = labelsByPath[navigationTargetKey(documentPath, href)];
        if (label == null || anchor.text.trim().isEmpty) continue;
        changed = replaceNavigationAnchorLabel(anchor, label) || changed;
      }
    }
    return changed ? serializeEpubNavigation(document, markup) : markup;
  }

  /// Declare the namespace on the new element itself: a declaration on a
  /// sibling or descendant cannot bind this element's prefix.
  static xml.XmlElement _dcLanguageElement(
    xml.XmlDocument opf,
    String languageTag,
  ) {
    final xml.XmlElement element = xml.XmlElement(
      xml.XmlName.fromString('dc:language'),
      <xml.XmlAttribute>[
        xml.XmlAttribute(
          xml.XmlName.fromString('xmlns:dc'),
          'http://purl.org/dc/elements/1.1/',
        ),
      ],
    );
    element.innerText = languageTag;
    return element;
  }

  /// NCX `content src` values are URI-encoded while [labelsByPath] keys are
  /// decoded archive paths; decode defensively so a malformed escape can't
  /// break the whole navigation pass.
  static String _decodeNcxSrc(String raw) {
    try {
      return Uri.decodeFull(raw);
    } catch (_) {
      return raw;
    }
  }

  /// Atomically-ish replace [finalFile] with fully-written [tempFile].
  ///
  /// Never truncates [finalFile] before the new content is ready. On failure the
  /// original [finalFile] is restored when a backup was taken.
  ///
  /// [shouldCommit] is re-checked before each irreversible rename step so a
  /// cancel between awaits cannot leave a half-committed final file.
  /// Returns `false` when [shouldCommit] refuses (backup restored if needed).
  ///
  /// A lock probe before translation cannot close the TOCTOU window (the
  /// user may open the output file mid-run), and probing with
  /// `FileMode.append` only checks WRITE access while the commit rename
  /// needs DELETE. So instead of a bigger probe, the failure path is made
  /// recoverable: a locked target throws [OutputFileLockedException] with
  /// the translated temp file preserved, instead of a raw
  /// FileSystemException with the temp file deleted.
  ///
  /// [lockedMessage] builds the localized lock message from the output and
  /// temp paths; when omitted a plain English message is used.
  static Future<bool> commitTempFile(
    File tempFile,
    File finalFile, {
    bool Function()? shouldCommit,
    String Function(String outputPath, String tempPath)? lockedMessage,
    Duration lockTimeout = const Duration(seconds: 45),
  }) => EpubOutputRecovery.commitTempFile(
    tempFile,
    finalFile,
    shouldCommit: shouldCommit,
    lockedMessage: lockedMessage,
    lockTimeout: lockTimeout,
  );

  static bool isFileLockError(FileSystemException error) =>
      EpubOutputRecovery.isFileLockError(error);

  @visibleForTesting
  static Future<void> reclaimStaleBackupsForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => EpubOutputRecovery.reclaimStaleBackups(
    finalFile,
    deleteForTest: deleteForTest,
  );

  @visibleForTesting
  static Future<void> reclaimStaleTempFilesForTest(
    File finalFile,
    File tempFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => EpubOutputRecovery.reclaimStaleTempFiles(
    finalFile,
    tempFile,
    deleteForTest: deleteForTest,
  );

  @visibleForTesting
  static bool sameFilesystemPath(
    String first,
    String second, {
    bool? windows,
  }) => EpubOutputRecovery.sameFilesystemPath(first, second, windows: windows);

  @visibleForTesting
  static Future<File> preserveRecoveryTempForTest(
    File tempFile,
    File finalFile,
  ) => EpubOutputRecovery.preserveRecoveryTemp(tempFile, finalFile);

  @visibleForTesting
  static Future<void> enforceRecoveryBudgetForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => EpubOutputRecovery.enforceRecoveryBudget(
    finalFile,
    deleteForTest: deleteForTest,
  );

  @visibleForTesting
  static Future<void> reclaimRecoveryFilesForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? committedTempFile,
  }) => EpubOutputRecovery.reclaimRecoveryFiles(
    finalFile,
    deleteForTest: deleteForTest,
    committedTempFile: committedTempFile,
  );

  @visibleForTesting
  static void commitTempFileSyncForTest(File tempFile, File finalFile) =>
      EpubOutputRecovery.commitTempFileSyncForTest(tempFile, finalFile);

  @visibleForTesting
  static Future<void> deleteBestEffortForTest(File file) =>
      EpubOutputRecovery.deleteBestEffort(file);

  static OpenedEpubArchive _openEpubArchive(
    String inputPath,
    String? expectedFingerprint,
  ) {
    return openStreamingEpubArchiveSync(
      inputPath: inputPath,
      expectedSourceFingerprint: expectedFingerprint,
      onFingerprintMismatch: checkEpubSourceHash,
      isFileLockError: EpubOutputRecovery.isFileLockError,
    );
  }

  static ({Map<String, Uint8List> files, String fingerprint})
  _loadArchiveSnapshotSync(String inputPath) {
    final OpenedEpubArchive opened = _openEpubArchive(inputPath, null);
    try {
      final Archive archive = opened.archive;
      final Map<String, Uint8List> files = <String, Uint8List>{};
      int totalInflatedBytes = 0;
      for (final ArchiveFile file in archive) {
        if (!file.isFile) {
          continue;
        }
        final Uint8List inflated = Uint8List.fromList(
          _fileBytes(file, inputPath: inputPath),
        );
        totalInflatedBytes += inflated.length;
        if (totalInflatedBytes > _kMaxEpubUncompressedBytes) {
          throw EpubDecompressionLimitException(
            inputPath: inputPath,
            compressedBytes: opened.compressedBytes,
            uncompressedBytes: totalInflatedBytes,
            limitBytes: _kMaxEpubUncompressedBytes,
          );
        }
        files[file.name] = inflated;
      }
      return (files: files, fingerprint: opened.fingerprint);
    } finally {
      opened.closeSync();
    }
  }

  static const int _kMaxEpubUncompressedBytes = kMaxEpubUncompressedBytes;

  /// Collects a synthetic byte source for the chunk-limit regression fixtures.
  /// Production ZIP reads hash and validate the file without collecting it.
  @visibleForTesting
  static Uint8List readChunksGuardedForTest({
    required String inputPath,
    required List<int> Function() nextChunk,
    required int limitBytes,
  }) {
    final bytes = BytesBuilder();
    for (List<int> chunk = nextChunk(); chunk.isNotEmpty; chunk = nextChunk()) {
      checkEpubCompressedSize(
        inputPath: inputPath,
        compressedBytes: bytes.length + chunk.length,
        limitBytes: limitBytes,
        uncompressedBytes: -1,
      );
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @visibleForTesting
  static void checkZipEntryCountForTest(String inputPath, List<int> bytes) {
    checkZipEntryCountReader(
      inputPath: inputPath,
      reader: MemoryRandomAccessReader(bytes),
    );
  }

  @visibleForTesting
  static void checkSymlinkEntrySizesForTest(String inputPath, List<int> bytes) {
    checkSymlinkEntrySizesReader(
      inputPath: inputPath,
      reader: MemoryRandomAccessReader(bytes),
    );
  }

  @visibleForTesting
  static void checkArchiveLimitsForTest({
    required String inputPath,
    required Archive archive,
    required int compressedBytes,
  }) {
    checkArchiveLimits(
      inputPath: inputPath,
      archive: archive,
      compressedBytes: compressedBytes,
    );
  }

  static String _writeTranslatedEpubToTempSync({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    List<String>? sourceLanguageTags,
    bool bilingual = false,
    String? expectedSourceFingerprint,
    String? translatedTitle,
    String? ownedTempPath,
    Map<String, String>? outputHtmlHashes,
  }) {
    // Keep source payloads compressed and share their ArchiveFile objects.
    // Only navigation metadata is inflated; output goes straight to disk.
    final OpenedEpubArchive opened = _openEpubArchive(
      inputPath,
      expectedSourceFingerprint,
    );
    try {
      final Archive sourceArchive = opened.archive;
      // Names occurring more than once in the raw central directory. The
      // decoder merges duplicates in place, so they cannot be counted from the
      // decoded archive (a per-archive name count is always 1).
      final Set<String> duplicateNames = opened.duplicateNames;
      final Archive repacked = Archive();

      // Navigation metadata (OPF language + translated NCX labels) is rendered
      // here from the same decoded archive: one decode pass, and the whole
      // book never has to cross into the main isolate. Navigation entries win
      // on collision, matching the old main-isolate addAll order.
      // Note: unlike chapter HTML, the rendered navigation XML is not passed
      // through _validateXmlReplacements — it is produced by the xml package
      // itself (well-formed by construction), not by model output.
      final Map<String, String> replacements = Map<String, String>.of(
        translatedHtmlByPath,
      );
      // Title/label translations remain useful even for unknown language tags;
      // the renderer independently guards language-only changes.
      final Map<String, List<int>> archiveView = _LazyArchiveView(
        sourceArchive,
        inputPath: inputPath,
      );
      replacements.addAll(
        renderNavigationMetadata(
          archiveFiles: archiveView,
          labelsByPath: navigationLabelsByPath,
          languageTag: navigationLanguageTag,
          sourceLanguageTags: sourceLanguageTags,
          bilingual: bilingual,
          renderedHtmlByPath: translatedHtmlByPath,
          translatedTitle: translatedTitle,
        ),
      );

      // The EPUB spec requires the mimetype entry to exist, be first,
      // uncompressed, and contain exactly "application/epub+zip". A missing
      // entry is synthesized; an empty or whitespace-padded entry (some tools
      // write "application/epub+zip\n") is normalized to the standard value
      // instead of propagating the defect into the output.
      const String standardMimetype = 'application/epub+zip';
      final ArchiveFile? mimetypeFile = sourceArchive.find('mimetype');
      String declaredMimetype = '';
      if (mimetypeFile != null) {
        declaredMimetype = utf8
            .decode(
              _fileBytes(mimetypeFile, inputPath: inputPath),
              allowMalformed: true,
            )
            .trim();
      }
      final List<int> mimetypeBytes = utf8.encode(
        declaredMimetype == standardMimetype
            ? declaredMimetype
            : standardMimetype,
      );
      final ArchiveFile repackedMimetype = ArchiveFile.noCompress(
        'mimetype',
        mimetypeBytes.length,
        mimetypeBytes,
      );
      final int? sourceModTime = mimetypeFile?.lastModTime;
      if (sourceModTime != null) {
        repackedMimetype.lastModTime = sourceModTime;
      }
      final int? sourceMode = mimetypeFile?.mode;
      if (sourceMode != null) {
        repackedMimetype.mode = sourceMode;
      }
      repacked.add(repackedMimetype);

      // The read path (_loadArchiveSnapshotSync) keys entries by name in a Map,
      // so duplicate entry names resolve last-wins there. The copy loop used
      // to emit every copy — including an untranslated first copy of a
      // replaced chapter, which some readers prefer. Dedupe to last-wins so
      // both sides agree on which copy survives. Insertion order (first-seen
      // position) is preserved, so entry ordering is unchanged.
      final Map<String, ArchiveFile> dedupedSource = <String, ArchiveFile>{};
      for (final ArchiveFile sourceFile in sourceArchive) {
        dedupedSource[sourceFile.name] = sourceFile;
      }

      // P-#44: the duplicate CRC check and its repair path inflate the same
      // entry; share one per-repack cache so the payload is inflated once
      // and reused instead of inflating twice.
      final Map<ArchiveFile, List<int>> duplicateBytesCache =
          <ArchiveFile, List<int>>{};
      int duplicateCacheBytes = 0;
      void onDuplicateCacheInsert(ArchiveFile file, List<int> inserted) {
        final int compressedBytes = file.rawContent is ZipFile
            ? (file.rawContent as ZipFile).compressedSize
            : inserted.length;
        duplicateCacheBytes = checkDuplicateCacheBudgetForTest(
          currentTotalBytes: duplicateCacheBytes,
          insertedBytes: inserted,
          inputPath: inputPath,
          compressedBytes: compressedBytes,
        );
      }

      for (final ArchiveFile sourceFile in dedupedSource.values) {
        if (sourceFile.name == 'mimetype') {
          continue;
        }
        if (!sourceFile.isFile) {
          repacked.add(
            ArchiveFile.directory(sourceFile.name)
              ..lastModTime = sourceFile.lastModTime
              ..mode = sourceFile.mode,
          );
          continue;
        }

        final String? replacement = replacements[sourceFile.name];
        if (replacement != null) {
          final List<int> utf8Bytes = utf8.encode(replacement);
          if (outputHtmlHashes != null) {
            outputHtmlHashes[sourceFile.name] = sha256
                .convert(utf8Bytes)
                .toString();
          }
          repacked.add(
            ArchiveFile.bytes(sourceFile.name, utf8Bytes)
              ..compression = sourceFile.compression
              ..lastModTime = sourceFile.lastModTime
              ..mode = sourceFile.mode,
          );
          continue;
        }

        // Compressed pass-through reuses the source payload verbatim, but for
        // duplicate entry names the decoded ArchiveFile is corrupt by
        // construction: ZipDecoder keeps the FIRST duplicate's payload while
        // overwriting crc32 with the LAST duplicate's value. ZipEncoder would
        // then write a CRC that does not match the content. Verify the stored
        // CRC against the payload for duplicates and recompress on mismatch
        // so the encoder writes a correct CRC.
        //
        // The trigger is deliberately NOT a per-archive name count: the
        // decoder merges duplicates in place, so counting names over the
        // decoded archive is always 1 and that branch could never fire.
        // Duplicates are detected from the raw central-directory headers
        // ([DecodedEpubArchive.duplicateNames]) instead. Deleting the branch
        // instead would regress the corrupt-CRC protection (see
        // b_round7_regression_test.dart #28, which asserts valid CRCs in the
        // repacked output for duplicate entries).
        if (duplicateNames.contains(sourceFile.name) &&
            !_storedCrcMatchesPayload(
              sourceFile,
              inputPath: inputPath,
              bytesCache: duplicateBytesCache,
              onCacheInsert: onDuplicateCacheInsert,
            )) {
          final List<int> payload = _fileBytes(
            sourceFile,
            inputPath: inputPath,
            bytesCache: duplicateBytesCache,
            onCacheInsert: onDuplicateCacheInsert,
          );
          AppLogger.warn(
            'Duplicate entry "${sourceFile.name}" has a CRC mismatch; '
            'recompressing instead of reusing the stored payload.',
            tag: 'repack',
          );
          repacked.add(
            ArchiveFile.bytes(sourceFile.name, payload)
              ..compression = sourceFile.compression
              ..lastModTime = sourceFile.lastModTime
              ..mode = sourceFile.mode,
          );
          continue;
        }

        repacked.add(sourceFile);
      }

      final File outputFile = File(outputFilePath);
      outputFile.parent.createSync(recursive: true);

      final String tempPath =
          ownedTempPath ??
          path.join(
            outputFile.parent.path,
            '${path.basename(outputFilePath)}.tmp.${DateTime.now().microsecondsSinceEpoch}',
          );
      final File tempFile = File(tempPath);
      try {
        final output = OutputFileStream(tempPath);
        try {
          ZipEncoder().encodeStream(repacked, output);
        } finally {
          output.closeSync();
        }
        // OutputFileStream.flush drains its buffer but does not fsync. Preserve
        // the previous flush:true durability before exposing a committable temp.
        final handle = tempFile.openSync(mode: FileMode.append);
        try {
          handle.flushSync();
        } finally {
          handle.closeSync();
        }
        return tempFile.path;
      } catch (error) {
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }
        rethrow;
      }
    } finally {
      opened.closeSync();
    }
  }

  /// Inflates [file]'s content, guarding against zip-bomb entries that lie
  /// about their header-declared size.
  ///
  /// The preflight ([checkArchiveLimitsForTest]) only accumulates the
  /// header-declared [ArchiveFile.size], so a malicious entry can declare a
  /// tiny size while inflating to gigabytes and sail through it. Lazily
  /// decoded entries (whose [ArchiveFile.rawContent] is a [ZipFile]) are
  /// therefore inflated through [_GuardedInflateStream], which counts the
  /// ACTUAL decompressed bytes as they arrive and throws
  /// [EpubDecompressionLimitException] the moment the cap is exceeded — the
  /// inflate aborts mid-stream instead of materializing the payload first.
  /// Already-materialized entries (built in memory by the repacker) hold no
  /// attacker-controlled bytes and take the direct path. Like the old
  /// `rawContent.getStream()` shape, this never memoizes into
  /// [ArchiveFile.content], so [ArchiveFile.isCompressed] stays intact for
  /// the repacker's compressed pass-through.
  static List<int> _fileBytes(
    ArchiveFile file, {
    String inputPath = '',
    Map<ArchiveFile, List<int>>? bytesCache,
    void Function(ArchiveFile file, List<int> inserted)? onCacheInsert,
    // Test-only: shrinks the per-entry inflate cap (P2-#14) so the guard is
    // exercisable without a 512 MiB bomb.
    int? limitBytesOverride,
  }) {
    final FileContent? raw = file.rawContent;
    if (raw is ZipFile) {
      // P-#44: callers that inflate the same entry twice in a row (CRC
      // verification followed by the repair path) share one cache so the
      // second call reuses the first call's bytes instead of inflating
      // again. The cache is caller-owned and never escapes the operation,
      // and nothing is memoized into ArchiveFile.content, so
      // ArchiveFile.isCompressed stays intact for the repacker.
      final int limit = limitBytesOverride ?? _kMaxEpubUncompressedBytes;
      if (bytesCache != null) {
        return bytesCache.putIfAbsent(file, () {
          final List<int> bytes = _inflateZipFileGuarded(
            inputPath: inputPath,
            file: file,
            zipFile: raw,
            limitBytes: limit,
          );
          onCacheInsert?.call(file, bytes);
          return bytes;
        });
      }
      return _inflateZipFileGuarded(
        inputPath: inputPath,
        file: file,
        zipFile: raw,
        limitBytes: limit,
      );
    }
    final Object content = file.content;
    if (content is Uint8List) {
      return content;
    }
    if (content is List<int>) {
      return content;
    }
    if (content is String) {
      return utf8.encode(content);
    }
    return <int>[];
  }

  static Uint8List _inflateZipFileGuarded({
    required String inputPath,
    required ArchiveFile file,
    required ZipFile zipFile,
    required int limitBytes,
  }) {
    // getStream(decompress: false) returns the raw payload stream, decrypting
    // first when needed (mirroring ZipFile.decompress). The stream position
    // is restored in finally: ZipFile.decompress does not restore it when the
    // output throws, and our guard aborts mid-inflate by throwing — without
    // this, a guarded entry would be left at EOS for any later use.
    final InputStream compressed = zipFile.getStream(decompress: false);
    final int savePos = compressed.position;
    try {
      if (zipFile.compressionMethod == CompressionType.deflate) {
        final output = _GuardedInflateStream(
          inputPath: inputPath,
          entryName: file.name,
          compressedBytes: zipFile.compressedSize,
          limitBytes: limitBytes,
        );
        _decodeRawInflateChunked(compressed, output);
        return output.getBytes();
      }
      if (zipFile.compressionMethod == CompressionType.bzip2) {
        final output = _GuardedInflateStream(
          inputPath: inputPath,
          entryName: file.name,
          compressedBytes: zipFile.compressedSize,
          limitBytes: limitBytes,
        );
        // BZip2Decoder.decodeStream writes to the output incrementally
        // (byte by byte), so the guard aborts mid-stream here without help.
        BZip2Decoder().decodeStream(compressed, output);
        return output.getBytes();
      }
      // Stored (uncompressed) entries need no inflate work: bound the
      // payload and hand back the source bytes directly instead of copying
      // them through the guard stream's growable buffer (P-#43). The
      // returned view aliases the decoded archive buffer; callers never
      // mutate it.
      if (compressed.length > limitBytes) {
        throw EpubDecompressionLimitException(
          inputPath: '$inputPath!${file.name}',
          compressedBytes: zipFile.compressedSize,
          uncompressedBytes: compressed.length,
          limitBytes: limitBytes,
        );
      }
      return compressed.toUint8List();
    } finally {
      compressed.setPosition(savePos);
    }
  }

  /// Incrementally inflates raw deflate data, feeding the guard stream chunk
  /// by chunk as the native decoder emits them.
  ///
  /// P1-#1: `ZLibDecoder().decodeStream` cannot back the guard — its io
  /// implementation funnels the whole decompressed payload through a
  /// `ChunkedConversionSink.withCallback` that only fires on close, so the
  /// full payload materializes before the guard ever sees a byte. Driving
  /// the chunked conversion manually lets the guard count actual output
  /// bytes per chunk and abort mid-stream the moment the cap is exceeded.
  static void _decodeRawInflateChunked(
    InputStream compressed,
    _GuardedInflateStream output,
  ) {
    final Sink<List<int>> inSink = ZLibCodec(
      raw: true,
    ).decoder.startChunkedConversion(_GuardedChunkSink(output));
    while (!compressed.isEOS) {
      final int remaining = compressed.length;
      final int chunkSize = remaining < 64 * 1024 ? remaining : 64 * 1024;
      inSink.add(compressed.readBytes(chunkSize).toUint8List());
    }
    inSink.close();
  }

  /// Visible for testing: inflate [file] with a caller-owned byte cache
  /// (P-#44), proving the CRC-verification and repair paths share one
  /// inflation instead of decoding the entry twice.
  @visibleForTesting
  static List<int> fileBytesForTest(
    ArchiveFile file, {
    String inputPath = '',
    Map<ArchiveFile, List<int>>? bytesCache,
    void Function(ArchiveFile file, List<int> inserted)? onCacheInsert,
  }) => _fileBytes(
    file,
    inputPath: inputPath,
    bytesCache: bytesCache,
    onCacheInsert: onCacheInsert,
  );

  /// Checks the cumulative inflated payload retained by the duplicate cache.
  @visibleForTesting
  static int checkDuplicateCacheBudgetForTest({
    required int currentTotalBytes,
    required List<int> insertedBytes,
    required String inputPath,
    required int compressedBytes,
    int? budgetBytesOverride,
  }) {
    final int next = currentTotalBytes + insertedBytes.length;
    final int budget = budgetBytesOverride ?? _kMaxEpubUncompressedBytes;
    if (next > budget) {
      throw EpubDecompressionLimitException(
        inputPath: inputPath,
        compressedBytes: compressedBytes,
        uncompressedBytes: next,
        limitBytes: budget,
      );
    }
    return next;
  }

  /// Visible for testing: inflate [file] with a custom byte cap, proving the
  /// guard counts actual decompressed bytes rather than header-declared
  /// sizes (a lying entry declares small but inflates large).
  @visibleForTesting
  static List<int> inflateZipFileGuardedForTest({
    required ArchiveFile file,
    required String inputPath,
    required int limitBytes,
  }) {
    final FileContent? raw = file.rawContent;
    if (raw is ZipFile) {
      return _inflateZipFileGuarded(
        inputPath: inputPath,
        file: file,
        zipFile: raw,
        limitBytes: limitBytes,
      );
    }
    return _fileBytes(file, inputPath: inputPath);
  }

  /// True when the decoded entry's stored CRC32 matches its payload, so the
  /// compressed payload can be passed through to the encoder untouched. A
  /// null stored CRC is fine: the encoder recomputes it. Only duplicate
  /// entry names can corrupt the stored value (the decoder keeps the first
  /// duplicate's payload but overwrites crc32 with the last duplicate's),
  /// so callers only need this check for duplicates.
  static bool _storedCrcMatchesPayload(
    ArchiveFile file, {
    String inputPath = '',
    Map<ArchiveFile, List<int>>? bytesCache,
    void Function(ArchiveFile file, List<int> inserted)? onCacheInsert,
  }) {
    final int? stored = file.crc32;
    if (stored == null) {
      return true;
    }
    try {
      return getCrc32(
            _fileBytes(
              file,
              inputPath: inputPath,
              bytesCache: bytesCache,
              onCacheInsert: onCacheInsert,
            ),
          ) ==
          stored;
    } on EpubDecompressionLimitException {
      // A lying entry must abort via the limit handling, not degrade into a
      // "CRC mismatch → recompress" retry that would inflate it again.
      rethrow;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static bool storedCrcMatchesPayloadForTest(ArchiveFile file) =>
      _storedCrcMatchesPayload(file);
}
