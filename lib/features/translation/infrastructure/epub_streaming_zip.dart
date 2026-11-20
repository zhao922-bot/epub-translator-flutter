import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Maximum compressed `.epub` input size accepted for processing (256 MiB).
const int kMaxEpubCompressedBytes = 256 * 1024 * 1024;

/// Maximum total uncompressed payload bytes allowed from an EPUB (512 MiB).
const int kMaxEpubUncompressedBytes = 512 * 1024 * 1024;

/// Maximum compressed payload allowed for a Unix symlink entry (64 KiB).
const int kMaxSymlinkCompressedBytes = 64 * 1024;

/// Maximum aggregate uncompressed-to-compressed ratio allowed for an archive.
const int kMaxCompressionRatio = 100;

/// Maximum number of entries allowed in a single EPUB ZIP archive.
const int kMaxEpubEntryCount = 50000;

/// Decoded archive plus the entry names occurring more than once in the raw
/// central directory (used to preserve last-wins content and valid CRC32).
typedef DecodedEpubArchive = ({Archive archive, Set<String> duplicateNames});

/// Thrown when the source EPUB file is locked by another process (Windows
/// sharing/lock violation).
class InputFileLockedException implements Exception {
  InputFileLockedException(this.inputPath);

  final String inputPath;

  @override
  String toString() => 'InputFileLockedException: $inputPath';
}

/// Thrown when an EPUB archive violates decompression, ratio, entry-count, or
/// symlink safety limits.
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
      'safety limit ($uncompressedBytes bytes from $compressedBytes compressed '
      'bytes, limit $limitBytes bytes).';
}

void checkEpubCompressedSize({
  required String inputPath,
  required int compressedBytes,
  int limitBytes = kMaxEpubCompressedBytes,
  int? uncompressedBytes,
}) {
  if (compressedBytes > limitBytes) {
    throw EpubDecompressionLimitException(
      inputPath: inputPath,
      compressedBytes: compressedBytes,
      uncompressedBytes: uncompressedBytes ?? compressedBytes,
      limitBytes: limitBytes,
    );
  }
}

/// Decoded EPUB archive paired with its streaming SHA-256 fingerprint and the
/// underlying [InputFileStream] that backs lazy ZIP entry reads.
///
/// Callers must call [closeSync] in a `try ... finally` block once entry reads
/// and compressed repacking pass-throughs are finished.
class OpenedEpubArchive {
  OpenedEpubArchive({
    required this.archive,
    required this.duplicateNames,
    required this.fingerprint,
    required this.compressedBytes,
    this.stream,
  });

  final Archive archive;
  final Set<String> duplicateNames;
  final String fingerprint;
  final int compressedBytes;
  InputFileStream? stream;

  DecodedEpubArchive get decoded =>
      (archive: archive, duplicateNames: duplicateNames);

  void closeSync() {
    final InputFileStream? active = stream;
    stream = null;
    if (active == null) return;
    try {
      active.closeSync();
    } catch (_) {
      // Best-effort cleanup; ignore already-closed handles.
    }
  }
}

/// Random-access byte source abstraction so ZIP preflight checks share one
/// parser across both disk-backed streaming opens and in-memory test fixtures.
abstract interface class RandomAccessBytesReader {
  int get length;

  /// Reads `[start, end)` bytes, clamping safely when needed.
  Uint8List readRange(int start, int end);
}

class MemoryRandomAccessReader implements RandomAccessBytesReader {
  MemoryRandomAccessReader(this._bytes);

  final List<int> _bytes;

  @override
  int get length => _bytes.length;

  @override
  Uint8List readRange(int start, int end) {
    final List<int> bytes = _bytes;
    if (bytes is Uint8List) {
      return Uint8List.sublistView(bytes, start, end);
    }
    return Uint8List.fromList(bytes.sublist(start, end));
  }
}

class _FileRandomAccessReader implements RandomAccessBytesReader {
  _FileRandomAccessReader(this._raf, this.length);

  final RandomAccessFile _raf;
  @override
  final int length;

