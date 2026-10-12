part of 'epub_chapter_translator.dart';

/// Owns HTML, protected-slot, and cross-file footnote translation strategies,
/// including response validation, prompt rules, splitting, retries, and fallback.
/// Every request goes through the invocation owner; child work shares the outer
/// queue's HTTP budget without holding a permit for a parent strategy operation.
class _EpubTranslationStrategy {
  _EpubTranslationStrategy(this.owner);

  final EpubChapterTranslator owner;

  Future<List<String>> translateBlockBatch({
    required Dio dio,
    required TranslationConfig config,
    required TranslationBlockBatch batch,
    String? chapterPath,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    int? fallbackWindow,
    Future<void> Function(String id, String html)? onValidated,
  }) async {
    final List<ExtractedBlock> htmlBlocks = <ExtractedBlock>[];
    final List<_ProtectedSlotRequest> slotRequests = <_ProtectedSlotRequest>[];
    for (final ExtractedBlock block in batch.blocks) {
      final ProtectedAnchorTextSlots? template = _tryParseProtectedSlots(
        block.sourceHtml,
      );
      if (template != null && template.hasProtectedAnchors) {
        slotRequests.add(
          _ProtectedSlotRequest(
            id: block.id,
            block: block,
            template: template,
            chapterPath: chapterPath ?? '',
          ),
        );
        continue;
      }
      htmlBlocks.add(block);
    }

    final Map<String, String> translatedById = <String, String>{};
    if (htmlBlocks.isNotEmpty) {
      final List<String> translatedHtml = await translateHtmlBlockBatch(
        dio: dio,
        config: config,
        chapterPath: chapterPath,
        batch: TranslationBlockBatch(htmlBlocks, context: batch.context),
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        fallbackWindow: fallbackWindow,
        onValidated: onValidated,
      );
      for (int index = 0; index < htmlBlocks.length; index += 1) {
        translatedById[htmlBlocks[index].id] = translatedHtml[index];
      }
    }
    if (slotRequests.isNotEmpty) {
      translatedById.addAll(
        await _translateProtectedSlotBatch(
          dio: dio,
          config: config,
          requests: slotRequests,
          context: batch.context,
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
          apiCounted: true,
          onValidated: onValidated,
        ),
      );
    }
    return batch.blocks
        .map((ExtractedBlock block) => translatedById[block.id]!)
        .toList(growable: false);
  }

  Future<List<String>> translateHtmlBlockBatch({
    required Dio dio,
    required TranslationConfig config,
    required TranslationBlockBatch batch,
    String? chapterPath,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    int? fallbackWindow,
    Future<void> Function(String id, String html)? onValidated,
  }) async {
    final Map<String, dynamic> payloadMap = <String, dynamic>{
      if (!batch.context.isEmpty) 'context': batch.context.toJson(),
      'blocks': batch.blocks
          .map(
            (ExtractedBlock block) => <String, String>{
              'id': block.id,
              'html': block.sourceHtml,
            },
          )
          .toList(),
    };
    final String payload = jsonEncode(payloadMap);

    try {
      final _BatchParseOutcome
      parsed = await owner._apiClient.runRetried<_BatchParseOutcome>(
        config: config,
        retryDelayOverride: retryDelayOverride,
        shouldRetry: TranslationApiClient.shouldRetryBatchError,
        cancelToken: cancelToken,
        operation: () async {
          if (cancelToken?.isCancelled ?? false) {
            throw const TranslationCancelledException();
          }
          final TranslationStyleProfile batchStyleProfile =
              _EpubBookMemory._styleProfileFromBookMemoryJson(
                batch.context.bookMemory,
              );
          final bool batchStyleConfirmed =
              _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
                batch.context.bookMemory,
              );
          final Map<String, dynamic> requestData = <String, dynamic>{
            'model': config.model,
            'temperature': 0.2,
            'messages': <Map<String, String>>[
              <String, String>{
                'role': 'system',
                'content':
                    'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include read-only context before and after the requested blocks plus a compact bookMemory summary of earlier chapters. Use that context only for continuity, pronouns, tone, terminology, and paragraph flow. Translate only items in "blocks"; never include context items in the response. Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain the original "id" and the translated HTML in "html". Do not omit any block and keep the same order.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}${_chineseSecondPersonInstruction(config: config)}${_idiomaticTranslationInstruction()}',
              },
              <String, String>{'role': 'user', 'content': payload},
            ],
          };
          final Response<dynamic> response = await owner._postChatCompletions(
            dio: dio,
            data: requestData,
            cancelToken: cancelToken,
          );

          final Map<String, dynamic> jsonPayload = owner._apiClient
              .decodeBatchJsonPayload(response.data);
          final Object? blocksJson = jsonPayload['blocks'];
          if (blocksJson is! List) {
            throw const FormatException(
              'Translated batch blocks is not a JSON array.',
            );
          }
          if (blocksJson.length != batch.blocks.length) {
            throw const FormatException(
              'Translated batch length does not match request length.',
            );
          }

          final Map<String, String> translatedById = <String, String>{};
          final Set<String> requestedIds = batch.blocks
              .map((block) => block.id)
              .toSet();
          if (requestedIds.length != batch.blocks.length) {
            throw const FormatException('Requested block ids must be unique.');
          }
          for (final dynamic item in blocksJson) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Translated batch item is not a JSON object.',
              );
            }
            final Object? id = item['id'];
            final Object? html = item['html'];
            if (id is! String || html is! String || html.trim().isEmpty) {
              throw const FormatException(
                'Translated batch item is missing id or html.',
              );
            }
            if (!requestedIds.contains(id) || translatedById.containsKey(id)) {
              throw const FormatException(
                'Translated batch contains an unknown or duplicate id.',
              );
            }
            translatedById[id] = html.trim();
          }

