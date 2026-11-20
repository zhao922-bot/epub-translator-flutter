part of 'epub_chapter_translator.dart';

/// Output filename budgets, Windows MAX_PATH guards, and cache key builders.
class _EpubTranslatorPaths {
  const _EpubTranslatorPaths._();

  static String outputFilePath({
    required String inputPath,
    required String outputDirectory,
    required String suffix,
  }) {
    final String safeSuffix = TranslationApiClient.sanitizeOutputSuffix(suffix);
    final String baseName = path.basenameWithoutExtension(inputPath);
    String candidate = path.join(
      outputDirectory,
      outputFileName(baseName, safeSuffix),
    );
    // Never overwrite the source EPUB even if sanitization collapses the name.
    if (_sameFilesystemPath(candidate, inputPath)) {
      candidate = path.join(
        outputDirectory,
        outputFileName(baseName, '${safeSuffix}_out'),
      );
    }
    return candidate;
  }

  /// Reports append at most `.diagnostics.json` and then the shared atomic
  /// write suffix. This also covers EPUB temp/backup/recovery suffixes.
  static const int outputPathSuffixBudget = 17 + atomicWriteSuffixBudget;

  /// Keep every derived artifact writable. Windows counts UTF-16 units;
  /// POSIX filesystems count UTF-8 bytes per filename component.
  static String outputFileName(
    String baseName,
    String suffix, {
    bool? windows,
  }) {
    final bool useUtf16 = windows ?? Platform.isWindows;
    int size(String value) =>
        useUtf16 ? value.length : utf8.encode(value).length;
    String truncate(String value, int budget) {
      if (useUtf16) return EpubChapterTranslator._truncateUtf16(value, budget);
      final result = StringBuffer();
      int used = 0;
      for (final rune in value.runes) {
        final character = String.fromCharCode(rune);
        final bytes = utf8.encode(character).length;
        if (used + bytes > budget) break;
        result.write(character);
        used += bytes;
      }
      return result.toString();
    }

    const int limit = 255 - outputPathSuffixBudget;
    final String name = '$baseName$suffix.epub';
    if (size(name) <= limit) return name;
    final String hash = sha256
        .convert(utf8.encode(name))
        .toString()
        .substring(0, 12);
    final String tail = '${truncate(suffix, 64)}_$hash.epub';
    return '${truncate(baseName, limit - size(tail))}$tail';
  }

  @visibleForTesting
  static Future<void> validateOutputDirectory(
    String directory,
    UiLanguage language,
  ) async {
    final bool chinese = language == UiLanguage.chinese;
    if (await FileSystemEntity.type(directory) !=
        FileSystemEntityType.directory) {
      throw StateError(
        chinese
            ? '输出目录不存在或不是目录：$directory'
            : 'Output directory does not exist or is not a directory: $directory',
      );
    }
    File? probe;
    try {
      // Probe the directory itself: Windows ACLs distinguish creating files
      // from creating subdirectories (which can also inherit different ACLs).
      final candidate = File(
        path.join(
          directory,
          '.epub-write-probe-${DateTime.now().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}',
        ),
      );
      await candidate.create(exclusive: true);
      probe = candidate;
      await probe.writeAsBytes([0], flush: true);
      await probe.delete();
      probe = null;
    } on FileSystemException catch (error) {
      throw StateError(
        chinese
            ? '无法写入输出目录：$directory（$error）'
            : 'Output directory is not writable: $directory ($error)',
      );
    } finally {
      if (probe != null && await probe.exists()) {
        try {
          await probe.delete();
        } on FileSystemException {
          // Preserve the original write failure if cleanup also fails.
        }
      }
    }
  }

  /// Include reports and their atomic temporary names, as well as EPUB
  /// recovery files. [String.length] counts Windows UTF-16 code units.
  ///
  /// Visible for testing.
  @visibleForTesting
  static bool outputPathExceedsWindowsMaxPath(String outputFilePath) {
    // MAX_PATH (260) counts the terminating NUL, so 259 is the longest
    // usable path; a final path of exactly 260 already overflows.
    return outputFilePath.length + outputPathSuffixBudget >= 260;
  }

  /// Throws [WindowsLongPathException] when the longest write path the
  /// commit produces would exceed Windows MAX_PATH (260) while the system
  /// long-path policy is off. Runs before any paid API work. Fails open
  /// when the policy cannot be determined (null): blocking on a guess would
  /// be worse than the registry read failing silently.
  ///
  /// [longPathsEnabledReader] is a test seam for the (slow, PowerShell-based)
  /// registry read.
  static Future<void> throwIfOutputPathTooLongForWindows(
    String outputFilePath, {
    Future<bool?> Function()? longPathsEnabledReader,
  }) async {
    final String fileName = path.windows.basename(outputFilePath);
    if (fileName.length + outputPathSuffixBudget > 255) {
      throw FileSystemException(
        'Output filename plus temporary suffix exceeds 255 UTF-16 code units.',
        outputFilePath,
      );
    }
    if (!outputPathExceedsWindowsMaxPath(outputFilePath)) {
      return;
    }
    final bool? enabled =
        await (longPathsEnabledReader ??
            NativePlatformBridge.windowsLongPathsEnabled)();
    if (enabled == false) {
      throw WindowsLongPathException(outputFilePath);
    }
  }

  /// Classifies a pre-run exclusive-create probe failure: a real sharing/lock
  /// violation (Windows osError 32/33) is reported as "locked" (close the
  /// reader); anything else (e.g. ERROR_ACCESS_DENIED = 5 on a read-only
  /// file, or a Unix EACCES/EROFS) is an access problem and must not be
  /// misreported as "locked".
  ///
  /// Visible for testing.
  @visibleForTesting
  static String preRunProbeErrorMessage(
    FileSystemException error,
    AppStrings strings,
    String outputFilePath,
  ) {
    return EpubIsolateWorker.isFileLockError(error)
        ? strings.outputFileLocked(outputFilePath)
        : strings.outputFileNotWritable(outputFilePath);
  }

