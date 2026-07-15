import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

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
  /// When [shouldCommit] returns false after the isolate finishes (e.g. cancel),
  /// the temp file is deleted and the existing final output is left untouched.
  /// Returns `true` when the final file was committed, `false` when
  /// [shouldCommit] refused the commit (temp cleaned; final path untouched).
  static Future<bool> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    bool Function()? shouldCommit,
  }) async {
    final String tempPath = await Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
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
  }) {
    return Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
      ),
    );
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

    // Windows cannot rename over an existing file. Move final aside, promote
    // temp, then drop the backup. If promotion fails or commit is refused after
    // the backup move, restore the backup.
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

  static Map<String, Uint8List> _loadArchiveFilesSync(String inputPath) {
    final List<int> bytes = File(inputPath).readAsBytesSync();
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
  }) {
    final List<int> sourceBytes = File(inputPath).readAsBytesSync();
    final Archive sourceArchive = ZipDecoder().decodeBytes(sourceBytes);
    final Archive repacked = Archive();

    final ArchiveFile? mimetypeFile = sourceArchive.find('mimetype');
    if (mimetypeFile != null) {
      final List<int> mimetypeBytes = _fileBytes(mimetypeFile);
      repacked.add(
        ArchiveFile.noCompress('mimetype', mimetypeBytes.length, mimetypeBytes)
          ..lastModTime = mimetypeFile.lastModTime
          ..mode = mimetypeFile.mode,
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

      final String? replacement = translatedHtmlByPath[sourceFile.name];
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
