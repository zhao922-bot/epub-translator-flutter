import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart' as xml;

import '../../../shared/logging/app_logger.dart';
import 'epub/epub_text_decoder.dart';

/// Heavy ZIP work off the UI isolate (Windows/Android).
class EpubIsolateWorker {
  const EpubIsolateWorker._();

  /// Reads and decodes an EPUB into a name -> bytes map on a background isolate.
  static Future<Map<String, Uint8List>> loadArchiveFiles(String inputPath) {
    return Isolate.run(() => _loadArchiveFilesSync(inputPath));
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
  static Future<bool> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    bool Function()? shouldCommit,
  }) async {
    final String tempPath = await Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
        navigationLabelsByPath: navigationLabelsByPath,
        navigationLanguageTag: navigationLanguageTag,
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
      );
    } catch (error) {
      await _deleteQuietly(tempFile);
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
  }) {
    return Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
        navigationLabelsByPath: navigationLabelsByPath,
        navigationLanguageTag: navigationLanguageTag,
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
    final List<xml.XmlElement> languages = opf.descendants
        .whereType<xml.XmlElement>()
        .where((xml.XmlElement element) => element.name.local == 'language')
        .toList(growable: false);
    if (languages.isEmpty) {
      // No dc:language present: append one instead of skipping, so the
      // finished book still carries the target language.
      final xml.XmlElement? metadata = opf.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'metadata')
          .firstOrNull;
      if (metadata != null) {
        metadata.children.add(_dcLanguageElement(opf, languageTag));
      }
    } else {
      for (final xml.XmlElement language in languages) {
        language.innerText = languageTag;
      }
    }

    final Map<String, String> replacements = <String, String>{
      opfPath: opf.toXmlString(),
    };
    final xml.XmlElement? spine = opf.descendants
        .whereType<xml.XmlElement>()
        .where((xml.XmlElement element) => element.name.local == 'spine')
        .firstOrNull;
    final String ncxId = spine?.getAttribute('toc') ?? '';
    xml.XmlElement? ncxItem;
    for (final xml.XmlElement item
        in opf.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'item',
        )) {
      if ((ncxId.isNotEmpty && item.getAttribute('id') == ncxId) ||
          item.getAttribute('media-type') == 'application/x-dtbncx+xml') {
        ncxItem = item;
        break;
      }
    }
    final String ncxHref = ncxItem?.getAttribute('href') ?? '';
    if (ncxHref.isEmpty) {
      return replacements;
    }
    final String ncxPath = path.posix.normalize(
      path.posix.join(path.posix.dirname(opfPath), ncxHref),
    );
    final List<int>? ncxBytes = archiveFiles[ncxPath];
    if (ncxBytes == null) {
      return replacements;
    }

    final xml.XmlDocument ncx = xml.XmlDocument.parse(
      decodeEpubText(bytes: ncxBytes, filePath: ncxPath, strict: true),
    );
    ncx.rootElement.setAttribute('xml:lang', languageTag);
    for (final xml.XmlElement navPoint
        in ncx.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'navPoint',
        )) {
      final xml.XmlElement? content = navPoint.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'content')
          .firstOrNull;
      final String source = content?.getAttribute('src') ?? '';
      if (source.isEmpty) {
        continue;
      }
      final String chapterPath = path.posix.normalize(
        path.posix.join(
          path.posix.dirname(ncxPath),
          _decodeNcxSrc(source.split('#').first),
        ),
      );
      final String? label = labelsByPath[chapterPath];
      if (label == null) {
        continue;
      }
      final xml.XmlElement? text = navPoint.descendants
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

  /// Builds a `<dc:language>` element for an OPF missing one. Reuses the
  /// document's declared Dublin Core namespace when present; otherwise the
  /// new element carries its own `xmlns:dc` so the output stays well-formed.
  static xml.XmlElement _dcLanguageElement(
    xml.XmlDocument opf,
    String languageTag,
  ) {
    bool dcDeclared = false;
    for (final xml.XmlElement element
        in opf.descendants.whereType<xml.XmlElement>()) {
      for (final xml.XmlAttribute attribute in element.attributes) {
        if (attribute.name.qualified == 'xmlns:dc') {
          dcDeclared = true;
          break;
        }
      }
      if (dcDeclared) {
        break;
      }
    }
    final xml.XmlElement element = xml.XmlElement(
      xml.XmlName.fromString('dc:language'),
      dcDeclared
          ? <xml.XmlAttribute>[]
          : <xml.XmlAttribute>[
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
  static Future<bool> commitTempFile(
    File tempFile,
    File finalFile, {
    bool Function()? shouldCommit,
  }) async {
    bool allowCommit() => shouldCommit == null || shouldCommit();

    await finalFile.parent.create(recursive: true);
    if (!await tempFile.exists()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }

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
    try {
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
    } catch (error) {
      await _deleteQuietly(tempFile);
      rethrow;
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
  static Archive _decodeEpubArchive(String inputPath) {
    final List<int> bytes = File(inputPath).readAsBytesSync();
    return ZipDecoder().decodeBytes(bytes);
  }

  static Map<String, Uint8List> _loadArchiveFilesSync(String inputPath) {    final List<int> bytes = File(inputPath).readAsBytesSync();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final Map<String, Uint8List> files = <String, Uint8List>{};
    for (final ArchiveFile file in archive) {
      if (!file.isFile) {
        continue;
      }
      files[file.name] = Uint8List.fromList(_fileBytes(file));
    }
    return files;
  }

  /// Encodes the EPUB and writes only a same-directory temp file.
  /// Returns the absolute temp path. Does not touch [outputFilePath].
  static String _writeTranslatedEpubToTempSync({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
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
    final Archive sourceArchive = _decodeEpubArchive(inputPath);
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
        ),
      );
    }

    final ArchiveFile? mimetypeFile = sourceArchive.find('mimetype');
    if (mimetypeFile != null) {
      final List<int> mimetypeBytes = _fileBytes(mimetypeFile);
      repacked.add(
        ArchiveFile.noCompress('mimetype', mimetypeBytes.length, mimetypeBytes)
          ..lastModTime = mimetypeFile.lastModTime
          ..mode = mimetypeFile.mode,
      );
    } else {
      // The EPUB spec requires the mimetype entry to exist, be first, and be
      // uncompressed. A source book missing it would otherwise produce an
      // invalid EPUB; synthesize the standard entry instead of propagating
      // the defect.
      final List<int> defaultMimetypeBytes = utf8.encode(
        'application/epub+zip',
      );
      repacked.add(
        ArchiveFile.noCompress(
          'mimetype',
          defaultMimetypeBytes.length,
          defaultMimetypeBytes,
        ),
      );
    }

    for (final ArchiveFile sourceFile in sourceArchive) {
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