  static bool _sameFilesystemPath(String left, String right) {
    final String a = _normalizeInputPathForCache(left);
    final String b = _normalizeInputPathForCache(right);
    if (a.isEmpty || b.isEmpty) {
      return false;
    }
    return a == b;
  }

  /// Canonical path used in fingerprints so Windows casing/separators match.
  static String _normalizeInputPathForCache(String inputPath) {
    final String trimmed = inputPath.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    String normalized = path.normalize(trimmed);
    try {
      normalized = path.normalize(File(trimmed).absolute.path);
    } catch (_) {
      // Keep the best-effort normalize above.
    }
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  static Future<String> inputFingerprint(
    String inputPath, {
    String? expectedSourceFingerprint,
    required CancelToken cancelToken,
    required void Function() throwIfCancelled,
  }) async {
    // Read as a stream: context changes elsewhere in the book must invalidate
    // block translations even when the file size and timestamp are unchanged.
    final Digest contentHash = await cancellableFingerprint(
      File(inputPath).openRead(),
      cancelToken: cancelToken,
      throwIfCancelled: throwIfCancelled,
    );
    checkEpubSourceHash(contentHash.toString(), expectedSourceFingerprint);
    final String normalizedPath = _normalizeInputPathForCache(inputPath);
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              EpubChapterTranslator._cacheSchemaVersion,
              EpubChapterTranslator.qualityCacheSchemaVersion,
              normalizedPath,
              contentHash.toString(),
            ].join('|'),
          ),
        )
        .toString();
  }

  static String jobKey({
    required TranslationApiClient apiClient,
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              EpubChapterTranslator._cacheSchemaVersion,
              EpubChapterTranslator.qualityCacheSchemaVersion,
              config.chunkSize,
              inputFingerprint,
              apiClient.normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.bilingual,
              config.lockedGlossary.trim(),
              config.residualQualityCheck,
              if (config.effectiveReasoningEffort != null ||
                  config.maxOutputTokens != 8192 ||
                  config.semanticQualityCheck) ...[
                config.effectiveReasoningEffort ?? 'provider-default',
                config.maxOutputTokens,
                config.semanticQualityCheck,
              ],
              if (config.semanticQualityCheck) ...[
                config.maxSemanticReviewRequests,
                config.maxSemanticReviewTokens,
                config.semanticReviewScope.name,
                "semantic-suggestions-v2",
                config.autoApplyVerifiedCorrections,
              ],
              config.styleProfileEnabled,
              _styleProfileCacheValue(confirmedStyleProfile),
              chapters
                  .map((InspectedChapter chapter) => chapter.path)
                  .join('|'),
            ].join('|'),
          ),
        )
        .toString();
  }

  static String blockCacheKey(
    TranslationApiClient apiClient,
    TranslationConfig config,
    ExtractedBlock block, {
    required String chapterPath,
    required String inputFingerprint,
    String contextIdentity = '',
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              EpubChapterTranslator._cacheSchemaVersion,
              EpubChapterTranslator.qualityCacheSchemaVersion,
              apiClient.normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.lockedGlossary.trim(),
              config.chunkSize,
              config.residualQualityCheck,
              if (config.effectiveReasoningEffort != null ||
                  config.maxOutputTokens != 8192 ||
                  config.semanticQualityCheck) ...[
                config.effectiveReasoningEffort ?? 'provider-default',
                config.maxOutputTokens,
                config.semanticQualityCheck,
              ],
              if (config.semanticQualityCheck) ...[
                'semantic-suggestions-v2',
                config.autoApplyVerifiedCorrections,
                config.semanticReviewScope.name,
              ],
              config.styleProfileEnabled,
              _styleProfileCacheValue(confirmedStyleProfile),
              inputFingerprint,
              chapterPath,
              if (contextIdentity.isNotEmpty)
                'selection-context-v1:$contextIdentity',
              // Block ids are positional within a chapter (e.g. "p-3"), so
              // two blocks with identical source HTML at different positions
              // get different keys. Neighbor context feeds the prompt for
              // each position, so sharing a key across positions would reuse
              // a translation that was shaped by the wrong context. Old
              // entries keyed without the id hash differently and are simply
              // never hit again.
              block.id,
              block.sourceHtml,
              // Earlier alias-marked footnotes were translated as prose.
              // Invalidate only those cache entries, retaining ordinary text.
              if (RegExp(
                r'\b(?!epub:)[\w-]+:type\s*=',
              ).hasMatch(block.sourceHtml))
                'epub-type-alias-protection-v1',
              // Old cell caches may contain model-owned layout or links.
              // Invalidate just these blocks, retaining ordinary paid text.
              if (block.tagName == 'td' || block.tagName == 'th')
                'table-cell-structure-v2',
              if (block.tagName == 'caption') 'table-caption-structure-v2',
              if (RegExp(
                r'<(?:pre|code|var|kbd|samp|svg|math|script|style)(?=[\s/>])',
                caseSensitive: false,
              ).hasMatch(block.sourceHtml))
                'non-prose-text-v2',
              if (block.isAuthorSignature) 'author-signature-v1',
            ].join('|'),
          ),
        )
        .toString();
  }

  static String _styleProfileCacheValue(
    TranslationStyleProfile? confirmedStyleProfile,
  ) {
    if (confirmedStyleProfile == null) {
      return 'none';
    }
    return jsonEncode(confirmedStyleProfile.toJson());
  }
}