          final Map<String, String> okById = <String, String>{};
          final List<ExtractedBlock> failedBlocks = <ExtractedBlock>[];
          for (final ExtractedBlock block in batch.blocks) {
            try {
              final String? translated = translatedById[block.id];
              if (translated == null || translated.isEmpty) {
                throw const FormatException(
                  'A translated block is missing from the batch response.',
                );
              }
              final String locked =
                  EpubChapterTranslator._lockTranslatedHtmlStructure(
                    block,
                    translated,
                  );
              EpubChapterTranslator._validateTranslatedBlockQuality(
                config: config,
                block: block,
                translatedHtml: locked,
              );
              okById[block.id] = locked;
              await onValidated?.call(block.id, locked);
            } on FormatException catch (error) {
              // Retry transient quality rejection at batch level. Preserve
              // successfully parsed blocks when only structure is invalid.
              if (_isQualityRejection(error)) {
                rethrow;
              }
              failedBlocks.add(block);
            }
          }
          return _BatchParseOutcome(okById: okById, failedBlocks: failedBlocks);
        },
      );
      if (parsed.failedBlocks.isNotEmpty) {
        final TranslationStyleProfile fallbackStyleProfile =
            _EpubBookMemory._styleProfileFromBookMemoryJson(
              batch.context.bookMemory,
            );
        final bool fallbackConfirmed =
            _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
              batch.context.bookMemory,
            );
        final List<String> retried = await translateBlocksIndividually(
          dio: dio,
          config: config,
          batch: TranslationBlockBatch(
            parsed.failedBlocks,
            context: batch.context,
          ),
          chapterPath: chapterPath,
          styleProfile: fallbackStyleProfile,
          styleProfileConfirmed: fallbackConfirmed,
          retryDelayOverride: retryDelayOverride,
          fallbackWindow: fallbackWindow,
          cancelToken: cancelToken,
          onValidated: onValidated,
        );
        for (int index = 0; index < parsed.failedBlocks.length; index += 1) {
          parsed.okById[parsed.failedBlocks[index].id] = retried[index];
        }
      }
      return <String>[
        for (final ExtractedBlock block in batch.blocks)
          parsed.okById[block.id]!,
      ];
    } on DioException catch (error) {
      if (EpubChapterTranslator._isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      if (TranslationApiClient.isDeterministicHttpError(error)) {
        throw StateError(
          TranslationApiClient.deterministicHttpErrorMessage(error, config),
        );
      }
      if (TranslationApiClient.isConnectionTimeout(error)) {
        for (final ExtractedBlock block in batch.blocks) {
          owner._markDegradedBlock(
            chapterPath: chapterPath ?? '',
            blockId: block.id,
            apiCounted: true,
          );
        }
        return batch.blocks
            .map((ExtractedBlock block) => block.sourceHtml)
            .toList(growable: false);
      }
      if (TranslationApiClient.shouldFallbackBatchDioException(error)) {
        final TranslationStyleProfile fallbackStyleProfile =
            _EpubBookMemory._styleProfileFromBookMemoryJson(
              batch.context.bookMemory,
            );
        final bool fallbackConfirmed =
            _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
              batch.context.bookMemory,
            );
        return translateBlocksIndividually(
          dio: dio,
          config: config,
          batch: batch,
          chapterPath: chapterPath,
          styleProfile: fallbackStyleProfile,
          styleProfileConfirmed: fallbackConfirmed,
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
          fallbackWindow: fallbackWindow,
          onValidated: onValidated,
        );
      }
      rethrow;
    } on FormatException catch (_) {
      final TranslationStyleProfile fallbackStyleProfile =
          _EpubBookMemory._styleProfileFromBookMemoryJson(
            batch.context.bookMemory,
          );
      final bool fallbackConfirmed =
          _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
            batch.context.bookMemory,
          );
      return translateBlocksIndividually(
        dio: dio,
        config: config,
        batch: batch,
        chapterPath: chapterPath,
        styleProfile: fallbackStyleProfile,
        styleProfileConfirmed: fallbackConfirmed,
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        fallbackWindow: fallbackWindow,
        onValidated: onValidated,
      );
    }
  }

  Future<List<String>> translateBlocksIndividually({
    required Dio dio,
    required TranslationConfig config,
    required TranslationBlockBatch batch,
    String? chapterPath,
    required TranslationStyleProfile styleProfile,
    required bool styleProfileConfirmed,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    int? fallbackWindow,
    Future<void> Function(String id, String html)? onValidated,
  }) {
    final int limit = fallbackWindow ?? config.maxConcurrent;
    return const TranslationWorkQueue().map<ExtractedBlock, String>(
      batch.blocks,
      concurrency: limit,
      throwIfCancelled: () {
        if (cancelToken?.isCancelled == true ||
            (isCancelled?.call() ?? false)) {
          throw const TranslationCancelledException();
        }
        owner._run.throwIfCancelled();
      },
      process: (ExtractedBlock block, int index) async {
        try {
          final String translated = await _translateBlock(
            dio: dio,
            config: config,
            block: block,
            context: batch.context,
            chapterPath: chapterPath,
            retryDelayOverride: retryDelayOverride,
            cancelToken: cancelToken,
            styleProfile: styleProfile,
            styleProfileConfirmed: styleProfileConfirmed,
          );
          if (!owner._isDegradedBlock(
            chapterPath: chapterPath ?? '',
            blockId: block.id,
          )) {
            await onValidated?.call(block.id, translated);
          }
          return translated;
        } catch (error) {
          if (error is TranslationCancelledException ||
              EpubChapterTranslator._isCancelError(error) ||
              error is StateError) {
            rethrow;
          }
          owner._markDegradedBlock(
            chapterPath: chapterPath ?? '',
            blockId: block.id,
            apiCounted: true,
          );
          AppLogger.warn(
            'Block ${block.id} kept its source text after repeated '
            'failures (${error.runtimeType}).',
            tag: 'translate',
          );
          return block.sourceHtml;
        }
      },
    );
  }

  Future<String> _translateBlock({
    required Dio dio,
    required TranslationConfig config,
    required ExtractedBlock block,
    required TranslationBatchContext context,
    String? chapterPath,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    TranslationStyleProfile styleProfile = TranslationStyleProfile.empty,
    bool styleProfileConfirmed = false,
  }) async {
    Object? lastError;
    String? lastLocked;
    for (int attempt = 1; ; attempt += 1) {
      try {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        String userContent = block.sourceHtml;
        if (attempt > 1 && lastError != null) {
          // Tell the model why the previous attempt was rejected so a clean
          // retry has a concrete instruction instead of repeating the same
          // (often untranslated) output. Keep the reason lossy/safe — never
          // embed the raw exception or API key here.
          final String reason = owner
              ._safeErrorText(lastError, config)
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          final String retryInstruction = _isEmptyTranslationResponse(lastError)
              ? 'The previous response was empty. Return a complete HTML '
                    'fragment with every human-readable text node translated '
                    'into ${config.targetLanguage}.'
              : 'Translate every human-readable text node into '
                    '${config.targetLanguage}.';
          userContent =
              '$userContent\n\n'
              '[RETRY] The previous translation was rejected for this reason: '
              '$reason. $retryInstruction Only titles, proper names, and '
              'reference data (such as author names, journal names, volume, '
              'issue, year, and page numbers in a bibliography entry) may '
              'stay in the original language. Return the complete HTML '
              'fragment with all tags, attributes, and inline emphasis '
              'preserved.';
        }
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. Preserve every HTML tag, attribute, inline emphasis, entity, and link target. Translate only human-readable text nodes. Return only the translated HTML fragment with no markdown fences and no explanation.${_styleProfileInstruction(config: config, styleProfile: styleProfile, confirmed: styleProfileConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}${_chineseSecondPersonInstruction(config: config)}${_idiomaticTranslationInstruction()}',
            },
            if (!context.isEmpty)
              EpubChapterTranslator._fallbackContextMessage(context),
            <String, String>{'role': 'user', 'content': userContent},
          ],
        };
        final Response<dynamic> response = await owner._postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );

        final String cleaned = _cleanHtmlResponse(
          owner._apiClient.extractMessageContent(response.data),
          sourceText: block.sourceText,
        );
        if (cleaned.isEmpty) {
          throw const FormatException(
            'The translation API returned an empty block.',
          );
        }
        final String locked =
            EpubChapterTranslator._lockTranslatedHtmlStructure(block, cleaned);
        lastLocked = locked;
        EpubChapterTranslator._validateTranslatedBlockQuality(
          config: config,
          block: block,
          translatedHtml: locked,
        );
        return locked;
      } catch (error) {
        if (EpubChapterTranslator._isCancelError(error) ||
            error is TranslationCancelledException) {
          throw const TranslationCancelledException();
        }
        // 401/403/404 are deterministic configuration errors: fail fast with
        // the precise diagnostic instead of burning maxRetries attempts.
        if (TranslationApiClient.isDeterministicHttpError(error)) {
          throw StateError(
            TranslationApiClient.deterministicHttpErrorMessage(error, config),
          );
        }
        lastError = error;
        // A parse failure is deterministic for the same prompt (re-sending
        // the block would just bill the same request again), and a 413 on a
        // single block means even one block is too large to ever succeed:
        // break out and let the normal failure path degrade/throw instead
        // of wasting retries.
        final bool payloadTooLarge =
            error is DioException && error.response?.statusCode == 413;
        if (error is TranslationParseException ||
            payloadTooLarge ||
            attempt >=
                TranslationApiClient.maxAttemptsForError(config, error)) {
          break;
        }
        await TranslationApiClient.delayUnlessCancelled(
          retryDelayOverride ??
              TranslationApiClient.retryDelayForError(config, error, attempt),
          cancelToken: cancelToken,
        );
      }
    }
    // A residual-quality rejection that survives every retry must NOT abort
    // the whole book. The model is not reliably deterministic: one unstable
    // batch reply that leaves a source-language run can fail all retries even
    // when the same block translates correctly on another call. Degrade that
    // one block to its last usable translation (or the source HTML when no
    // reply ever came back), record it for the run report, and keep going.
    // Degrade to the last usable translation. Prefer the structure-locked
    // variant so a quality rejection does not let tag/attribute drift from
    // the raw model reply leak into the EPUB.
    String degradeFallback() {
      final String? usable = lastLocked;
      return usable ?? block.sourceHtml;
    }

    if (lastError is FormatException && _isQualityRejection(lastError)) {
      owner._markDegradedBlock(
        chapterPath: chapterPath ?? '',
        blockId: block.id,
        apiCounted: true,
      );
      return degradeFallback();
    }
    if (lastError is FormatException &&
        _isEmptyTranslationResponse(lastError)) {
      throw StateError(
        'Translation failed after ${config.maxRetries} attempts for block '
        '${block.id}: the translation API returned empty content.',
      );
    }
    if (TranslationApiClient.isRequestTimeout(lastError)) {
      owner._markDegradedBlock(
        chapterPath: chapterPath ?? '',
        blockId: block.id,
        apiCounted: true,
      );
      return degradeFallback();
    }
    if (lastError is TranslationParseException) {
      // A single block whose reply never parsed (e.g. a non-JSON gateway
      // response) is deterministic for this prompt but not systemic: re-
      // sending would just re-bill the same broken prompt. Degrade this
      // block instead of aborting the whole book — consistent with the
      // footnote path, which also degrades per item on parse failures. A
      // systematically broken gateway degrades every block, and the run is
      // then marked failed via allBlocksDegraded, so nothing is silently
      // shipped in the source language.
      owner._markDegradedBlock(
        chapterPath: chapterPath ?? '',
        blockId: block.id,
        apiCounted: true,
      );
      AppLogger.warn(
        'Block ${block.id} kept its source text: the translation API '
        'returned an unparseable response (${lastError.runtimeType}).',
        tag: 'translate',
      );
      return degradeFallback();
    }
    if (lastError is DioException && lastError.response?.statusCode == 413) {
      owner._markDegradedBlock(
        chapterPath: chapterPath ?? '',
        blockId: block.id,
        apiCounted: true,
        reason: 'HTTP 413: block exceeds server request limit; source retained',
      );
      AppLogger.warn(
        'Block ${block.id} exceeds the server request limit (HTTP 413); source retained.',
        tag: 'translate',
      );
      return block.sourceHtml;
    }
    if (lastError is DioException && lastError.error is HandshakeException) {
      final String host = Uri.parse(
        owner._apiClient.normalizedBaseUrl(config.apiBaseUrl),
      ).host;
      throw StateError(
        'TLS handshake failed while connecting to $host. The API endpoint may be blocked on this network, require a proxy/VPN, or be interrupted by certificate inspection.',
      );
    }
    throw StateError(
      'Translation failed after ${config.maxRetries} attempts: $lastError',
    );
  }

  /// Whether [error] is a residual-quality gate rejection. Other transport
  /// failures remain fatal unless they are explicitly handled below.
  static bool _isQualityRejection(Object error) {
    final String message = error.toString();
    return RegExp(
      r'Possible untranslated source-language text remains in block '
      r'|Possible untranslated source-language token '
      r'|Possible untranslated source-language text',
    ).hasMatch(message);
  }

  static String _cleanHtmlResponse(String response, {String sourceText = ''}) {
    String value = response.trim();
    final Match? fence = RegExp(
      r'^```(?:html|xhtml)?\s*\n([\s\S]*?)\n```$',
      caseSensitive: false,
    ).firstMatch(value);
    if (fence != null) value = fence.group(1)!.trim();
    final dom.DocumentFragment fragment = XhtmlHtmlCompatibility.parseFragment(
      value,
    );
    final bool hasMarkup = fragment.nodes.any((node) => node is dom.Element);
    final bool hasOutsideText = fragment.nodes.any(
      (node) => node is dom.Text && node.data.trim().isNotEmpty,
    );
    if (value.contains('```') ||
        _hasTranslationExplanationPrefix(value) ||
        (hasMarkup && hasOutsideText) ||
        _hasTranslationExplanationPrefix(
          _EpubBookMemory._plainTextFromHtmlFragment(value),
        ) ||
        _hasMarkdownWrapper(value) ||
        _hasUnexpectedJsonWrapper(
          sourceText: sourceText,
          translatedText: value,
        )) {
      throw const TranslationParseException(
        'HTML translation contains wrapper content.',
      );
    }
    return value;
  }

  static bool _shouldDegradeSingle(Object error, TranslationConfig config) {
    if (error is TranslationCancelledException ||
        EpubChapterTranslator._isCancelError(error)) {
      throw const TranslationCancelledException();
    }
    if (TranslationApiClient.isDeterministicHttpError(error)) {
      throw StateError(
        TranslationApiClient.deterministicHttpErrorMessage(error, config),
      );
    }
    return error is FormatException ||
        TranslationApiClient.isRequestTimeout(error) ||
        (error is DioException && error.response?.statusCode == 413);
  }

  static String? _oversizedReason(Object error) =>
      error is DioException && error.response?.statusCode == 413
      ? 'HTTP 413: block exceeds server request limit; source retained'
      : null;

  static bool _isEmptyTranslationResponse(Object error) {
    return error is FormatException &&
        error.toString().contains(
          'The translation API returned an empty block.',
        );
  }

  Future<Map<String, String>> _translateFootnoteBatch({
    required Dio dio,
    required TranslationConfig config,
    required FootnoteTranslationBatch batch,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    Future<void> Function(String id, String html)? onValidated,
  }) async {
    final Set<String> requestedIds = batch.references
        .map((FootnoteBlockReference reference) => reference.requestId)
        .toSet();
    if (requestedIds.length != batch.references.length) {
      throw const FormatException(
        'Cross-file footnote request ids must be unique.',
      );
    }

    final List<FootnoteBlockReference> htmlReferences =
        <FootnoteBlockReference>[];
    final List<_ProtectedSlotRequest> slotRequests = <_ProtectedSlotRequest>[];
    for (final FootnoteBlockReference reference in batch.references) {
      final ProtectedAnchorTextSlots? template = _tryParseProtectedSlots(
        reference.block.sourceHtml,
      );
      if (template != null && template.hasProtectedAnchors) {
        slotRequests.add(
          _ProtectedSlotRequest(
            id: reference.requestId,
            block: reference.block,
            template: template,
            chapterPath: reference.chapter.path,
          ),
        );
        continue;
      }
      htmlReferences.add(reference);
    }

    final Map<String, String> translatedById = <String, String>{};
    if (htmlReferences.isNotEmpty) {
      try {
        translatedById.addAll(
          await _translateFootnoteHtmlBatch(
            dio: dio,
            config: config,
            references: htmlReferences,
            context: batch.context,
            retryDelayOverride: retryDelayOverride,
            cancelToken: cancelToken,
            onRequestAttempt: onRequestAttempt,
            onValidated: onValidated,
          ),
        );
      } on DioException catch (error) {
        // 401/403/404/400 are deterministic configuration errors: fail fast
        // with the precise localized diagnostic instead of burning
        // per-reference fallback requests that would all fail the same way.
        if (EpubChapterTranslator._isCancelError(error)) {
          throw const TranslationCancelledException();
        }
        if (TranslationApiClient.isDeterministicHttpError(error)) {
          throw StateError(
            TranslationApiClient.deterministicHttpErrorMessage(error, config),
          );
        }
        if (TranslationApiClient.isConnectionTimeout(error) ||
            (error.response?.statusCode == 413 && htmlReferences.length == 1)) {
          // A connection timeout is endpoint-wide rather than payload-size
          // related. The batch already retried once, so retain its source
          // blocks instead of multiplying the outage into per-block calls.
          for (final FootnoteBlockReference reference in htmlReferences) {
            owner._markDegradedBlock(
              chapterPath: reference.chapter.path,
              blockId: reference.block.id,
              reason: _oversizedReason(error),
            );
            translatedById[reference.requestId] = reference.block.sourceHtml;
            AppLogger.warn(
              'Footnote ${reference.requestId} retained its source (HTTP ${error.response?.statusCode}, ${error.type}).',
              tag: 'translate',
            );
          }
        } else {
          // Send and receive timeouts degrade alike: a receive timeout on a
          // large batch can be payload related, and a send timeout means
          // the payload never left — retrying each reference on its own
          // (one that still times out degrades to its source HTML) matches
          // the main block path, which degrades on any request timeout.
          if (!TranslationApiClient.shouldFallbackBatchDioException(error)) {
            rethrow;
          }
          // A receive timeout on a large batch can be payload related. Retry
          // each reference independently; one that still times out degrades
          // to its source HTML and is reported with the run.
          for (final FootnoteBlockReference reference in htmlReferences) {
            try {
              translatedById.addAll(
                await _translateFootnoteHtmlBatch(
                  dio: dio,
                  config: config,
                  references: <FootnoteBlockReference>[reference],
                  context: batch.context,
                  retryDelayOverride: retryDelayOverride,
                  cancelToken: cancelToken,
                  onRequestAttempt: onRequestAttempt,
                  onValidated: onValidated,
                ),
              );
            } catch (singleError) {
              if (!_shouldDegradeSingle(singleError, config)) {
                rethrow;
              }
              owner._markDegradedBlock(
                chapterPath: reference.chapter.path,
                blockId: reference.block.id,
                reason: _oversizedReason(singleError),
              );
              translatedById[reference.requestId] = reference.block.sourceHtml;
              AppLogger.warn(
                'Footnote ${reference.requestId} retained its source after ${singleError.runtimeType}.',
                tag: 'translate',
              );
            }
          }
        }
      } on FormatException {
        // A malformed model reply is usually deterministic for the same
        // prompt, so the whole batch is not re-sent. Retry each reference
        // on its own; one that still comes back malformed degrades to its
        // source HTML and is reported with the run instead of aborting the
        // whole book.
        for (final FootnoteBlockReference reference in htmlReferences) {
          try {
            translatedById.addAll(
              await _translateFootnoteHtmlBatch(
                dio: dio,
                config: config,
                references: <FootnoteBlockReference>[reference],
                context: batch.context,
                retryDelayOverride: retryDelayOverride,
                cancelToken: cancelToken,
                onRequestAttempt: onRequestAttempt,
                onValidated: onValidated,
              ),
            );
          } catch (singleError) {
            if (!_shouldDegradeSingle(singleError, config)) rethrow;
            owner._markDegradedBlock(
              chapterPath: reference.chapter.path,
              blockId: reference.block.id,
              reason: _oversizedReason(singleError),
            );
            translatedById[reference.requestId] = reference.block.sourceHtml;
          }
        }
      }
    }
    if (slotRequests.isNotEmpty) {
      translatedById.addAll(
        await _translateProtectedSlotBatch(
          dio: dio,
          config: config,
          requests: slotRequests,
          context: batch.context,
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
          onRequestAttempt: onRequestAttempt,
          onValidated: onValidated,
        ),
      );
    }
    return <String, String>{
      for (final FootnoteBlockReference reference in batch.references)
        reference.requestId: translatedById[reference.requestId]!,
    };
  }

  Future<Map<String, String>> _translateFootnoteHtmlBatch({
    required Dio dio,
    required TranslationConfig config,
    required List<FootnoteBlockReference> references,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    Future<void> Function(String id, String html)? onValidated,
  }) {
    final Set<String> requestedIds = references
        .map((FootnoteBlockReference reference) => reference.requestId)
        .toSet();
    final Map<String, dynamic> payloadMap = <String, dynamic>{
      if (!context.isEmpty) 'context': context.toJson(),
      'blocks': references
          .map(
            (FootnoteBlockReference reference) => <String, String>{
              'id': reference.requestId,
              'html': reference.block.sourceHtml,
            },
          )
          .toList(),
    };
    final String payload = jsonEncode(payloadMap);

    return owner._apiClient.runRetried<Map<String, String>>(
      config: config,
      retryDelayOverride: retryDelayOverride,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      operation: () async {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final TranslationStyleProfile batchStyleProfile =
            _EpubBookMemory._styleProfileFromBookMemoryJson(context.bookMemory);
        final bool batchStyleConfirmed =
            _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
              context.bookMemory,
            );
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include a compact read-only bookMemory summary. Use that context only for terminology and style. Translate only items in "blocks". Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, link target, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain exactly one original request "id" and the translated HTML in "html". Return every requested id exactly once.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}${_chineseSecondPersonInstruction(config: config)}${_idiomaticTranslationInstruction()}',
            },
            <String, String>{'role': 'user', 'content': payload},
          ],
        };
        onRequestAttempt?.call();
        final Response<dynamic> response = await owner._postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );
        final Map<String, dynamic> jsonPayload = owner._apiClient
            .decodeBatchJsonPayload(response.data);
        final Object? rawBlocks = jsonPayload['blocks'];
        if (rawBlocks is! List<dynamic> ||
            rawBlocks.length != references.length) {
          throw const FormatException(
            'Translated footnote batch length does not match request length.',
          );
        }

        final Map<String, String> rawTranslatedById = <String, String>{};
        for (final Object? item in rawBlocks) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException(
              'Translated footnote batch item is not a JSON object.',
            );
          }
          final Object? rawId = item['id'];
          final Object? rawHtml = item['html'];
          if (rawId is! String ||
              rawId.isEmpty ||
              rawHtml is! String ||
              rawHtml.trim().isEmpty) {
            throw const FormatException(
              'Translated footnote batch item is missing id or html.',
            );
          }
          if (!requestedIds.contains(rawId)) {
            throw FormatException(
              'Translated footnote batch contains unknown id $rawId.',
            );
          }
          if (rawTranslatedById.containsKey(rawId)) {
            throw FormatException(
              'Translated footnote batch contains duplicate id $rawId.',
            );
          }
          rawTranslatedById[rawId] = rawHtml.trim();
        }

        final Map<String, String> translatedById = <String, String>{};
        for (final FootnoteBlockReference reference in references) {
          final String? translated = rawTranslatedById[reference.requestId];
          if (translated == null) {
            throw FormatException(
              'Translated footnote ${reference.requestId} is missing from the batch response.',
            );
          }
          final String locked =
              EpubChapterTranslator._lockTranslatedHtmlStructure(
                reference.block,
                translated,
              );
          EpubChapterTranslator._validateTranslatedBlockQuality(
            config: config,
            block: reference.block,
            translatedHtml: locked,
          );
          translatedById[reference.requestId] = locked;
          await onValidated?.call(reference.requestId, locked);
        }
        return translatedById;
      },
    );
  }

  Future<Map<String, String>> _translateProtectedSlotBatch({
    required Dio dio,
    required TranslationConfig config,
    required List<_ProtectedSlotRequest> requests,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    int? maxBatchAttempts,
    // The slot pipeline is shared: the main block pipeline counts every
    // block up front (pass true so degrades are subtracted from the
    // report), the footnote pipeline never counts degrades (leave false).
    bool apiCounted = false,
    Future<void> Function(String id, String html)? onValidated,
  }) async {
    final Set<String> requestedIds = requests
        .map((_ProtectedSlotRequest request) => request.id)
        .toSet();
    if (requestedIds.length != requests.length) {
      throw const FormatException('Protected slot request ids must be unique.');
    }
    try {
      return await _translateProtectedSlotBatchOnce(
        dio: dio,
        config: config,
        requests: requests,
        context: context,
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        onRequestAttempt: onRequestAttempt,
        maxAttemptsOverride: maxBatchAttempts,
        onValidated: onValidated,
      );
    } on FormatException catch (error) {
      if (requests.length == 1) {
        try {
          final Map<String, String> translated =
              await _translateProtectedSlotsIndividually(
                dio: dio,
                config: config,
                request: requests.single,
                context: context,
                retryDelayOverride: retryDelayOverride,
                cancelToken: cancelToken,
                onRequestAttempt: onRequestAttempt,
              );
          await onValidated?.call(
            requests.single.id,
            translated[requests.single.id]!,
          );
          return translated;
        } catch (singleError) {
          if (_shouldDegradeSingle(singleError, config)) {
            owner._markDegradedBlock(
              chapterPath: requests.single.chapterPath,
              blockId: requests.single.block.id,
              apiCounted: apiCounted,
              reason: _oversizedReason(singleError),
            );
            AppLogger.warn(
              'Protected block ${requests.single.block.id} retained its source after ${singleError.runtimeType}.',
              tag: 'translate',
            );
            return <String, String>{
              requests.single.id: requests.single.block.sourceHtml,
            };
          }
          rethrow;
        }
      }
      if (error is TranslationParseException) {
        // Deterministic failure: the model did not return JSON for this
        // prompt shape, so bisecting would just re-bill the same broken
        // prompt at every level of the split. Translate each block's slots
        // directly instead (the single-request path below still degrades
        // quality rejections per block).
        final Map<String, String> translated = <String, String>{};
        for (final _ProtectedSlotRequest request in requests) {
          translated.addAll(
            await _translateProtectedSlotBatch(
              dio: dio,
              config: config,
              requests: <_ProtectedSlotRequest>[request],
              context: context,
              retryDelayOverride: retryDelayOverride,
              cancelToken: cancelToken,
              onRequestAttempt: onRequestAttempt,
              apiCounted: apiCounted,
              onValidated: onValidated,
            ),
          );
        }
        return translated;
      }
      // Validation failure on a well-formed reply: bisect, but each level
      // gets a single attempt. A deterministic validation failure must not
      // eat maxRetries at every level of the split.
      final int midpoint = requests.length ~/ 2;
      final Map<String, String> left = await _translateProtectedSlotBatch(
        dio: dio,
        config: config,
        requests: requests.sublist(0, midpoint),
        context: context,
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        onRequestAttempt: onRequestAttempt,
        maxBatchAttempts: 1,
        apiCounted: apiCounted,
        onValidated: onValidated,
      );
      final Map<String, String> right = await _translateProtectedSlotBatch(
        dio: dio,
        config: config,
        requests: requests.sublist(midpoint),
        context: context,
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        onRequestAttempt: onRequestAttempt,
        maxBatchAttempts: 1,
        apiCounted: apiCounted,
        onValidated: onValidated,
      );
      return <String, String>{...left, ...right};
    } on DioException catch (error) {
      if (EpubChapterTranslator._isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      // 401/403/404 are deterministic configuration errors: fail fast with
      // the precise diagnostic instead of billing per-block fallback
      // requests that would all fail the same way.
      if (TranslationApiClient.isDeterministicHttpError(error)) {
        throw StateError(
          TranslationApiClient.deterministicHttpErrorMessage(error, config),
        );
      }
      if (TranslationApiClient.isConnectionTimeout(error)) {
        for (final _ProtectedSlotRequest request in requests) {
          owner._markDegradedBlock(
            chapterPath: request.chapterPath,
            blockId: request.block.id,
            apiCounted: apiCounted,
          );
        }
        return <String, String>{
          for (final _ProtectedSlotRequest request in requests)
            request.id: request.block.sourceHtml,
        };
      }
      if (_shouldDegradeSingle(error, config) && requests.length == 1) {
        // A send timeout on a single slot request means the payload never
        // left; degrading to the source text matches the main block path,
        // which degrades on any request timeout instead of aborting the run.
        owner._markDegradedBlock(
          chapterPath: requests.single.chapterPath,
          blockId: requests.single.block.id,
          apiCounted: apiCounted,
          reason: _oversizedReason(error),
        );
        AppLogger.warn(
          'Protected block ${requests.single.block.id} retained its source after ${error.runtimeType} (HTTP ${error.response?.statusCode}).',
          tag: 'translate',
        );
        return <String, String>{
          requests.single.id: requests.single.block.sourceHtml,
        };
      }
      if (!TranslationApiClient.shouldFallbackBatchDioException(error) ||
          requests.length == 1) {
        rethrow;
      }
    }

    // Transport-level fallback (e.g. 413 payload too large): split the batch
    // with the normal per-level retry policy; smaller payloads usually pass.
    final int midpoint = requests.length ~/ 2;
    final Map<String, String> left = await _translateProtectedSlotBatch(
      dio: dio,
      config: config,
      requests: requests.sublist(0, midpoint),
      context: context,
      retryDelayOverride: retryDelayOverride,
      cancelToken: cancelToken,
      onRequestAttempt: onRequestAttempt,
      apiCounted: apiCounted,
      onValidated: onValidated,
    );
    final Map<String, String> right = await _translateProtectedSlotBatch(
      dio: dio,
      config: config,
      requests: requests.sublist(midpoint),
      context: context,
      retryDelayOverride: retryDelayOverride,
      cancelToken: cancelToken,
      onRequestAttempt: onRequestAttempt,
      apiCounted: apiCounted,
      onValidated: onValidated,
    );
    return <String, String>{...left, ...right};
  }

  Future<Map<String, String>> _translateProtectedSlotBatchOnce({
    required Dio dio,
    required TranslationConfig config,
    required List<_ProtectedSlotRequest> requests,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    int? maxAttemptsOverride,
    Future<void> Function(String id, String html)? onValidated,
  }) {
    final Set<String> requestedIds = requests
        .map((_ProtectedSlotRequest request) => request.id)
        .toSet();
    final Map<String, _ProtectedSlotRequest> requestById =
        <String, _ProtectedSlotRequest>{
          for (final _ProtectedSlotRequest request in requests)
            request.id: request,
        };
    final String payload = jsonEncode(<String, Object?>{
      if (!context.isEmpty) 'context': context.toJson(),
      'blocks': requests
          .map((_ProtectedSlotRequest request) => request.toJson())
          .toList(growable: false),
    });

    return owner._apiClient.runRetried<Map<String, String>>(
      config: config,
      retryDelayOverride: retryDelayOverride,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      maxAttemptsOverride: maxAttemptsOverride,
      operation: () async {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final TranslationStyleProfile batchStyleProfile =
            _EpubBookMemory._styleProfileFromBookMemoryJson(context.bookMemory);
        final bool batchStyleConfirmed =
            _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
              context.bookMemory,
            );
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'Translate only each slot "text" into ${config.targetLanguage}. Return strict JSON only, with exactly the requested block ids and slot ids. Every block must contain only "id" and "slots"; every slot must contain only string "id" and string "text"; never return HTML, tags, attributes, markdown, or explanations. Treat angle brackets in translated text as ordinary text.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}${_chineseSecondPersonInstruction(config: config)}${_idiomaticTranslationInstruction()}',
            },
            <String, String>{'role': 'user', 'content': payload},
          ],
        };
        onRequestAttempt?.call();
        final Response<dynamic> response = await owner._postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );
        final Map<String, dynamic> jsonPayload = owner._apiClient
            .decodeBatchJsonPayload(response.data);
        final Object? rawBlocks = jsonPayload['blocks'];
        if (rawBlocks is! List<dynamic> ||
            rawBlocks.length != requests.length) {
          throw const FormatException(
            'Translated slot block count does not match request count.',
          );
        }

        final Map<String, List<String>> translatedSlotsById =
            <String, List<String>>{};
        for (final Object? rawBlock in rawBlocks) {
          if (rawBlock is! Map<String, dynamic> ||
              rawBlock.keys.toSet().difference(const <String>{
                'id',
                'slots',
              }).isNotEmpty ||
              const <String>{
                'id',
                'slots',
              }.difference(rawBlock.keys.toSet()).isNotEmpty) {
            throw const FormatException(
              'Translated slot block must contain only id and slots.',
            );
          }
          final Object? rawId = rawBlock['id'];
          final Object? rawSlots = rawBlock['slots'];
          if (rawId is! String ||
              !requestedIds.contains(rawId) ||
              translatedSlotsById.containsKey(rawId)) {
            throw const FormatException(
              'Translated slot response contains an unknown or duplicate block id.',
            );
          }
          final _ProtectedSlotRequest request = requestById[rawId]!;
          if (rawSlots is! List<dynamic> ||
              rawSlots.length != request.template.slotTexts.length) {
            throw FormatException(
              'Translated slot count does not match block $rawId.',
            );
          }
          final Map<String, String> textBySlotId = <String, String>{};
          final Set<String> expectedSlotIds = request.slotIds.toSet();
          for (final Object? rawSlot in rawSlots) {
            if (rawSlot is! Map<String, dynamic> ||
                rawSlot.keys.toSet().difference(const <String>{
                  'id',
                  'text',
                }).isNotEmpty ||
                const <String>{
                  'id',
                  'text',
                }.difference(rawSlot.keys.toSet()).isNotEmpty) {
              throw const FormatException(
                'Translated slot must contain only id and text.',
              );
            }
            final Object? rawSlotId = rawSlot['id'];
            final Object? rawText = rawSlot['text'];
            if (rawSlotId is! String ||
                !expectedSlotIds.contains(rawSlotId) ||
                textBySlotId.containsKey(rawSlotId) ||
                rawText is! String) {
              throw const FormatException(
                'Translated slot contains an unknown or duplicate id, or non-string text.',
              );
            }
            textBySlotId[rawSlotId] = rawText;
          }
          translatedSlotsById[rawId] = request.slotIds
              .map((String slotId) => textBySlotId[slotId]!)
              .toList(growable: false);
        }

        final Map<String, String> translated = <String, String>{};
        for (final _ProtectedSlotRequest request in requests) {
          final String html = _renderAndValidateProtectedSlots(
            config: config,
            request: request,
            translatedSlots: translatedSlotsById[request.id]!,
          );
          translated[request.id] = html;
          await onValidated?.call(request.id, html);
        }
        return translated;
      },
    );
  }

  Future<Map<String, String>> _translateProtectedSlotsIndividually({
    required Dio dio,
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) async {
    // A manual retry loop instead of runRetried so that (a) a whole-round
    // retry carries the previous failure reason into the prompt — like
    // _translateBlock's [RETRY] instruction, a blind re-send of the same
    // prompt usually reproduces the same rejection — and (b) a repeated
    // *identical* render/quality failure stops re-billing the whole round:
    // the model is deterministically reproducing the rejected shape, so
    // further rounds would just burn tokens. The caller then degrades the
    // block instead of aborting the book.
    final Set<String> seenFailureSignatures = <String>{};
    String? retryReason;
    for (int attempt = 1; ; attempt += 1) {
      try {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        return await _translateProtectedSlotsIndividuallyOnce(
          dio: dio,
          config: config,
          request: request,
          context: context,
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
          onRequestAttempt: onRequestAttempt,
          retryReason: retryReason,
        );
      } catch (error, stackTrace) {
        if (error is TranslationCancelledException ||
            EpubChapterTranslator._isCancelError(error)) {
          throw const TranslationCancelledException();
        }
        final bool retryable = TranslationApiClient.shouldRetryBatchError(
          error,
        );
        final int maxAttempts = TranslationApiClient.maxAttemptsForError(
          config,
          error,
        );
        final String signature = owner
            ._safeErrorText(error, config)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final bool repeatedDeterministic =
            error is FormatException &&
            error is! TranslationParseException &&
            !seenFailureSignatures.add(signature);
        if (!retryable || repeatedDeterministic || attempt >= maxAttempts) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        retryReason = signature;
        await TranslationApiClient.delayUnlessCancelled(
          retryDelayOverride ??
              TranslationApiClient.retryDelayForError(config, error, attempt),
          cancelToken: cancelToken,
        );
      }
    }
  }

  Future<Map<String, String>> _translateProtectedSlotsIndividuallyOnce({
    required Dio dio,
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    String? retryReason,
  }) async {
    final List<String> translatedSlots = <String>[];
    for (final String sourceText in request.template.slotTexts) {
      // Retry at the slot level: a transient failure on slot k must not
      // re-bill the slots that already translated cleanly. A render/quality
      // failure of the rebuilt block still retries the whole round via the
      // loop in [_translateProtectedSlotsIndividually].
      translatedSlots.add(
        await owner._apiClient.runRetried<String>(
          config: config,
          retryDelayOverride: retryDelayOverride,
          shouldRetry: TranslationApiClient.shouldRetryBatchError,
          cancelToken: cancelToken,
          operation: () => _translateProtectedSlotTextOnce(
            dio: dio,
            config: config,
            sourceText: sourceText,
            context: context,
            cancelToken: cancelToken,
            onRequestAttempt: onRequestAttempt,
            retryReason: retryReason,
          ),
        ),
      );
    }
    return <String, String>{
      request.id: _renderAndValidateProtectedSlots(
        config: config,
        request: request,
        translatedSlots: translatedSlots,
      ),
    };
  }

  Future<String> _translateProtectedSlotTextOnce({
    required Dio dio,
    required TranslationConfig config,
    required String sourceText,
    required TranslationBatchContext context,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    String? retryReason,
  }) async {
    final String trimmedSource = sourceText.trim();
    if (cancelToken?.isCancelled ?? false) {
      throw const TranslationCancelledException();
    }
    // Tell the model why the previous whole-round attempt was rejected so
    // the retry has a concrete instruction instead of reproducing the same
    // rejected shape. The reason is lossy/safe — never the raw exception.
    final String userText = retryReason == null
        ? trimmedSource
        : '$trimmedSource\n\n[RETRY] The previous translation was rejected '
              'for this reason: $retryReason. Translate the text again into '
              '${config.targetLanguage}, returning only the translated text '
              'with no JSON, HTML, Markdown formatting, labels, or '
              'explanation.';
    final TranslationStyleProfile batchStyleProfile =
        _EpubBookMemory._styleProfileFromBookMemoryJson(context.bookMemory);
    final bool batchStyleConfirmed =
        _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
          context.bookMemory,
        );
    final Map<String, dynamic> requestData = <String, dynamic>{
      'model': config.model,
      'temperature': 0.2,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'Translate the user text into ${config.targetLanguage}. Return only the translated text, with no JSON, HTML, Markdown formatting, labels, or explanation.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}${_chineseSecondPersonInstruction(config: config)}${_idiomaticTranslationInstruction()}',
        },
        if (!context.isEmpty)
          EpubChapterTranslator._fallbackContextMessage(context),
        <String, String>{'role': 'user', 'content': userText},
      ],
    };
    onRequestAttempt?.call();
    final Response<dynamic> response = await owner._postChatCompletions(
      dio: dio,
      data: requestData,
      cancelToken: cancelToken,
    );
    final String translated = owner._apiClient.extractMessageContent(
      response.data,
    );
    _validateIndividualSlotTranslation(
      sourceText: trimmedSource,
      translatedText: translated,
    );
    return translated.trim();
  }

  /// Matches an HTML tag open inside a protected-slot translation
  /// (`<p>`, `</p>`, `<!DOCTYPE …>`, `<?xml …>`). The `<` must be
  /// immediately followed by a letter, `/`, `!` or `?`: `a < b > c` is
  /// plain text (browsers treat `< ` as text, not markup), so a comparison
  /// must not trip the wrapper detector — otherwise it would burn
  /// maxRetries² paid retries across the nested retry layers.
  static final RegExp _slotWrapperTagPattern = RegExp(r'</?[A-Za-z!?][^>]*>');

  static void _validateIndividualSlotTranslation({
    required String sourceText,
    required String translatedText,
  }) {
    final String trimmed = translatedText.trim();
    if (trimmed.isEmpty) {
      // Deterministic: re-sending the same prompt will not make the model
      // produce content, so throw TranslationParseException (no retry) rather
      // than FormatException (which the retry policy would re-bill).
      throw const TranslationParseException(
        'Individual protected slot translation is empty.',
      );
    }
    if (trimmed.contains('```') ||
        _hasUnexpectedJsonWrapper(
          sourceText: sourceText,
          translatedText: trimmed,
        ) ||
        _hasMarkdownWrapper(trimmed) ||
        RegExp(r'<!--[\s\S]*?-->').hasMatch(trimmed) ||
        // See [_slotWrapperTagPattern]: `<` must abut a letter/`/`/`!`/`?`
        // or a comparison like "a < b" is misread as markup.
        _slotWrapperTagPattern.hasMatch(trimmed) ||
        _hasTranslationExplanationPrefix(trimmed)) {
      throw const TranslationParseException(
        'Individual protected slot translation contains wrapper content.',
      );
    }
  }

  static bool _hasMarkdownWrapper(String value) {
    if (RegExp(r'^`{1,2}[\s\S]+`{1,2}$').hasMatch(value) ||
        RegExp(r'^~~[\s\S]+~~$').hasMatch(value) ||
        RegExp(r'^\*\*[\s\S]+\*\*$').hasMatch(value) ||
        RegExp(r'^__[\s\S]+__$').hasMatch(value) ||
        RegExp(r'^\*[\s\S]+\*$').hasMatch(value) ||
        RegExp(r'^_[\s\S]+_$').hasMatch(value) ||
        RegExp(r'!?\[[^\]\r\n]+\]\([^\)\r\n]+\)').hasMatch(value)) {
      return true;
    }
    return value
        .split(RegExp(r'\r?\n'))
        .any(
          (String line) =>
              RegExp(r'^\s*(?:#{1,6}|>|[-+*]|\d+[.)])\s+').hasMatch(line) ||
              RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line) ||
              RegExp(r'^\s*\|.*\|\s*$').hasMatch(line),
        );
  }

  static bool _hasTranslationExplanationPrefix(String value) {
    return RegExp(
          r'^(?:(?:好的|当然|可以|没问题)[，,。.!！\s]*)?(?:(?:以下|下面)是)?(?:译文|翻译(?:结果|内容)?)(?:如下)?\s*[:：]',
        ).hasMatch(value) ||
        RegExp(
          r"^(?:(?:sure|certainly|of course|okay|ok)[,!.]?\s*)?(?:here(?:'s| is)\s+)?(?:the\s+)?(?:translation(?: result)?|translated (?:text|html(?: fragment)?))(?:\s+is)?\s*[:：]",
          caseSensitive: false,
        ).hasMatch(value);
  }

  static bool _hasUnexpectedJsonWrapper({
    required String sourceText,
    required String translatedText,
  }) {
    if (!RegExp(
      r'^[\[{"\d\-]|^(?:true|false|null)$',
    ).hasMatch(translatedText)) {
      return false;
    }
    try {
      final Object? decoded = jsonDecode(translatedText);
      if (decoded is String) {
        final String source = sourceText.trim();
        return !(source.startsWith('"') && source.endsWith('"'));
      }
      if (decoded is Map || decoded is List) return true;
      // Numbers and booleans are ordinary text when the source is also a
      // scalar, rather than evidence of a JSON protocol response.
      if (decoded is num || decoded is bool) {
        try {
          final Object? source = jsonDecode(sourceText.trim());
          return !((decoded is num && source is num) ||
              (decoded is bool && source is bool));
        } on FormatException {
          return true;
        }
      }
      return decoded == null && sourceText.trim() != 'null';
    } on FormatException {
      return false;
    }
  }

  static String _renderAndValidateProtectedSlots({
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required List<String> translatedSlots,
  }) {
    final String rendered = request.template.render(translatedSlots);
    EpubChapterTranslator._validateTranslatedBlockQuality(
      config: config,
      block: request.block,
      translatedHtml: rendered,
    );
    return rendered;
  }

  /// Parses [sourceHtml] for protected-anchor slot translation, returning
  /// null when the fragment does not meet [ProtectedAnchorTextSlots.parse]'s
  /// single-root requirement. [ProtectedAnchorTextSlots.containsProtectedAnchors]
  /// is intentionally looser than [parse] (it also covers ordinary
  /// multi-root HTML), so a block can pass the check yet fail the parse;
  /// falling back to the plain HTML path keeps one odd block from failing
  /// its whole batch.
  static ProtectedAnchorTextSlots? _tryParseProtectedSlots(String sourceHtml) {
    try {
      return ProtectedAnchorTextSlots.parse(sourceHtml);
    } on FormatException {
      return null;
    }
  }

  String _styleProfileInstruction({
    required TranslationConfig config,
    TranslationStyleProfile? styleProfile,
    bool confirmed = false,
  }) {
    if (!config.styleProfileEnabled) {
      return '';
    }
    final TranslationStyleProfile? profile = styleProfile;
    if (profile == null || profile.isEmpty) {
      return '';
    }
    if (confirmed) {
      return profile.toConfirmedPromptInstruction(
        targetLanguage: config.targetLanguage,
      );
    }
    return profile.toPromptInstruction(targetLanguage: config.targetLanguage);
  }

  /// Terminology gloss rule that applies to every translation path.
  ///
  /// For CJK targets (mainly Chinese), a term that is hard to transliterate and
  /// carries real historical/technical meaning (for example "assarting") should
  /// be translated and, on its FIRST occurrence in the book, kept in the
  /// original language inside full-width parentheses as a gloss. Later
  /// occurrences use only the translated form. This helps preserve semantic
  /// precision without leaving bare source-language tokens flagged by the
  /// residual-quality check.
  String _terminologyGlossInstruction({required TranslationConfig config}) {
    if (!EpubChapterTranslator._isCjkTargetLanguage(config.targetLanguage)) {
      return '';
    }
    return ' For a term that is hard to transliterate and carries real '
        'historical or technical meaning (for example "assarting" meaning '
        '"clearing forest land"), translate it into ${config.targetLanguage} '
        'and, on its first occurrence in the book, keep the original term '
        'inside full-width parentheses as a gloss, for example '
        '伐林开垦（assarting） (translated term followed by original term). On later occurrences use only the translated '
        'form without parentheses. Keep the gloss term inside the same inline '
        'text run and exact same element as the translated term would occupy.';
  }

  /// Second-person formality rule for Chinese targets, applied to every
  /// translation path like the terminology gloss rule.
  ///
  /// Models tend to mix 你 (informal) and 您 (formal) within one book;
  /// published Chinese translations conventionally use 您 throughout, so
  /// the rule is stated explicitly. Prompt-level only: a model can still
  /// deviate, but in practice the explicit instruction holds.
  String _chineseSecondPersonInstruction({required TranslationConfig config}) {
    final bool isChinese =
        EpubChapterTranslator.normalizeTargetLanguage(config.targetLanguage) ==
        'zh';
    if (!isChinese) {
      return '';
    }
    // Second-person formality is a pragmatic judgment, not a fixed rule: the
    // model chooses between 您 and 你 from the speaker/addressee relationship
    // visible in context. Prompt-level only; consistency for the same speaker
    // pair across batches is best-effort.
    return ' When the target language is Chinese, choose between 您 (formal) '
        'and 你 (informal) for the second person based on the relationship '
        'between speaker and addressee: use 您 for strangers, business or '
        'service interactions, and respectful address; use 你 for family, '
        'close friends, lovers, children, and the narrator\'s intimate asides '
        'to the reader (for example, "you see" as a discourse marker becomes '
        '你看, not 您看). Once chosen for a given pair of speakers, keep it '
        'consistent throughout the book.';
  }

  /// Universal (not language-gated): render meaning, not words. Idioms,
  /// metaphors, and figurative expressions must be translated by their
  /// intended meaning in natural target-language phrasing, never word for
  /// word. Prompt-level only; the model can still produce translationese.
  String _idiomaticTranslationInstruction() {
    return ' Translate meaning, not words: render idioms, metaphors, and '
        'figurative expressions by their intended meaning in natural, '
        'idiomatic target-language phrasing. Never translate them word for '
        'word or calque source-language metaphors literally.';
  }
}

class _ProtectedSlotRequest {
  const _ProtectedSlotRequest({
    required this.id,
    required this.block,
    required this.template,
    required this.chapterPath,
  });

  final String id;
  final ExtractedBlock block;
  final ProtectedAnchorTextSlots template;

  /// Scopes degraded-block tracking: block ids restart per chapter, so the
  /// bare id would collide across chapters.
  final String chapterPath;

  List<String> get slotIds => List<String>.generate(
    template.slotTexts.length,
    (int index) => 's$index',
    growable: false,
  );

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'slots': <Map<String, String>>[
        for (int index = 0; index < template.slotTexts.length; index += 1)
          <String, String>{'id': 's$index', 'text': template.slotTexts[index]},
      ],
    };
  }
}

/// Outcome of parsing one translated batch: blocks that parsed cleanly and
/// passed quality, plus the blocks that failed and need an individual retry.
class _BatchParseOutcome {
  const _BatchParseOutcome({required this.okById, required this.failedBlocks});

  final Map<String, String> okById;
  final List<ExtractedBlock> failedBlocks;
}
