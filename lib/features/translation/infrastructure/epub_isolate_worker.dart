import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart' as xml;

import '../../../shared/logging/app_logger.dart';
import 'epub/epub_text_decoder.dart';
import 'epub/epub_navigation.dart';
import 'epub/epub_source_guard.dart';

/// A `.tmp.*` file counts as a stale orphan only when older than this. The
/// temp file of a live commit is always seconds old; orphans from a dead
/// previous process or session are far older. An age gate (instead of
/// "older than this process started") is robust against filesystem
/// timestamp granularity (FAT32/exFAT: 2s) and clock skew, and also
/// protects the temp files of a second concurrently running app instance.
const Duration _kStaleTempAge = Duration(minutes: 30);

/// Thrown when the final output file is locked by another process at commit
/// time (Windows: a reader holding it open without share access).
///
/// The fully-translated temp file is deliberately NOT deleted: the user can
/// close the locking program and retry the translation (block cache makes the
/// retry fast with no extra API cost), or rename [tempFilePath] manually.
/// [message] is already localized by the caller via [EpubIsolateWorker.commitTempFile]'s
/// `lockedMessage` callback.
class OutputFileLockedException implements Exception {
  OutputFileLockedException(this.message, this.tempFilePath);

  final String message;
  final String tempFilePath;

  @override
  String toString() => message;
}

/// Thrown when the SOURCE file is locked by another process at read time
/// (Windows: a reader holding it open without share access), mirroring
/// [OutputFileLockedException].
///
/// Unlike the output case there is no temp file to preserve: the read never
/// started, and the block cache on disk is unaffected, so closing the locking
/// program and retrying is cheap. Catchers build the user-facing message via
/// `AppStrings.inputFileLocked`.
class InputFileLockedException implements Exception {
  InputFileLockedException(this.inputPath);

  final String inputPath;

  @override
  String toString() => 'InputFileLockedException: $inputPath';
}

/// Thrown when a source EPUB trips the zip-bomb guards in
/// [_decodeArchiveWithLimits]: the compressed file itself is implausibly
/// large, the header-declared uncompressed total exceeds the cap, the
/// overall compression ratio is absurd, or the entry count exceeds the cap
/// (millions of near-empty entries). Rejected BEFORE any entry content is
/// materialized, so a malicious archive cannot OOM the isolate.
/// Catchers build the user-facing message via
/// `AppStrings.epubDecompressionLimit`.
class EpubDecompressionLimitException implements Exception {
  EpubDecompressionLimitException({
    required this.inputPath,
    required this.compressedBytes,
    required this.uncompressedBytes,
    required this.limitBytes,
  });

  final String inputPath;
  final int compressedBytes;
  final int uncompressedBytes;
  final int limitBytes;

  @override
  String toString() =>
      'EpubDecompressionLimitException: $inputPath expands beyond the '
      'decompression limit ($uncompressedBytes bytes vs $limitBytes allowed).';
}

/// Heavy ZIP work off the UI isolate (Windows/Android).
class EpubIsolateWorker {
  const EpubIsolateWorker._();

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

