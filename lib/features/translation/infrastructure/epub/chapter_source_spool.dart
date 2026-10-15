import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/io/atomic_file_writer.dart';
import '../../../../shared/logging/app_logger.dart';
import '../../domain/models/inspected_chapter.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub_isolate_worker.dart';
import 'chapter_source_restorer.dart';
import 'epub_source_guard.dart';

/// Run-owned snapshots of the exact prepared sources, retained for retries.
/// JSON, UTF-8 and file I/O all execute on workers; only models cross back.
class ChapterSourceSpool {
  // Public directory injection; storage/ownership remain private.
  // ignore: prefer_initializing_formals
  ChapterSourceSpool({Directory? directory}) : _directory = directory;

  Directory? _directory;
  Future<Directory>? _directoryFuture;
  bool _ownsDirectory = false;
  bool _disposed = false;
  final Map<String, Future<void>> _pending = {};

  static Set<String> Function(Map<String, List<int>>, String) _selectChapter(
    String chapterPath,
  ) =>
      (_, _) => {chapterPath};

  // Static entry points cannot capture the run's cancellation callbacks.
  static Future<InspectedChapter> _save(
    String filePath,
    InspectedChapter chapter,
  ) => Isolate.run(() async {
    final payload = {
      'originalHtml': chapter.originalHtml,
      'body': chapter.body,
      'blocks': [
        for (final block in chapter.blocks)
          {
            'id': block.id,
            'sourceHtml': block.sourceHtml,
            'sourceText': block.sourceText,
          },
      ],
    };
    await writeFileAtomically(File(filePath), jsonEncode(payload));
    // Release only after the atomic commit succeeded.
    return chapter.copyWith(
      originalHtml: '',
      body: '',
      blocks: [
        for (final block in chapter.blocks)
          block.copyWith(sourceHtml: '', sourceText: ''),
      ],
    );
  });

  static Future<InspectedChapter?> _load(
    String filePath,
    InspectedChapter chapter,
    bool blocks,
  ) => Isolate.run(() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    // Skeleton-only exports neither build the block index nor transfer the
    // duplicated per-block sources back to the caller isolate.
    final sources = blocks
        ? {
            for (final item in json['blocks'] as List<dynamic>)
              (item as Map<String, dynamic>)['id'] as String: item,
          }
        : const <String, dynamic>{};
    return chapter.copyWith(
      originalHtml: json['originalHtml'] as String,
      body: json['body'] as String,
      blocks: blocks
          ? [
              for (final block in chapter.blocks)
                block.copyWith(
                  sourceHtml: sources[block.id]?['sourceHtml'] as String?,
                  sourceText: sources[block.id]?['sourceText'] as String?,
                ),
            ]
          : chapter.blocks,
    );
  });

  Future<File> _file(String chapterPath) async {
    if (_directory == null) {
      final pending = _directoryFuture ??= Directory.systemTemp.createTemp(
        'epub-chapter-sources-',
      );
      try {
        _directory = await pending;
        _ownsDirectory = true;
      } catch (_) {
        if (identical(_directoryFuture, pending)) _directoryFuture = null;
        rethrow;
      }
    }
    return File(
      path.join(
        _directory!.path,
        '${sha256.convert(utf8.encode(chapterPath))}.json',
      ),
    );
  }

  Future<T> _enqueue<T>(String chapterPath, Future<T> Function() action) {
    if (_disposed) return Future.error(StateError('Source spool is disposed.'));
    final previous = _pending[chapterPath] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    // A failed operation must not poison the queue or create an unhandled
    // error on its tail. Readers and writers observe invocation order.
    final settled = operation.then<void>((_) {}, onError: (_, _) {});
    _pending[chapterPath] = settled;
    return operation.whenComplete(() {
      if (identical(_pending[chapterPath], settled)) {
        _pending.remove(chapterPath);
      }
    });
  }

  Future<InspectedChapter> release(
    InspectedChapter chapter,
  ) => _enqueue(chapter.path, () async {
    try {
      final file = await _file(chapter.path);
      return await _save(file.path, chapter);
    } catch (error) {
      AppLogger.warn(
        'Source release skipped (${error.runtimeType}); keeping retry sources.',
        tag: 'translate',
      );
      return chapter;
    }
  });

  Future<InspectedChapter> restore(
    InspectedChapter chapter, {
    bool blocks = true,
    bool Function()? isCancelled,
  }) => _enqueue(chapter.path, () async {
    void throwIfCancelled() {
      if (isCancelled?.call() ?? false) {
        throw const TranslationCancelledException();
      }
    }

    throwIfCancelled();
    if (chapter.originalHtml.isNotEmpty &&
        (!blocks || chapter.blocks.every((b) => b.sourceHtml.isNotEmpty))) {
      return chapter;
    }
    final file = await _file(chapter.path);
    throwIfCancelled();
    final snapshot = await _load(file.path, chapter, blocks);
    throwIfCancelled();
    if (snapshot != null) return snapshot;

    // The guarded input archive remains a fallback if a temporary snapshot
    // disappeared. Preserve exact source identity and existing translations.
    var source = chapter;
    if (source.originalHtml.isEmpty) {
      final identity = source.sourceIdentity;
      if (identity == null) {
        throw FormatException(
          'Released chapter has no recoverable source: ${chapter.path}',
        );
      }
      final chapterPath = chapter.path;
      final archive = await EpubIsolateWorker.loadInspectionSnapshot(
        identity.inputPath,
        selectEntries: _selectChapter(chapterPath),
      );
      throwIfCancelled();
      checkEpubSourceHash(archive.fingerprint, identity.sha256);
      final bytes = archive.files[chapterPath];
      if (bytes == null) {
        throw FormatException('Source chapter not found: $chapterPath');
      }
      source = source.copyWith(
        originalHtml: utf8.decode(bytes, allowMalformed: true),
      );
    }
    final restored = await ChapterSourceRestorer.restoreChapter(
      chapter: source,
      isCancelled: () => isCancelled?.call() ?? false,
    );
    throwIfCancelled();
    final translations = {
      for (final block in chapter.blocks) block.id: block.translatedHtml,
    };
    return restored.copyWith(
      blocks: [
        for (final block in restored.blocks)
          block.copyWith(translatedHtml: translations[block.id]),
      ],
    );
  });

  Future<void> dispose() async {
    _disposed = true;
    await Future.wait(_pending.values.toList());
    if (!_ownsDirectory) return;
    try {
      await _directory?.delete(recursive: true);
    } on FileSystemException {
      AppLogger.warn('Source spool cleanup deferred.', tag: 'translate');
    }
  }
}