  @override
  Uint8List readRange(int start, int end) {
    final int count = end - start;
    if (count <= 0) return Uint8List(0);
    _raf.setPositionSync(start);
    final Uint8List out = Uint8List(count);
    int filled = 0;
    while (filled < count) {
      final int n = _raf.readIntoSync(out, filled, count);
      if (n <= 0) break;
      filled += n;
    }
    return filled == count ? out : Uint8List.sublistView(out, 0, filled);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

int _readU8(Uint8List b, int offset) => b[offset];

int _readU16(Uint8List b, int offset) => b[offset] | (b[offset + 1] << 8);

int _readU32(Uint8List b, int offset) =>
    b[offset] |
    (b[offset + 1] << 8) |
    (b[offset + 2] << 16) |
    (b[offset + 3] << 24);

int _readU64(Uint8List b, int offset) =>
    _readU32(b, offset) + (_readU32(b, offset + 4) * 0x100000000);

Never _invalidZipDirectory() =>
    throw const FormatException('Invalid ZIP directory.');

/// Finds the validated EOCD offset in [reader], matching `archive 4.0.9`'s
/// reverse signature search so an ambiguous inner EOCD in a comment is rejected
/// with [FormatException].
int findValidatedEocdEnd(RandomAccessBytesReader reader) {
  final int totalLen = reader.length;
  if (totalLen < 22) _invalidZipDirectory();
  final int tailStart = math.max(0, totalLen - 22 - 0xffff);
  final Uint8List tail = reader.readRange(tailStart, totalLen);

  int? outerEnd;
  for (int i = tail.length - 22; i >= 0; i--) {
    if (_readU32(tail, i) == 0x06054b50 &&
        tailStart + i + 22 + _readU16(tail, i + 20) == totalLen) {
      outerEnd = tailStart + i;
      break;
    }
  }
  if (outerEnd == null) _invalidZipDirectory();

  // Mirror ZipDirectory._findSignature from archive 4.0.9.
  final int scanLen = totalLen - 4;
  if (scanLen <= 0) _invalidZipDirectory();
  const int bufferSize = 1024;
  final int chunkSize = math.min(scanLen, bufferSize);
  int startPos = scanLen - chunkSize;
  int? decoderEnd;
  while (startPos >= 0) {
    final Uint8List chunk = startPos >= tailStart
        ? Uint8List.sublistView(
            tail,
            startPos - tailStart,
            startPos - tailStart + chunkSize,
          )
        : reader.readRange(startPos, startPos + chunkSize);
    for (int chunkPos = chunkSize - 4; chunkPos >= 0; chunkPos--) {
      if (_readU32(chunk, chunkPos) == 0x06054b50) {
        decoderEnd = startPos + chunkPos;
        break;
      }
    }
    if (decoderEnd != null) break;
    if (startPos > 0 && startPos < chunkSize) {
      startPos = 0;
    } else {
      startPos -= chunkSize;
    }
  }

  if (decoderEnd != outerEnd) _invalidZipDirectory();
  return outerEnd;
}

({
  int centralOffset,
  int centralSize,
  int directoryEnd,
  int declaredOnDisk,
  int declaredTotal,
})
_resolveCentralDirectoryRange(RandomAccessBytesReader reader, int end) {
  final Uint8List eocd = reader.readRange(end, end + 22);
  if (eocd.length < 22) _invalidZipDirectory();
  if (_readU16(eocd, 4) != 0 || _readU16(eocd, 6) != 0) {
    _invalidZipDirectory();
  }
  int declaredOnDisk = _readU16(eocd, 8);
  int declaredTotal = _readU16(eocd, 10);
  int centralSize = _readU32(eocd, 12);
  int centralOffset = _readU32(eocd, 16);
  int directoryEnd = end;

  if (end >= 20) {
    final Uint8List locator = reader.readRange(end - 20, end);
    if (locator.length == 20 && _readU32(locator, 0) == 0x07064b50) {
      final int zip64Offset = _readU64(locator, 8);
      final int locatorStart = end - 20;
      if (zip64Offset < 0 || zip64Offset + 56 > locatorStart) {
        _invalidZipDirectory();
      }
      final Uint8List zip64 = reader.readRange(zip64Offset, zip64Offset + 56);
      if (zip64.length < 56 || _readU32(zip64, 0) != 0x06064b50) {
        _invalidZipDirectory();
      }
      if (_readU32(zip64, 16) != 0 || _readU32(zip64, 20) != 0) {
        _invalidZipDirectory();
      }
      declaredOnDisk = _readU64(zip64, 24);
      declaredTotal = _readU64(zip64, 32);
      centralSize = _readU64(zip64, 40);
      centralOffset = _readU64(zip64, 48);
      directoryEnd = zip64Offset;
    }
  }

  if (centralOffset < 0 ||
      centralSize < 0 ||
      centralOffset + centralSize > directoryEnd) {
    _invalidZipDirectory();
  }
  return (
    centralOffset: centralOffset,
    centralSize: centralSize,
    directoryEnd: directoryEnd,
    declaredOnDisk: declaredOnDisk,
    declaredTotal: declaredTotal,
  );
}

void _scanCentralDirectoryHeaders({
  required RandomAccessBytesReader reader,
  required String inputPath,
  required int end,
  required bool checkEntryCount,
  required bool checkSymlinks,
}) {
  final ({
    int centralOffset,
    int centralSize,
    int directoryEnd,
    int declaredOnDisk,
    int declaredTotal,
  })
  range = _resolveCentralDirectoryRange(reader, end);
  final int directoryStart = range.centralOffset;
  final int directoryEnd = range.centralOffset + range.centralSize;
  const int windowBytes = 256 * 1024;

  int fileOffset = directoryStart;
  Uint8List window = Uint8List(0);
  int windowStart = directoryStart;
  int count = 0;

  Uint8List ensureBytes(int needed) {
    final int available = window.length - (fileOffset - windowStart);
    if (available >= needed) return window;
    final int remaining = directoryEnd - fileOffset;
    if (remaining < needed) _invalidZipDirectory();
    final int readLen = math.max(needed, math.min(remaining, windowBytes));
    window = reader.readRange(fileOffset, fileOffset + readLen);
    windowStart = fileOffset;
    if (window.length < needed) _invalidZipDirectory();
    return window;
  }

  while (fileOffset < directoryEnd) {
    ensureBytes(46);
    final int rel = fileOffset - windowStart;
    if (_readU32(window, rel) != 0x02014b50) {
      _invalidZipDirectory();
    }
    final int nameLen = _readU16(window, rel + 28);
    final int extraLen = _readU16(window, rel + 30);
    final int commentLen = _readU16(window, rel + 32);
    final int headerLen = 46 + nameLen + extraLen + commentLen;
    if (fileOffset + headerLen > directoryEnd) {
      _invalidZipDirectory();
    }
    if (checkEntryCount) {
      count++;
      if (count > kMaxEpubEntryCount) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: reader.length,
          uncompressedBytes: count,
          limitBytes: kMaxEpubEntryCount,
        );
      }
    }
    if (checkSymlinks) {
      final int hostOs = _readU8(window, rel + 5);
      final int externalFileAttributes = _readU32(window, rel + 38);
      if (hostOs == 3 && ((externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        final int compressedSize = _readU32(window, rel + 20);
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: compressedSize,
          uncompressedBytes: -1,
          limitBytes: kMaxSymlinkCompressedBytes,
        );
      }
    }
    fileOffset += headerLen;
  }
  if (fileOffset != directoryEnd) {
    _invalidZipDirectory();
  }
  if (checkEntryCount &&
      (range.declaredOnDisk != count || range.declaredTotal != count)) {
    _invalidZipDirectory();
  }
}

void checkZipEntryCountReader({
  required String inputPath,
  required RandomAccessBytesReader reader,
}) {
  final int end = findValidatedEocdEnd(reader);
  _scanCentralDirectoryHeaders(
    reader: reader,
    inputPath: inputPath,
    end: end,
    checkEntryCount: true,
    checkSymlinks: false,
  );
}

void checkSymlinkEntrySizesReader({
  required String inputPath,
  required RandomAccessBytesReader reader,
}) {
  final int end = findValidatedEocdEnd(reader);
  _scanCentralDirectoryHeaders(
    reader: reader,
    inputPath: inputPath,
    end: end,
    checkEntryCount: false,
    checkSymlinks: true,
  );
}

/// Validates entry count and header-declared uncompressed size limits on [archive].
void checkArchiveLimits({
  required String inputPath,
  required Archive archive,
  required int compressedBytes,
  int maxEntries = kMaxEpubEntryCount,
  int maxUncompressedBytes = kMaxEpubUncompressedBytes,
}) {
  final int entryCount = archive.length;
  if (entryCount > maxEntries) {
    throw EpubDecompressionLimitException(
      inputPath: inputPath,
      compressedBytes: compressedBytes,
      uncompressedBytes: entryCount,
      limitBytes: maxEntries,
    );
  }
  int totalUncompressed = 0;
  for (final ArchiveFile file in archive) {
    totalUncompressed += file.size;
    if (totalUncompressed > maxUncompressedBytes) {
      throw EpubDecompressionLimitException(
        inputPath: inputPath,
        compressedBytes: compressedBytes,
        uncompressedBytes: totalUncompressed,
        limitBytes: maxUncompressedBytes,
      );
    }
  }
  if (totalUncompressed > compressedBytes * kMaxCompressionRatio) {
    throw EpubDecompressionLimitException(
      inputPath: inputPath,
      compressedBytes: compressedBytes,
      uncompressedBytes: totalUncompressed,
      limitBytes: compressedBytes * kMaxCompressionRatio,
    );
  }
}

/// Applies duplicate central-directory header resolution and safety checks on a
/// freshly decoded [Archive] backed by [decoder].
DecodedEpubArchive finalizeDecodedArchiveWithLimits({
  required String inputPath,
  required ZipDecoder decoder,
  required Archive archive,
  required int compressedBytes,
}) {
  final Set<String> seen = <String>{};
  final Set<String> duplicates = <String>{};
  for (final ZipFileHeader header in decoder.directory.fileHeaders) {
    final ZipFile? file = header.file;
    final String? name = file?.filename;
    if (file == null || name == null || name.isEmpty) continue;
    if (!seen.add(name)) {
      duplicates.add(name);
      final ArchiveFile entry = name.endsWith('/') || name.endsWith('\\')
          ? ArchiveFile.directory(name)
          : ArchiveFile.file(name, header.uncompressedSize, file);
      entry.mode = header.externalFileAttributes;
      entry.lastModTime =
          (header.lastModifiedFileDate << 16) | header.lastModifiedFileTime;
      entry.crc32 = file.crc32;
      entry.compression = file.compressionMethod;
      archive.addFile(entry);
    }
  }
  checkArchiveLimits(
    inputPath: inputPath,
    archive: archive,
    compressedBytes: compressedBytes,
  );
  return (archive: archive, duplicateNames: duplicates);
}

/// Keeps lazy ZIP reads on the file already hashed and checked. Closing the
/// archive releases that handle; opening the same path again could read a
/// different file after an atomic replacement.
class _OpenedReadOnlyFile extends AbstractFileHandle {
  _OpenedReadOnlyFile(this._file, this.length);