  /// Only the small title crosses the isolate boundary. The same guarded ZIP
  /// loader and source fingerprint used by inspection apply to this read.
  static Future<String?> readBookTitle(
    String inputPath, {
    String? expectedSourceFingerprint,
  }) {
    return Isolate.run(() {
      final snapshot = _loadArchiveSnapshotSync(inputPath);
      checkEpubSourceHash(snapshot.fingerprint, expectedSourceFingerprint);
      try {
        final container = xml.XmlDocument.parse(
          decodeEpubText(
            bytes: snapshot.files['META-INF/container.xml']!,
            filePath: 'META-INF/container.xml',
            strict: true,
          ),
        );
        final opfPath = container.descendants
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local == 'rootfile')
            .firstOrNull
            ?.getAttribute('full-path');
        if (opfPath == null) return null;
        final opf = xml.XmlDocument.parse(
          decodeEpubText(
            bytes: snapshot.files[opfPath]!,
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
      } catch (_) {
        return null;
      }
    });
  }

  /// Repacks an EPUB, replacing selected XHTML payloads, on a background isolate.
  ///
  /// Writes to a same-directory temp file first, then commits to [outputFilePath]
  /// only after encoding succeeds. Callers should re-check cancellation after this
  /// returns if they need to discard an uncommitted temp (this method commits
  /// only when [shouldCommit] returns true, default always commit).
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
    bool bilingual = false,
    bool Function()? shouldCommit,
    String Function(String outputPath, String tempPath)? lockedMessage,
    String? expectedSourceFingerprint,
    String? translatedTitle,
  }) async {
    final String tempPath = await Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
        navigationLabelsByPath: navigationLabelsByPath,
        navigationLanguageTag: navigationLanguageTag,
        bilingual: bilingual,
        expectedSourceFingerprint: expectedSourceFingerprint,
        translatedTitle: translatedTitle,
      ),
    );

    final File tempFile = File(tempPath);
    try {
      if (shouldCommit != null && !shouldCommit()) {
        await _deleteQuietly(tempFile);
        return false;
      }
      return await commitTempFile(
        tempFile,
        File(outputFilePath),
        shouldCommit: shouldCommit,
        lockedMessage: lockedMessage,
      );
    } catch (error) {
      // A locked output keeps its temp file by design (see
      // OutputFileLockedException): deleting it here would destroy the
      // recovery path commitTempFile just preserved.
      if (error is! OutputFileLockedException) {
        await _deleteQuietly(tempFile);
      }
      rethrow;
    }
  }

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
  }) {
    if (languageTag == null) {
      // The target language is unknown: OPF/NCX navigation metadata is left
      // untouched rather than guessing a language tag.
      AppLogger.info(
        'renderNavigationMetadata: no target language tag; skipping OPF/NCX navigation updates.',
        tag: 'repack',
      );
      return const <String, String>{};
    }
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
            .toList(growable: false);
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
          titleElement.setAttribute('xml:lang', languageTag);
        }
      } catch (_) {
        // Keep the original title on any XML manipulation failure.
      }
    }

    final Map<String, String> replacements = <String, String>{
      opfPath: opf.toXmlString(),
    };
    for (final item in opf.descendants.whereType<xml.XmlElement>().where(
      (element) =>
          element.name.local == 'item' &&
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
      final bytes = archiveFiles[navPath];
      if (bytes == null) continue;
      // Use rendered content when navigation is also a translated chapter,
      // preserving translated prose outside its toc rather than restoring it.
      final markup =
          renderedHtmlByPath[navPath] ??
          decodeEpubText(bytes: bytes, filePath: navPath, strict: true);
      replacements[navPath] = synchronizeEpub3Navigation(
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
      (item) => item.name.local == 'item',
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
    ncx.rootElement.setAttribute('xml:lang', languageTag);
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
          docTitleText.setAttribute('xml:lang', languageTag);
          (docTitleText.parent as xml.XmlElement).setAttribute(
            'xml:lang',
            languageTag,
          );
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
  }) async {
    bool allowCommit() => shouldCommit == null || shouldCommit();

    await finalFile.parent.create(recursive: true);
    if (!await tempFile.exists()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }
    // A previous process may have died between moving the original aside
    // and promoting the temp file, leaving `.bak.*` files behind.
    await _reclaimStaleBackups(finalFile);
    // A previous process may also have died between the isolate returning
    // the temp path and the commit running, leaving `.tmp.*` orphans
    // behind (unlike `.bak.*` files, nothing reclaimed these until now).
    await _reclaimStaleTempFiles(finalFile, tempFile);

    try {
      if (!await finalFile.exists()) {
        if (!allowCommit()) {
          await _deleteQuietly(tempFile);
          return false;
        }
        await tempFile.rename(finalFile.path);
        return true;
      }

      // Dart's File.rename on Windows uses MOVEFILE_REPLACE_EXISTING, so
      // renaming over an existing file works fine; it only throws
      // FileSystemException when the target is locked by another process.
      // Still move final aside first: if promotion fails or commit is refused
      // after the backup move, the backup can be restored instead of losing
      // the original.
      final File backupFile = File(
        '${finalFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}',
      );
      if (!allowCommit()) {
        await _deleteQuietly(tempFile);
        return false;
      }
      await finalFile.rename(backupFile.path);
      try {
        if (!allowCommit()) {
          if (await backupFile.exists() && !await finalFile.exists()) {
            await backupFile.rename(finalFile.path);
          }
          await _deleteQuietly(tempFile);
          return false;
        }
        await tempFile.rename(finalFile.path);
        await _deleteQuietly(backupFile);
        return true;
      } catch (error) {
        if (await backupFile.exists() && !await finalFile.exists()) {
          await backupFile.rename(finalFile.path);
        }
        rethrow;
      }
    } on FileSystemException catch (error) {
      if (isFileLockError(error)) {
        // The output file is locked (Windows sharing violation): keep the
        // translated temp file and report a localized message. The user
        // closes the locking program and retries — the block cache makes
        // the retry fast with no extra API cost — or renames the temp file
        // manually.
        throw OutputFileLockedException(
          lockedMessage?.call(finalFile.path, tempFile.path) ??
              'The output file is locked by another program: ${finalFile.path}. '
                  'The translated file was kept at: ${tempFile.path}',
          tempFile.path,
        );
      }
      await _deleteQuietly(tempFile);
      rethrow;
    } catch (error) {
      await _deleteQuietly(tempFile);
      rethrow;
    }
  }

  /// True when [error] looks like a Windows file-lock (sharing/lock
  /// violation) rather than a different filesystem failure.
  ///
  /// Shared by the EPUB pipeline and the settings store: a sharing violation
  /// (osError 32/33) can only be produced by a real Windows file lock, so the
  /// classification is tested directly with synthetic exceptions.
  static bool isFileLockError(FileSystemException error) {
    // ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION.
    final int? code = error.osError?.errorCode;
    if (code == 32 || code == 33) {
      return true;
    }
    // Prefer the OS-provided message: Dart's FileSystemException.message
    // embeds the file path, and a file literally named
    // "...being used by another process.epub" must not be misclassified
    // as a lock violation.
    const String lockPhrase = 'being used by another process';
    if ((error.osError?.message ?? '').toLowerCase().contains(lockPhrase)) {
      return true;
    }
    // Fallback for exceptions without OSError details: strip the path
    // before matching so a matching file name can't trigger a false
    // positive. (Single-character paths are test artifacts, not real file
    // paths; stripping those would mangle the message itself.)
    String message = error.message.toLowerCase();
    final String? path = error.path;
    if (path != null && path.length > 1) {
      message = message.replaceAll(path.toLowerCase(), '');
    }
    return message.contains(lockPhrase);
  }

  /// Recovers from a commit that died mid-rename: if the final file is
  /// missing but a `.bak.*` backup survived, the newest backup is restored;
  /// remaining stale backups are deleted. Best effort; never throws.
  static Future<void> _reclaimStaleBackups(File finalFile) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.bak.';
      final List<File> backups = <File>[];
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is File && path.basename(entity.path).startsWith(prefix)) {
          backups.add(entity);
        }
      }
      if (backups.isEmpty) {
        return;
      }
      // The timestamp suffix sorts chronologically; the newest is last.
      backups.sort((File a, File b) => a.path.compareTo(b.path));
      if (!await finalFile.exists()) {
        final File newest = backups.removeLast();
        try {
          await newest.rename(finalFile.path);
          AppLogger.warn(
            'Restored ${finalFile.path} from stale backup ${newest.path} '
            'left by an interrupted commit.',
            tag: 'repack',
          );
        } catch (_) {
          // Leave the backup file in place if the restore fails: it is the
          // only surviving copy of the user's output. Older stale backups
          // are still safe to delete below.
        }
      }
      for (final File stale in backups) {
        await _deleteQuietly(stale);
      }
    } catch (_) {
      // Best effort: stale backups must never break a commit.
    }
  }

  /// Deletes `.tmp.*` orphans left by a previous process that died after
  /// the isolate wrote the temp EPUB but before [commitTempFile] promoted
  /// it. Only files older than [_kStaleTempAge] are touched, and the temp
  /// file this commit is about to promote is always excluded — so a live
  /// commit (or a temp deliberately kept by an [OutputFileLockedException]
  /// recovery, or a second app instance's temp) can never be deleted.
  /// Best effort; never throws.
  static Future<void> _reclaimStaleTempFiles(
    File finalFile,
    File tempFile,
  ) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.tmp.';
      final DateTime cutoff = DateTime.now().subtract(_kStaleTempAge);
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File || !path.basename(entity.path).startsWith(prefix)) {
          continue;
        }
        if (entity.path == tempFile.path) {
          continue;
        }
        if ((await entity.lastModified()).isBefore(cutoff)) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {
      // Best effort: stale temps must never break a commit.
    }
  }

  /// Sync helper used by tests that exercise pure filesystem commit logic.
  static void commitTempFileSyncForTest(File tempFile, File finalFile) {
    finalFile.parent.createSync(recursive: true);
    if (!tempFile.existsSync()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }
    if (!finalFile.existsSync()) {
      tempFile.renameSync(finalFile.path);
      return;
    }
    final File backupFile = File(
      '${finalFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      finalFile.renameSync(backupFile.path);
      try {
        tempFile.renameSync(finalFile.path);
        if (backupFile.existsSync()) {
          backupFile.deleteSync();
        }
      } catch (error) {
        if (backupFile.existsSync() && !finalFile.existsSync()) {
          backupFile.renameSync(finalFile.path);
        }
        rethrow;
      }
    } catch (error) {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
      rethrow;
    }
  }

  /// Reads and decodes the source EPUB in a tight scope so the raw download
  /// buffer has no live local reference once decoding returns.
  static Archive _decodeEpubArchive(
    String inputPath,
    String? expectedFingerprint,
  ) {
    final bytes = _readSourceBytesGuarded(inputPath);
    if (expectedFingerprint != null) {
      checkEpubSourceHash(
        sha256.convert(bytes).toString(),
        expectedFingerprint,
      );
    }
    return _decodeArchiveWithLimits(inputPath, bytes);
  }

  static ({Map<String, Uint8List> files, String fingerprint})
  _loadArchiveSnapshotSync(String inputPath) {
    final List<int> bytes = _readSourceBytesGuarded(inputPath);
    final Archive archive = _decodeArchiveWithLimits(inputPath, bytes);
    final Map<String, Uint8List> files = <String, Uint8List>{};
    for (final ArchiveFile file in archive) {
      if (!file.isFile) {
        continue;
      }
      files[file.name] = Uint8List.fromList(_fileBytes(file));
    }
    return (files: files, fingerprint: sha256.convert(bytes).toString());
  }

  /// Zip-bomb guards for [_decodeArchiveWithLimits]. A legitimate EPUB is
  /// tens of megabytes at most; these caps only trip on malicious or
  /// degenerate archives.
  ///
  /// The compressed cap exists because `readAsBytesSync` materializes the
  /// whole file first: without it, a multi-GB fake "EPUB" would OOM the
  /// read itself before decoding even starts.
  static const int _kMaxEpubCompressedBytes = 256 * 1024 * 1024;

  /// Cap on the header-declared uncompressed total across all entries.
  static const int _kMaxEpubUncompressedBytes = 512 * 1024 * 1024;

  /// Cap on total-uncompressed / compressed-bytes. Real books sit far below
  /// this (text compresses ~3-5x, images barely at all); a classic 42.zip
  /// style bomb is many orders of magnitude above it.
  static const int _kMaxCompressionRatio = 100;

  /// Cap on the number of entries in the archive. Real books carry hundreds
  /// to low thousands of entries; tens of thousands is already implausible.
  /// Without this, a bomb of millions of near-empty entries sails under the
  /// size/ratio guards above while every entry still costs a decoded header
  /// object and per-entry processing downstream.
  static const int _kMaxEpubEntryCount = 50000;

  /// Reads the source file with two guards: a cap on the compressed size
  /// (see [_kMaxEpubCompressedBytes]) and Windows file-lock classification
  /// that throws [InputFileLockedException] instead of a raw English
  /// [FileSystemException].
  static List<int> _readSourceBytesGuarded(String inputPath) {
    final File file = File(inputPath);
    final int compressedLength = file.lengthSync();
    if (compressedLength > _kMaxEpubCompressedBytes) {
      throw EpubDecompressionLimitException(
        inputPath: inputPath,
        compressedBytes: compressedLength,
        uncompressedBytes: -1,
        limitBytes: _kMaxEpubCompressedBytes,
      );
    }
    try {
      return file.readAsBytesSync();
    } on FileSystemException catch (error) {
      if (isFileLockError(error)) {
        throw InputFileLockedException(inputPath);
      }
      rethrow;
    }
  }

  /// Decodes ZIP bytes with zip-bomb guards. `archive` decodes lazily, so
  /// the header-declared entry sizes are accumulated BEFORE any entry
  /// content is touched: a malicious archive is rejected without ever
  /// materializing its payload.
  static Archive _decodeArchiveWithLimits(String inputPath, List<int> bytes) {
    checkZipEntryCountForTest(inputPath, bytes);
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    checkArchiveLimitsForTest(
      inputPath: inputPath,
      archive: archive,
      compressedBytes: bytes.length,
    );
    return archive;
  }

  /// The decoder builds *all* central-directory headers before its first
  /// callback, even with decodeStream. Walk their lengths without allocating
  /// entry objects before handing the bytes to it. Count actual headers too:
  /// an attacker can under-report the EOCD count or repeat identical names.
  @visibleForTesting
  static void checkZipEntryCountForTest(String inputPath, List<int> bytes) {
    Never invalid() => throw const FormatException('Invalid ZIP directory.');
    int u16(int at) {
      if (at < 0 || at + 2 > bytes.length) invalid();
      return bytes[at] | (bytes[at + 1] << 8);
    }

    int u32(int at) => u16(at) | (u16(at + 2) << 16);
    int u64(int at) {
      final low = u32(at);
      final high = u32(at + 4);
      // No supported input can need a >32-bit count, size or offset.
      if (high != 0) invalid();
      return low;
    }

    void checkCount(int count) {
      if (count > _kMaxEpubEntryCount) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: bytes.length,
          uncompressedBytes: count,
          limitBytes: _kMaxEpubEntryCount,
        );
      }
    }

    int end = bytes.length - 22;
    final int searchStart = bytes.length - 22 - 65535;
    while (end >= 0 && end >= searchStart) {
      if (u32(end) == 0x06054b50 && end + 22 + u16(end + 20) == bytes.length) {
        break;
      }
      end--;
    }
    if (end < 0 || end < searchStart) invalid();
    if (u16(end + 4) != 0 || u16(end + 6) != 0) invalid();
    int count = u16(end + 10);
    int size = u32(end + 12);
    int offset = u32(end + 16);
    int directoryBoundary = end;
    if (end >= 20 && u32(end - 20) == 0x07064b50) {
      final locator = end - 20;
      if (u32(locator + 4) != 0 || u32(locator + 16) != 1) invalid();
      final zip64 = u64(locator + 8);
      if (zip64 + 56 > locator || u32(zip64) != 0x06064b50) invalid();
      final recordSize = u64(zip64 + 4);
      if (recordSize < 44 || zip64 + 12 + recordSize != locator) invalid();
      if (u32(zip64 + 16) != 0 || u32(zip64 + 20) != 0) invalid();
      count = u64(zip64 + 32);
      checkCount(count);
      if (u64(zip64 + 24) != count) invalid();
      size = u64(zip64 + 40);
      offset = u64(zip64 + 48);
      directoryBoundary = zip64;
    } else {
      checkCount(count);
      if (u16(end + 8) != count) invalid();
    }
    final directoryEnd = offset + size;
    if (directoryEnd != directoryBoundary) invalid();
    int actualCount = 0;
    while (offset < directoryEnd) {
      if (offset + 46 > directoryEnd || u32(offset) != 0x02014b50) {
        invalid();
      }
      checkCount(++actualCount);
      final length =
          46 + u16(offset + 28) + u16(offset + 30) + u16(offset + 32);
      if (offset + length > directoryEnd) invalid();
      offset += length;
    }
    if (actualCount != count) invalid();
  }

  /// Visible for testing: the pure limit check behind
  /// [_decodeArchiveWithLimits]. Takes a decoded [archive] so tests can
  /// feed synthetic entries with huge declared sizes without building a
  /// real multi-hundred-megabyte file.
  @visibleForTesting
  static void checkArchiveLimitsForTest({
    required String inputPath,
    required Archive archive,
    required int compressedBytes,
  }) {
    int entryCount = 0;
    int totalUncompressed = 0;
    for (final ArchiveFile entry in archive) {
      // Count every entry (files and directories): each one costs a decoded
      // header object, so millions of near-empty entries are a DoS vector
      // even when their declared sizes stay under the byte caps below.
      entryCount += 1;
      if (entryCount > _kMaxEpubEntryCount) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: compressedBytes,
          uncompressedBytes: entryCount,
          limitBytes: _kMaxEpubEntryCount,
        );
      }
      if (!entry.isFile) {
        continue;
      }
      totalUncompressed += entry.size;
      if (totalUncompressed > _kMaxEpubUncompressedBytes) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: compressedBytes,
          uncompressedBytes: totalUncompressed,
          limitBytes: _kMaxEpubUncompressedBytes,
        );
      }
    }
    if (totalUncompressed > compressedBytes * _kMaxCompressionRatio) {
      throw EpubDecompressionLimitException(
        inputPath: inputPath,
        compressedBytes: compressedBytes,
        uncompressedBytes: totalUncompressed,
        limitBytes: compressedBytes * _kMaxCompressionRatio,
      );
    }
  }

  /// Encodes the EPUB and writes only a same-directory temp file.
  /// Returns the absolute temp path. Does not touch [outputFilePath].
  static String _writeTranslatedEpubToTempSync({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    bool bilingual = false,
    String? expectedSourceFingerprint,
    String? translatedTitle,
  }) {
    // Memory layout note: at peak this function holds the decoded source
    // archive (decompressed payloads), the repacked archive (mostly shared
    // views of the same payloads, plus replacements), and the encoded output.
    // Two things keep the raw download from adding a fourth full copy:
    //  1. [rawBytes] is released right after decoding: the read+decode is
    //     scoped into a helper so the raw buffer has no live local
    //     reference afterwards. Note the decoder is lazy: every source
    //     ArchiveFile keeps its compressed input (a view into this buffer)
    //     in its raw content slot even after decompression, so this alone
    //     is not enough.
    //  2. After the copy loop below, every source entry's raw+decompressed
    //     slots are cleared. Repacked entries already hold their own
    //     references to the payload buffers (shared Uint8List views), so
    //     only the original download buffer becomes collectable here.
    final Archive sourceArchive = _decodeEpubArchive(
      inputPath,
      expectedSourceFingerprint,
    );
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
    // Render navigation metadata whenever a target language is known, even
    // when no chapter produced a navigation label: the OPF <dc:language>
    // rewrite must still happen (renderNavigationMetadata handles empty
    // labels by only updating the language tag).
    if (navigationLanguageTag != null) {
      final Map<String, List<int>> archiveView = <String, List<int>>{
        for (final ArchiveFile file in sourceArchive)
          if (file.isFile) file.name: _fileBytes(file),
      };
      replacements.addAll(
        renderNavigationMetadata(
          archiveFiles: archiveView,
          labelsByPath: navigationLabelsByPath,
          languageTag: navigationLanguageTag,
          bilingual: bilingual,
          renderedHtmlByPath: translatedHtmlByPath,
          translatedTitle: translatedTitle,
        ),
      );
    }

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
          .decode(_fileBytes(mimetypeFile), allowMalformed: true)
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
        repacked.add(
          ArchiveFile.bytes(sourceFile.name, utf8Bytes)
            ..compression = sourceFile.compression
            ..lastModTime = sourceFile.lastModTime
            ..mode = sourceFile.mode,
        );
        continue;
      }

      final List<int> originalBytes = _fileBytes(sourceFile);
      repacked.add(
        ArchiveFile.bytes(sourceFile.name, originalBytes)
          ..compression = sourceFile.compression
          ..lastModTime = sourceFile.lastModTime
          ..mode = sourceFile.mode,
      );
    }

    // Every source entry was decompressed on first read in the loop above;
    // release each entry's lazy link to the raw download buffer (see the
    // memory note at the top of this function). The repacked entries keep
    // their own references to the payload buffers, so this only drops the
    // original ZIP bytes before the encode step allocates the output buffer.
    for (final ArchiveFile sourceFile in sourceArchive) {
      sourceFile.clear();
    }

    final Uint8List encoded = ZipEncoder().encodeBytes(repacked);
    final File outputFile = File(outputFilePath);
    outputFile.parent.createSync(recursive: true);

    final String tempPath = path.join(
      outputFile.parent.path,
      '${path.basename(outputFilePath)}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    final File tempFile = File(tempPath);
    try {
      tempFile.writeAsBytesSync(encoded, flush: true);
      return tempFile.path;
    } catch (error) {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
      rethrow;
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  static List<int> _fileBytes(ArchiveFile file) {
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
}