  RandomAccessFile? _file;
  int _position = 0;
  @override
  final int length;

  @override
  bool get isOpen => _file != null;

  @override
  int get position => _position;

  @override
  set position(int position) {
    _file!.setPositionSync(position);
    _position = position;
  }

  @override
  int readInto(Uint8List buffer, [int? count]) {
    final int remaining = length - _position;
    if (remaining <= 0) return 0;
    final int read = _file!.readIntoSync(
      buffer,
      0,
      math.min(count ?? buffer.length, remaining),
    );
    _position += read;
    return read;
  }

  @override
  Future<void> close() async {
    final RandomAccessFile? file = _file;
    _file = null;
    await file?.close();
  }

  @override
  void closeSync() {
    final RandomAccessFile? file = _file;
    _file = null;
    file?.closeSync();
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    throw UnsupportedError('The source EPUB is read-only.');
  }
}

OpenedEpubArchive _decodeCheckedArchive({
  required RandomAccessFile file,
  required String inputPath,
  required String fingerprint,
  required int compressedBytes,
}) {
  // The archive stream is bounded to the bytes covered by the fingerprint.
  final _FileRandomAccessReader reader = _FileRandomAccessReader(
    file,
    compressedBytes,
  );
  final int end = findValidatedEocdEnd(reader);
  _scanCentralDirectoryHeaders(
    reader: reader,
    inputPath: inputPath,
    end: end,
    checkEntryCount: true,
    checkSymlinks: true,
  );
  final InputFileStream inputStream = InputFileStream.withFileHandle(
    _OpenedReadOnlyFile(file, compressedBytes),
  );
  final ZipDecoder decoder = ZipDecoder();
  final Archive archive = decoder.decodeStream(inputStream);
  final DecodedEpubArchive finalized = finalizeDecodedArchiveWithLimits(
    inputPath: inputPath,
    decoder: decoder,
    archive: archive,
    compressedBytes: compressedBytes,
  );
  return OpenedEpubArchive(
    archive: finalized.archive,
    duplicateNames: finalized.duplicateNames,
    fingerprint: fingerprint,
    compressedBytes: compressedBytes,
    stream: inputStream,
  );
}

/// Streams SHA-256 hashing and ZIP EOCD / central-directory safety preflights
/// using bounded buffers (`<= 256 KiB`), then opens an [InputFileStream] backed
/// [OpenedEpubArchive] without materializing the full `.epub` in RAM.
OpenedEpubArchive openStreamingEpubArchiveSync({
  required String inputPath,
  required bool Function(FileSystemException error) isFileLockError,
  String? expectedSourceFingerprint,
  void Function(String actual, String expected)? onFingerprintMismatch,
  void Function(int bytesRead, int totalBytes)? onHashProgress,
}) {
  try {
    final RandomAccessFile raf = File(inputPath).openSync();
    bool handedOff = false;
    try {
      final int initialLength = raf.lengthSync();
      checkEpubCompressedSize(
        inputPath: inputPath,
        compressedBytes: initialLength,
      );

      final _DigestSink digestSink = _DigestSink();
      final ByteConversionSink hashInput = sha256.startChunkedConversion(
        digestSink,
      );
      final Uint8List buffer = Uint8List(256 * 1024);
      int totalRead = 0;
      while (true) {
        final int n = raf.readIntoSync(buffer);
        if (n == 0) break;
        totalRead += n;
        checkEpubCompressedSize(
          inputPath: inputPath,
          compressedBytes: totalRead,
        );
        hashInput.add(
          n == buffer.length ? buffer : Uint8List.sublistView(buffer, 0, n),
        );
        onHashProgress?.call(totalRead, initialLength);
      }
      hashInput.close();
      final String fingerprint = digestSink.value!.toString();

      if (expectedSourceFingerprint != null &&
          fingerprint != expectedSourceFingerprint) {
        onFingerprintMismatch?.call(fingerprint, expectedSourceFingerprint);
      }

      final OpenedEpubArchive opened = _decodeCheckedArchive(
        file: raf,
        inputPath: inputPath,
        fingerprint: fingerprint,
        compressedBytes: totalRead,
      );
      handedOff = true;
      return opened;
    } finally {
      if (!handedOff) raf.closeSync();
    }
  } on FileSystemException catch (error) {
    if (isFileLockError(error)) {
      throw InputFileLockedException(inputPath);
    }
    rethrow;
  }
}

/// Asynchronous cooperative-cancellable variant of
/// [openStreamingEpubArchiveSync], ensuring all [RandomAccessFile] handles are
/// deterministically closed before cancellation unwinds.
Future<OpenedEpubArchive> openStreamingEpubArchiveAsync({
  required String inputPath,
  required bool Function(FileSystemException error) isFileLockError,
  required bool Function() isCancelled,
  required Object Function() buildCancelledError,
  String? expectedSourceFingerprint,
  void Function(String actual, String expected)? onFingerprintMismatch,
  void Function(int bytesRead, int totalBytes)? onHashProgress,
}) async {
  if (isCancelled()) throw buildCancelledError();
  try {
    final RandomAccessFile raf = await File(inputPath).open();
    bool handedOff = false;
    try {
      final int initialLength = await raf.length();
      checkEpubCompressedSize(
        inputPath: inputPath,
        compressedBytes: initialLength,
      );

      final _DigestSink digestSink = _DigestSink();
      final ByteConversionSink hashInput = sha256.startChunkedConversion(
        digestSink,
      );
      final Uint8List buffer = Uint8List(256 * 1024);
      int totalRead = 0;
      int chunks = 0;
      while (true) {
        if (isCancelled()) {
          hashInput.close();
          throw buildCancelledError();
        }
        final int n = await raf.readInto(buffer);
        if (n == 0) break;
        totalRead += n;
        checkEpubCompressedSize(
          inputPath: inputPath,
          compressedBytes: totalRead,
        );
        hashInput.add(
          n == buffer.length ? buffer : Uint8List.sublistView(buffer, 0, n),
        );
        onHashProgress?.call(totalRead, initialLength);
        chunks++;
        if (chunks % 4 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (isCancelled()) {
        hashInput.close();
        throw buildCancelledError();
      }
      hashInput.close();
      final String fingerprint = digestSink.value!.toString();

      if (expectedSourceFingerprint != null &&
          fingerprint != expectedSourceFingerprint) {
        onFingerprintMismatch?.call(fingerprint, expectedSourceFingerprint);
      }

      final OpenedEpubArchive opened = _decodeCheckedArchive(
        file: raf,
        inputPath: inputPath,
        fingerprint: fingerprint,
        compressedBytes: totalRead,
      );
      handedOff = true;
      return opened;
    } finally {
      if (!handedOff) await raf.close();
    }
  } on FileSystemException catch (error) {
    if (isFileLockError(error)) {
      throw InputFileLockedException(inputPath);
    }
    rethrow;
  }
}
