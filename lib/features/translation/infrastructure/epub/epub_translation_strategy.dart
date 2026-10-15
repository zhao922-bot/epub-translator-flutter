part of 'epub_chapter_translator.dart';

/// Legal JSON with a deterministic shape mismatch: no identical retry, but a
/// smaller protected-slot payload can still use the established bisect path.
class _DeterministicBatchStructureException extends TranslationParseException {
  const _DeterministicBatchStructureException(super.message);
}

/// Only rebuilt-block validation may trigger a whole individual-slot round.
class _ProtectedSlotRenderException extends FormatException {
  const _ProtectedSlotRenderException(super.message);
}

/// Owns HTML, protected-slot, and cross-file footnote translation strategies,
/// including response validation, prompt rules, splitting, retries, and fallback.
/// Every request goes through the invocation owner; child work shares the outer
/// queue's HTTP budget without holding a permit for a parent strategy operation.
class _EpubTranslationStrategy {
  _EpubTranslationStrategy(this.owner);

  final EpubChapterTranslator owner;

  /// Preserve the shared exception contract: structural replies use
  /// TranslationParseException (no retry), syntax jitter uses FormatException.
  /// Validate before the legacy decoder wraps every syntax failure as final.
  /// Returns the already-parsed payload so callers do not decode the same
  /// reply a second time.
  Map<String, dynamic> _validateBatchReply(
    dynamic response,
    Set<String> ids, {
    Map<String, Set<String>>? slotIds,
  }) {
    final content = owner._apiClient.extractMessageContent(response);
    late final Map<String, dynamic> json;
    try {
      json = owner._apiClient.decodeJsonObject(content);
    } on FormatException catch (error) {
      // A legal JSON scalar/array is a deterministic schema mismatch. Broken
      // JSON beginning with an object/fence is transport/model format jitter.
      // decodeJsonObject() already stripped fences before failing, so the
      // classification must run on the fence-stripped candidate: decoding
      // the raw content here would always fail on fenced replies and
      // misclassify a legal non-object as retryable jitter.
      final stripped = owner._apiClient.decodeJsonValueAfterFenceStrip(content);
      final String trimmed = content.trimLeft();
      if (!stripped.valid &&
          (trimmed.startsWith('{') || trimmed.startsWith('```')) &&
          !error.message.contains('duplicate object key')) {
        throw const FormatException('Retryable JSON syntax jitter.');
      }
      throw TranslationParseException(
        'Deterministic JSON schema failure (${stripped.value.runtimeType}).',
      );
    }
    final blocks = json['blocks'];
    if (blocks is! List || blocks.length != ids.length) {
      throw const _DeterministicBatchStructureException(
        'Response must contain all requested blocks.',
      );
    }
    final seen = <String>{};
    for (final item in blocks) {
      if (item is! Map<String, dynamic> ||
          item['id'] is! String ||
          !ids.contains(item['id']) ||
          !seen.add(item['id'] as String)) {
        throw const _DeterministicBatchStructureException(
          'Response block structure/id mismatch.',
        );
      }
      if (slotIds == null) {
        if (item['html'] is! String) {
          throw const _DeterministicBatchStructureException(
            'Response block is missing string html.',
          );
        }
      } else {
        final slots = item['slots'];
        final expected = slotIds[item['id']]!;
        final seenSlots = <String>{};
        if (item.keys.length != 2 ||
            slots is! List ||
            slots.length != expected.length) {
          throw const _DeterministicBatchStructureException(
            'Response slot structure/count mismatch.',
          );
        }
        for (final slot in slots) {
          if (slot is! Map<String, dynamic> ||
              slot.keys.length != 2 ||
              slot['id'] is! String ||
              slot['text'] is! String ||
              !expected.contains(slot['id']) ||
              !seenSlots.add(slot['id'] as String)) {
            throw const _DeterministicBatchStructureException(
              'Response slot structure/id mismatch.',
            );
          }
          // An empty slot translation would render as empty HTML, silently
          // dropping the source text from the finished book. Reject it like
          // the individual-slot path does (TranslationParseException, not a
          // retryable FormatException): the request is then retried on its
          // own and degrades to its source text instead of shipping empty.
          if ((slot['text'] as String).trim().isEmpty) {
            throw const TranslationParseException(
              'Translated slot text is empty.',
            );
          }
        }
      }
    }
    return json;
  }

  // Strategy workers never hold HTTP permits while waiting for child work.
  // Every leaf request acquires the invocation's shared budget via the owner.
  Future<Map<String, String>> _mapTranslations<T>(
    List<T> items, {
    required TranslationConfig config,
    CancelToken? cancelToken,
    required Future<Map<String, String>> Function(T item) process,
  }) async {
    final results = await const TranslationWorkQueue()
        .map<T, Map<String, String>>(
          items,
          concurrency: config.maxConcurrent,
          throwIfCancelled: () {
            owner._run.throwIfCancelled();
            if (cancelToken?.isCancelled == true) {
              throw const TranslationCancelledException();
            }
          },
          process: (item, _) => process(item),
        );
    return <String, String>{for (final result in results) ...result};
  }

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
    final Map<String, String> translatedById = <String, String>{};
    for (final ExtractedBlock block in batch.blocks) {
      if (config.semanticQualityCheck) {
        final draft = await owner._semanticReviewer.readDraft(
          config,
          chapterPath ?? '',
          block,
          batch.context,
        );
        owner._run.throwIfCancelled();
        if (draft != null) {
          translatedById[block.id] = draft;
          continue;
        }
      }
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

    if (htmlBlocks.isNotEmpty) {
      final List<String> translatedHtml = await translateHtmlBlockBatch(
        dio: dio,
        config: config,
        chapterPath: chapterPath,
        batch: TranslationBlockBatch(htmlBlocks, context: batch.context),
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        fallbackWindow: fallbackWindow,
        onValidated: config.semanticQualityCheck ? null : onValidated,
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
          onValidated: config.semanticQualityCheck ? null : onValidated,
        ),
      );
    }
    if (config.semanticQualityCheck) {
      await owner._semanticReviewer.review(
        dio: dio,
        config: config,
        batch: batch,
        translations: translatedById,
        chapterPath: chapterPath ?? '',
        cancelToken: cancelToken,
      );
      for (final block in batch.blocks) {
        if (!owner._isDegradedBlock(
              chapterPath: chapterPath ?? '',
              blockId: block.id,
            ) &&
            !owner._run.isUnreviewed(chapterPath ?? '', block.id)) {
          await onValidated?.call(block.id, translatedById[block.id]!);
        }
      }
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
                    'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include read-only context before and after the requested blocks plus a compact bookMemory summary of earlier chapters. Use that context only for continuity, pronouns, tone, terminology, and paragraph flow. Reuse canonical bookMemory glossary targets for repeated names and brands; never alternate transliteration with paraphrases. Honor known family relationships; do not guess gender or older/younger status from unqualified English nouns. Choose ambiguous plant, object, historical and medical terms from context, without adding unsupported specificity. Translate only items in "blocks"; never include context items in the response. Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain the original "id" and the translated HTML in "html". Do not omit any block and keep the same order.${_styleInstructionFragment(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_idiomaticTranslationInstruction()}',
              },
              <String, String>{'role': 'user', 'content': payload},
            ],
          };
          final Response<dynamic> response = await owner._postChatCompletions(
            dio: dio,
            data: requestData,
            cancelToken: cancelToken,
          );

          // The validator returns the already-parsed payload: decoding the
          // same reply again would double the JSON parse cost per batch.
          final Map<String, dynamic> jsonPayload = _validateBatchReply(
            response.data,
            batch.blocks.map((b) => b.id).toSet(),
          );
          final List<dynamic> blocksJson =
              jsonPayload['blocks'] as List<dynamic>;

          final Map<String, String> translatedById = <String, String>{};
          final Set<String> requestedIds = batch.blocks
              .map((block) => block.id)
              .toSet();
          if (requestedIds.length != batch.blocks.length) {
            throw const FormatException('Requested block ids must be unique.');
          }
          for (final Map<String, dynamic> item
              in blocksJson.cast<Map<String, dynamic>>()) {
            final String id = item['id'] as String;
            final Object? html = item['html'];
            if (id.isEmpty) {
              throw const FormatException(
                'Translated batch item is missing id.',
              );
            }
            // An empty or missing html is a per-block failure, not a batch
            // failure: leave it unrecorded so the per-block loop below
            // routes only this block to the individual retry instead of
            // re-billing every healthy block in the batch.
            if (html is String && html.trim().isNotEmpty) {
              translatedById[id] = html.trim();
            }
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
                  EpubChapterTranslator._lockAndValidateTranslatedBlock(
                    config: config,
                    block: block,
                    translatedHtml: translated,
                  );
              okById[block.id] = locked;
              await onValidated?.call(block.id, locked);
            } on FormatException {
              // Both structure and quality failures are local to this item.
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
      // Shrink fallback first: a context-overflow 400 (or 413 / send-receive
      // timeout) is payload-size dependent, so per-block requests can still
      // succeed. Only errors that no smaller request could fix stay fatal.
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
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. Preserve every HTML tag, attribute, inline emphasis, entity, and link target. Translate only human-readable text nodes. Return only the translated HTML fragment with no markdown fences and no explanation.${_styleInstructionFragment(config: config, styleProfile: styleProfile, confirmed: styleProfileConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_idiomaticTranslationInstruction()}',
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

        // Single-parse entry: _cleanResponseDom parses the reply once and
        // hands the DOM to the structure lock, instead of the old string
        // cleaner (which parsed the reply twice) plus another parse inside
        // the lock. rejectEmptyResponse keeps the empty-reply contract.
        final _ResponseHtml replyDom = EpubChapterTranslator._cleanResponseDom(
          owner._apiClient.extractMessageContent(response.data),
          sourceText: block.sourceText,
          rejectEmptyResponse: true,
        );
        final String locked =
            EpubChapterTranslator._lockAndValidateTranslatedBlockDom(
              config: config,
              block: block,
              replyDom: replyDom,
              // Capture the locked reply before quality validation below:
              // a residual-quality rejection must degrade to this usable
              // locked HTML, not to the raw source.
              onLocked: (String html) => lastLocked = html,
            );
        return locked;
      } catch (error) {
        if (EpubChapterTranslator._isCancelError(error) ||
            error is TranslationCancelledException) {
          throw const TranslationCancelledException();
        }
        // An atomic context-overflow request must degrade before the generic
        // deterministic HTTP 400 check can abort the run.
        if (TranslationApiClient.isContextOverflowError(error)) {
          lastError = error;
          break;
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
        // the block would just bill the same request again), and a 413 or a
        // context-overflow 400 on a single block means even one block is too
        // large to ever succeed: break out and let the normal failure path
        // degrade/throw instead of wasting retries.
        final bool payloadTooLarge =
            error is DioException &&
            (error.response?.statusCode == 413 ||
                TranslationApiClient.isContextOverflowError(error));
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
    if (lastError is DioException &&
        (lastError.response?.statusCode == 413 ||
            TranslationApiClient.isContextOverflowError(lastError))) {
      owner._markDegradedBlock(
        chapterPath: chapterPath ?? '',
        blockId: block.id,
        apiCounted: true,
        reason:
            'HTTP ${lastError.response?.statusCode}: block exceeds server request limit; source retained',
      );
      AppLogger.warn(
        'Block ${block.id} exceeds the server request limit (HTTP ${lastError.response?.statusCode}); source retained.',
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

  static bool _shouldDegradeSingle(Object error, TranslationConfig config) {
    if (error is TranslationCancelledException ||
        EpubChapterTranslator._isCancelError(error)) {
      throw const TranslationCancelledException();
    }
    // A context-overflow 400 on an already-atomic request cannot shrink
    // further: degrade to the source text like a 413 instead of failing fast.
    if (TranslationApiClient.isContextOverflowError(error)) {
      return true;
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

  /// Short cause for the degraded-block run report. A context-overflow 400
  /// degrades like a 413 (see _shouldDegradeSingle), so it gets its own
  /// `HTTP 400: ...` reason instead of a blank — aligned with the main
  /// block path, which reports its HTTP status the same way.
  static String? _oversizedReason(Object error) {
    if (error is! DioException) return null;
    if (error.response?.statusCode == 413) {
      return 'HTTP 413: block exceeds server request limit; source retained';
    }
    if (TranslationApiClient.isContextOverflowError(error)) {
      return 'HTTP 400: block exceeds model context limit; source retained';
    }
    return null;
  }

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
    if (!config.semanticQualityCheck) {
      return _translateFootnoteBatchRaw(
        dio: dio,
        config: config,
        batch: batch,
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        onRequestAttempt: onRequestAttempt,
        onValidated: onValidated,
      );
    }
    final translations = <String, String>{};
    final pending = <FootnoteBlockReference>[];
    for (final reference in batch.references) {
      final draft = await owner._semanticReviewer.readDraft(
        config,
        reference.chapter.path,
        reference.block,
        batch.context,
      );
      owner._run.throwIfCancelled();
      if (draft == null) {
        pending.add(reference);
      } else {
        translations[reference.requestId] = draft;
      }
    }
    if (pending.isNotEmpty) {
      translations.addAll(
        await _translateFootnoteBatchRaw(
          dio: dio,
          config: config,
          batch: FootnoteTranslationBatch(pending, context: batch.context),
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
          onRequestAttempt: onRequestAttempt,
        ),
      );
    }
    await owner._semanticReviewer.reviewFootnotes(
      dio: dio,
      config: config,
      batch: batch,
      translations: translations,
      cancelToken: cancelToken,
    );
    for (final reference in batch.references) {
      if (!owner._isDegradedBlock(
            chapterPath: reference.chapter.path,
            blockId: reference.block.id,
          ) &&
          !owner._run.isUnreviewed(
            reference.chapter.path,
            reference.block.id,
          )) {
        await onValidated?.call(
          reference.requestId,
          translations[reference.requestId]!,
        );
      }
    }
    return translations;
  }

  Future<Map<String, String>> _translateFootnoteBatchRaw({
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
        if (EpubChapterTranslator._isCancelError(error)) {
          throw const TranslationCancelledException();
        }
        // Shrink fallback first: a context-overflow 400 (or 413 /
        // send-receive timeout) is payload-size dependent, so per-reference
        // requests can still succeed. Only errors that no smaller request
        // could fix stay fatal. Matches the main block path (:344) and the
        // protected-slot path (:1248).
        //
        // A lone oversized payload takes the direct fast path: one reference
        // cannot shrink further, so re-sending it would only burn a doomed
        // request.
        final bool loneOversizedPayload =
            htmlReferences.length == 1 &&
            (error.response?.statusCode == 413 ||
                TranslationApiClient.isContextOverflowError(error));
        if (!loneOversizedPayload &&
            TranslationApiClient.shouldFallbackBatchDioException(error)) {
          // Send and receive timeouts degrade alike: a receive timeout on a
          // large batch can be payload related, and a send timeout means
          // the payload never left — retrying each reference on its own
          // (one that still fails degrades to its source HTML) matches
          // the main block path, which degrades on any request timeout.
          // A context-overflow 400 or 413 is likewise payload-size
          // dependent: smaller per-reference requests can still succeed.
          // Retry each reference independently; one that still fails
          // degrades to its source HTML and is reported with the run.
          translatedById.addAll(
            await _mapTranslations(
              htmlReferences,
              config: config,
              cancelToken: cancelToken,
              process: (FootnoteBlockReference reference) async {
                try {
                  return await _translateFootnoteHtmlBatch(
                    dio: dio,
                    config: config,
                    references: <FootnoteBlockReference>[reference],
                    context: batch.context,
                    retryDelayOverride: retryDelayOverride,
                    cancelToken: cancelToken,
                    onRequestAttempt: onRequestAttempt,
                    onValidated: onValidated,
                  );
                } catch (singleError) {
                  if (!_shouldDegradeSingle(singleError, config)) {
                    rethrow;
                  }
                  owner._markDegradedBlock(
                    chapterPath: reference.chapter.path,
                    blockId: reference.block.id,
                    apiCounted: true,
                    reason: _oversizedReason(singleError),
                  );
                  AppLogger.warn(
                    'Footnote ${reference.requestId} retained its source after ${singleError.runtimeType}.',
                    tag: 'translate',
                  );
                  return {reference.requestId: reference.block.sourceHtml};
                }
              },
            ),
          );
        } else {
          // 401/403/404 and non-overflow 400s are deterministic
          // configuration errors: fail fast with the precise localized
          // diagnostic instead of burning per-reference fallback requests
          // that would all fail the same way.
          if (!loneOversizedPayload &&
              TranslationApiClient.isDeterministicHttpError(error)) {
            throw StateError(
              TranslationApiClient.deterministicHttpErrorMessage(error, config),
            );
          }
          if (TranslationApiClient.isConnectionTimeout(error) ||
              loneOversizedPayload) {
            // A connection timeout is endpoint-wide rather than
            // payload-size related. The batch already retried once, so
            // retain its source blocks instead of multiplying the outage
            // into per-block calls.
            for (final FootnoteBlockReference reference in htmlReferences) {
              owner._markDegradedBlock(
                chapterPath: reference.chapter.path,
                blockId: reference.block.id,
                apiCounted: true,
                reason: _oversizedReason(error),
              );
              translatedById[reference.requestId] = reference.block.sourceHtml;
              AppLogger.warn(
                'Footnote ${reference.requestId} retained its source (HTTP ${error.response?.statusCode}, ${error.type}).',
                tag: 'translate',
              );
            }
          } else {
            rethrow;
          }
        }
      } on FormatException {
        // A malformed model reply is usually deterministic for the same
        // prompt, so the whole batch is not re-sent. Retry each reference
        // on its own; one that still comes back malformed degrades to its
        // source HTML and is reported with the run instead of aborting the
        // whole book.
        if (htmlReferences.length > 1) {
          // Deterministic schema errors immediately lower payload complexity.
          // Binary splitting preserves the existing verified split contract,
          // with no identical whole-batch retry.
          final middle = htmlReferences.length ~/ 2;
          translatedById.addAll(
            await _mapTranslations(
              [
                htmlReferences.sublist(0, middle),
                htmlReferences.sublist(middle),
              ],
              config: config,
              cancelToken: cancelToken,
              process: (List<FootnoteBlockReference> part) =>
                  _translateFootnoteBatch(
                    dio: dio,
                    config: config,
                    batch: FootnoteTranslationBatch(
                      part,
                      context: batch.context,
                    ),
                    retryDelayOverride: retryDelayOverride,
                    cancelToken: cancelToken,
                    onRequestAttempt: onRequestAttempt,
                    onValidated: onValidated,
                  ),
            ),
          );
        } else {
          // Single reference: retryable format failures exhausted runRetried;
          // deterministic TranslationParseException failures skipped retries.
          // Neither path benefits from another identical request cycle, so
          // degrade directly to the source HTML.
          final FootnoteBlockReference reference = htmlReferences.single;
          owner._markDegradedBlock(
            chapterPath: reference.chapter.path,
            blockId: reference.block.id,
            apiCounted: true,
            reason: null,
          );
          translatedById[reference.requestId] = reference.block.sourceHtml;
          AppLogger.warn(
            'Footnote ${reference.requestId} retained its source after FormatException.',
            tag: 'translate',
          );
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
          apiCounted: true,
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
  }) async {
    final List<FootnoteBlockReference> failed = [];
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

    final translated = await owner._apiClient.runRetried<Map<String, String>>(
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
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include a compact read-only bookMemory summary. Use that context only for terminology and style. Translate only items in "blocks". Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, link target, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain exactly one original request "id" and the translated HTML in "html". Return every requested id exactly once.${_styleInstructionFragment(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_idiomaticTranslationInstruction()}',
            },
            <String, String>{'role': 'user', 'content': payload},
          ],
        };
        onRequestAttempt?.call();
        _TranslationRequestBudget.apply(requestData);
        final Response<dynamic> response = await owner._postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );
        final Map<String, dynamic> jsonPayload = _validateBatchReply(
          response.data,
          requestedIds,
        );
        final List<dynamic> rawBlocks = jsonPayload['blocks'] as List<dynamic>;

        final Map<String, String> rawTranslatedById = <String, String>{};
        for (final Map<String, dynamic> item
            in rawBlocks.cast<Map<String, dynamic>>()) {
          final String rawId = item['id'] as String;
          final Object? rawHtml = item['html'];
          if (rawId.isEmpty) {
            throw const FormatException(
              'Translated footnote batch item is missing id.',
            );
          }
          // An empty or missing html is a per-reference failure: leave it
          // unrecorded so the per-reference loop below retries only this
          // footnote instead of re-billing the whole batch.
          if (rawHtml is String && rawHtml.trim().isNotEmpty) {
            rawTranslatedById[rawId] = rawHtml.trim();
          }
        }

        final Map<String, String> translatedById = <String, String>{};
        for (final FootnoteBlockReference reference in references) {
          try {
            final String? translated = rawTranslatedById[reference.requestId];
            if (translated == null) {
              throw FormatException(
                'Translated footnote ${reference.requestId} is missing from the batch response.',
              );
            }
            final String locked =
                EpubChapterTranslator._lockAndValidateTranslatedBlock(
                  config: config,
                  block: reference.block,
                  translatedHtml: translated,
                );
            translatedById[reference.requestId] = locked;
          } on FormatException {
            if (references.length == 1) rethrow;
            failed.add(reference);
            continue;
          }
          await onValidated?.call(
            reference.requestId,
            translatedById[reference.requestId]!,
          );
        }
        return translatedById;
      },
    );
    translated.addAll(
      await _mapTranslations(
        failed,
        config: config,
        cancelToken: cancelToken,
        process: (FootnoteBlockReference reference) async {
          try {
            return await _translateFootnoteHtmlBatch(
              dio: dio,
              config: config,
              references: [reference],
              context: context,
              retryDelayOverride: retryDelayOverride,
              cancelToken: cancelToken,
              onRequestAttempt: onRequestAttempt,
              onValidated: onValidated,
            );
          } catch (error) {
            if (!_shouldDegradeSingle(error, config)) rethrow;
            owner._markDegradedBlock(
              chapterPath: reference.chapter.path,
              blockId: reference.block.id,
              apiCounted: true,
              reason: _oversizedReason(error),
            );
            return {reference.requestId: reference.block.sourceHtml};
          }
        },
      ),
    );
    return translated;
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
    // The slot pipeline is shared: both the main block pipeline and the
    // footnote pipeline count every block up front (pass true so degrades
    // are subtracted from the report). Callers forward their own pipeline's
    // value (see [_markDegradedBlock]).
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
        apiCounted: apiCounted,
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
      if (error is _DeterministicBatchStructureException) {
        final midpoint = requests.length ~/ 2;
        return _mapTranslations(
          [requests.sublist(0, midpoint), requests.sublist(midpoint)],
          config: config,
          cancelToken: cancelToken,
          process: (List<_ProtectedSlotRequest> half) =>
              _translateProtectedSlotBatch(
                dio: dio,
                config: config,
                requests: half,
                context: context,
                retryDelayOverride: retryDelayOverride,
                cancelToken: cancelToken,
                onRequestAttempt: onRequestAttempt,
                maxBatchAttempts: 1,
                apiCounted: apiCounted,
                onValidated: onValidated,
              ),
        );
      }
      if (error is TranslationParseException) {
        // Deterministic failure: the model did not return JSON for this
        // prompt shape, so bisecting would just re-bill the same broken
        // prompt at every level of the split. Translate each block's slots
        // directly instead (the single-request path below still degrades
        // quality rejections per block).
        return _mapTranslations(
          requests,
          config: config,
          cancelToken: cancelToken,
          process: (_ProtectedSlotRequest request) =>
              _translateProtectedSlotBatch(
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
      // Validation failure on a well-formed reply: bisect, but each level
      // gets a single attempt. A deterministic validation failure must not
      // eat maxRetries at every level of the split.
      final int midpoint = requests.length ~/ 2;
      return _mapTranslations(
        [requests.sublist(0, midpoint), requests.sublist(midpoint)],
        config: config,
        cancelToken: cancelToken,
        process: (List<_ProtectedSlotRequest> half) =>
            _translateProtectedSlotBatch(
              dio: dio,
              config: config,
              requests: half,
              context: context,
              retryDelayOverride: retryDelayOverride,
              cancelToken: cancelToken,
              onRequestAttempt: onRequestAttempt,
              maxBatchAttempts: 1,
              apiCounted: apiCounted,
              onValidated: onValidated,
            ),
      );
    } on DioException catch (error) {
      if (EpubChapterTranslator._isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      // Atomic size failures (413, send/receive timeout, context-overflow
      // 400) degrade a single request to its source instead of aborting.
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
      // Shrink fallback: a size-dependent failure (413, timeout,
      // context-overflow 400) bisects into smaller payloads, which usually
      // pass. Only errors that no smaller request could fix stay fatal.
      if (TranslationApiClient.shouldFallbackBatchDioException(error) &&
          requests.length > 1) {
        // Falls through to the bisect below.
      } else {
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
        rethrow;
      }
    }

    // Transport-level fallback (e.g. 413 payload too large): split the batch
    // with the normal per-level retry policy; smaller payloads usually pass.
    final int midpoint = requests.length ~/ 2;
    return _mapTranslations(
      [requests.sublist(0, midpoint), requests.sublist(midpoint)],
      config: config,
      cancelToken: cancelToken,
      process: (List<_ProtectedSlotRequest> half) =>
          _translateProtectedSlotBatch(
            dio: dio,
            config: config,
            requests: half,
            context: context,
            retryDelayOverride: retryDelayOverride,
            cancelToken: cancelToken,
            onRequestAttempt: onRequestAttempt,
            apiCounted: apiCounted,
            onValidated: onValidated,
          ),
    );
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
    bool apiCounted = false,
    Future<void> Function(String id, String html)? onValidated,
  }) async {
    final List<_ProtectedSlotRequest> failed = [];
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

    final result = await owner._apiClient.runRetried<Map<String, String>>(
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
                  'Translate only each slot "text" into ${config.targetLanguage}. Return strict JSON only, with exactly the requested block ids and slot ids. Every block must contain only "id" and "slots"; every slot must contain only string "id" and string "text"; never return HTML, tags, attributes, markdown, or explanations. Treat angle brackets in translated text as ordinary text.${_styleInstructionFragment(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_idiomaticTranslationInstruction()}',
            },
            <String, String>{'role': 'user', 'content': payload},
          ],
        };
        onRequestAttempt?.call();
        _TranslationRequestBudget.apply(requestData);
        final Response<dynamic> response = await owner._postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );
        final Map<String, dynamic> jsonPayload = _validateBatchReply(
          response.data,
          requestedIds,
          slotIds: {
            for (final request in requests) request.id: request.slotIds.toSet(),
          },
        );
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
          // 性能-#36: resolve slot ids to indexes through a map instead of
          // a per-slot indexOf scan (O(n^2) over the slots).
          final Map<String, int> slotIndexById = <String, int>{
            for (int index = 0; index < request.slotIds.length; index++)
              request.slotIds[index]: index,
          };
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
            _validateIndividualSlotTranslation(
              sourceText: request.template.slotTexts[slotIndexById[rawSlotId]!],
              translatedText: rawText,
              // Batch slots may carry HTML that the renderer escapes;
              // only the non-HTML wrapper checks apply here.
              checkHtmlTags: false,
            );
            textBySlotId[rawSlotId] = rawText;
          }
          translatedSlotsById[rawId] = request.slotIds
              .map((String slotId) => textBySlotId[slotId]!)
              .toList(growable: false);
        }

        final Map<String, String> translated = <String, String>{};
        for (final _ProtectedSlotRequest request in requests) {
          try {
            final String html = _renderAndValidateProtectedSlots(
              config: config,
              request: request,
              translatedSlots: translatedSlotsById[request.id]!,
            );
            translated[request.id] = html;
          } on FormatException {
            if (requests.length == 1) rethrow;
            failed.add(request);
            continue;
          }
          await onValidated?.call(request.id, translated[request.id]!);
        }
        return translated;
      },
    );
    result.addAll(
      await _mapTranslations(
        failed,
        config: config,
        cancelToken: cancelToken,
        process: (_ProtectedSlotRequest request) =>
            _translateProtectedSlotBatch(
              dio: dio,
              config: config,
              requests: [request],
              context: context,
              retryDelayOverride: retryDelayOverride,
              cancelToken: cancelToken,
              onRequestAttempt: onRequestAttempt,
              maxBatchAttempts: 1,
              apiCounted: apiCounted,
              onValidated: onValidated,
            ),
      ),
    );
    return result;
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
        // Transport retries belong exclusively to the per-slot retry layer.
        final bool retryable = error is _ProtectedSlotRenderException;
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
    // 性能-#37: normalize the block's source text once; every per-slot
    // request below would otherwise renormalize the whole block (O(K×M)).
    final String normalizedBlockText = request.block.sourceText
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    // 性能-#50: normalize each slot text once per block. Per-slot context
    // location reuses these instead of each slot renormalizing all
    // previous slots (K(K-1)/2 total).
    final List<String> normalizedSlotTexts = request.template.slotTexts
        .map((String s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
        .toList(growable: false);
    // Cache spans in order before concurrent requests/retries start. A missing
    // span keeps later slots on the historical leading-window fallback.
    int fromIndex = 0;
    final List<int> slotStarts = <int>[];
    for (final String needle in normalizedSlotTexts) {
      if (needle.isEmpty || fromIndex < 0) {
        slotStarts.add(-1);
        continue;
      }
      final int found = normalizedBlockText.indexOf(needle, fromIndex);
      slotStarts.add(found);
      fromIndex = found < 0 ? -1 : found + needle.length;
    }
    final List<String>
    translatedSlots = await const TranslationWorkQueue().map<String, String>(
      request.template.slotTexts,
      concurrency: config.maxConcurrent,
      throwIfCancelled: () {
        owner._run.throwIfCancelled();
        if (cancelToken?.isCancelled == true) {
          throw const TranslationCancelledException();
        }
      },
      process: (String sourceText, int index) {
        // Retry at the slot level: a transient failure on slot k must not
        // re-bill the slots that already translated cleanly. A render/quality
        // failure of the rebuilt block still retries the whole round via the
        // loop in [_translateProtectedSlotsIndividually].
        return owner._apiClient.runRetried<String>(
          config: config,
          retryDelayOverride: retryDelayOverride,
          shouldRetry: _shouldRetryIndividualSlotError,
          cancelToken: cancelToken,
          operation: () => _translateProtectedSlotTextOnce(
            dio: dio,
            config: config,
            sourceText: sourceText,
            request: request,
            slotIndex: index,
            normalizedBlockText: normalizedBlockText,
            normalizedSlotTexts: normalizedSlotTexts,
            locatedSlotStart: slotStarts[index],
            context: context,
            cancelToken: cancelToken,
            onRequestAttempt: onRequestAttempt,
            retryReason: retryReason,
          ),
        );
      },
    );
    try {
      return <String, String>{
        request.id: _renderAndValidateProtectedSlots(
          config: config,
          request: request,
          translatedSlots: translatedSlots,
        ),
      };
    } on FormatException catch (error) {
      throw _ProtectedSlotRenderException(error.message);
    }
  }

  /// Bounded plain-text window of a block for per-slot requests: enough for
  /// continuity, pronouns and terminology without re-sending the whole HTML
  /// once per slot.
  ///
  /// The window is centered on the slot's own position in the block (text
  /// before and after it) instead of always taking the first 600
  /// characters, so long-distance context is not systematically dropped
  /// for slots near the end of a long block. When the slot text cannot be
  /// located in the block, it falls back to the leading window.
  static const int _slotContextLimit = 600;

  static bool _shouldRetryIndividualSlotError(Object error) {
    return error is! TranslationCancelledException &&
        !EpubChapterTranslator._isCancelError(error) &&
        error is! TranslationParseException &&
        !TranslationApiClient.isDeterministicHttpError(error) &&
        !(error is DioException && error.response?.statusCode == 413);
  }

  static String _boundedSlotNeighbor(String text) =>
      text.length <= _slotContextLimit
      ? text
      : text.substring(0, _slotContextLimit);

  static String _blockContextSummary(
    ExtractedBlock block, {
    String? slotText,
    int? slotIndex,
    List<String>? slotTexts,
    List<String>? normalizedSlotTexts,
    String? normalizedBlockText,
    int? locatedSlotStart,
  }) {
    const int limit = _slotContextLimit;
    // 性能-#37: the normalized block text is identical for every slot of
    // the block; callers pass the cached copy so K slots do not each pay
    // O(block length) for the normalization.
    final String text =
        normalizedBlockText ??
        block.sourceText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.length <= limit) return text;
    int center = text.length ~/ 2;
    bool located = false;
    if (slotText != null && slotText.trim().isNotEmpty) {
      final String needle = slotText.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (needle.isNotEmpty) {
        // P2-#13: locate the slot's own span by walking slot boundaries in
        // order. Counting raw substring occurrences in the whole block text
        // (P2-#21's old approach) confused a needle that also appears
        // inside another slot's text ("world" inside "Hello world") with
        // the slot's own occurrence and centered the window wrongly.
        final int found =
            locatedSlotStart ??
            _indexOfSlotSpan(
              text,
              needle: needle,
              slotIndex: slotIndex,
              slotTexts: slotTexts,
              normalizedSlotTexts: normalizedSlotTexts,
            );
        if (found >= 0) {
          center = found + needle.length ~/ 2;
          located = true;
        }
      }
    }
    int start;
    if (!located) {
      // Slot position unknown: keep the historical leading window.
      start = 0;
    } else {
      start = center - limit ~/ 2;
      if (start < 0) start = 0;
    }
    int end = start + limit;
    if (end > text.length) {
      end = text.length;
      start = end - limit;
    }
    return text.substring(start, end);
  }

  /// Index in [text] where the [slotIndex]-th slot's own normalized text
  /// starts, or -1 when it cannot be located. Slots are scanned in order,
  /// each search starting after the previous slot's span, so the search
  /// stays within slot boundaries: a needle that also occurs inside
  /// another slot's text never counts as the slot's own occurrence
  /// (P2-#13). Duplicate slot texts resolve to their own occurrence, not
  /// the first one (P2-#21). Without slot identity, falls back to the
  /// first substring occurrence.
  ///
  /// 性能-#50: [normalizedSlotTexts] is computed once per block by the
  /// caller; when absent each slot is normalized on the fly (kept for the
  /// test hook and other callers).
  static int _indexOfSlotSpan(
    String text, {
    required String needle,
    required int? slotIndex,
    required List<String>? slotTexts,
    required List<String>? normalizedSlotTexts,
  }) {
    if (slotIndex == null || slotIndex < 0) {
      return text.indexOf(needle);
    }
    final List<String>? normalized =
        normalizedSlotTexts ??
        slotTexts
            ?.map((String s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
            .toList(growable: false);
    if (normalized == null || slotIndex >= normalized.length) {
      return text.indexOf(needle);
    }
    int fromIndex = 0;
    for (int i = 0; i <= slotIndex; i++) {
      final String slotNeedle = normalized[i];
      if (slotNeedle.isEmpty) {
        continue;
      }
      final int found = text.indexOf(slotNeedle, fromIndex);
      if (found < 0) {
        return -1;
      }
      if (i == slotIndex) {
        return found;
      }
      fromIndex = found + slotNeedle.length;
    }
    return -1;
  }

  Future<String> _translateProtectedSlotTextOnce({
    required Dio dio,
    required TranslationConfig config,
    required String sourceText,
    required _ProtectedSlotRequest request,
    required int slotIndex,
    required TranslationBatchContext context,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
    String? retryReason,
    String? normalizedBlockText,
    List<String>? normalizedSlotTexts,
    int? locatedSlotStart,
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
    final Map<String, Object?> slotContext = <String, Object?>{
      // Never the full source HTML: every slot request would re-send the
      // whole block, multiplying input tokens by the slot count and risking
      // the input window on small slots. A bounded plain-text summary is
      // enough for continuity, pronouns and terminology.
      'blockSummary': _blockContextSummary(
        request.block,
        slotText: request.template.slotTexts[slotIndex],
        // P2-#21: the slot id (s0, s1, ...) encodes the index; duplicate
        // slot texts resolve to their own occurrence, not the first one.
        slotIndex: slotIndex,
        slotTexts: request.template.slotTexts,
        // 性能-#37: cached normalized block text (see
        // [_translateProtectedSlotsIndividuallyOnce]).
        normalizedBlockText: normalizedBlockText,
        // 性能-#50: cached normalized slot texts (same).
        normalizedSlotTexts: normalizedSlotTexts,
        locatedSlotStart: locatedSlotStart,
      ),
      'currentSlotId': request.slotIds[slotIndex],
      'previousText': slotIndex > 0
          ? _boundedSlotNeighbor(request.template.slotTexts[slotIndex - 1])
          : null,
      'nextText': slotIndex + 1 < request.template.slotTexts.length
          ? _boundedSlotNeighbor(request.template.slotTexts[slotIndex + 1])
          : null,
    };
    final Map<String, dynamic> requestData = <String, dynamic>{
      'model': config.model,
      'temperature': 0.2,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'Translate the user text into ${config.targetLanguage}. Return only the translated text, with no JSON, HTML, Markdown formatting, labels, or explanation.${_styleInstructionFragment(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${owner._apiClient.lockedGlossaryInstruction(config)}${_idiomaticTranslationInstruction()}',
        },
        if (!context.isEmpty)
          EpubChapterTranslator._fallbackContextMessage(context),
        <String, String>{
          'role': 'system',
          'content':
              'Read-only plain-text summary of the source block. Use only '
              'for continuity, pronouns, terminology and sentence flow; '
              'translate only the current slot supplied in the user message, '
              'never this context.\n'
              '${jsonEncode(slotContext)}',
        },
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
  // P2-#8: also matches an unterminated comment (`<!-- note` with no
  // `-->`): the old pattern only caught closed comments, so an unclosed
  // one slipped through the wrapper checks.
  static final RegExp _slotHtmlCommentPattern = RegExp(r'<!--[\s\S]*?(-->|$)');

  static void _validateIndividualSlotTranslation({
    required String sourceText,
    required String translatedText,
    // Batch protected slots may legitimately contain HTML (e.g. a model
    // returning "<script>"): the downstream renderer escapes it (see
    // epub_repository_performance_test's "&lt;script&gt;" assertions).
    // Rejecting HTML tags here would false-positive on that established
    // defense, so the batch path skips tag and HTML comment checks.
    bool checkHtmlTags = true,
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
        _hasMarkdownWrapper(trimmed, sourceText: sourceText) ||
        (checkHtmlTags && _slotHtmlCommentPattern.hasMatch(trimmed)) ||
        // See [_slotWrapperTagPattern]: `<` must abut a letter/`/`/`!`/`?`
        // or a comparison like "a < b" is misread as markup.
        (checkHtmlTags && _slotWrapperTagPattern.hasMatch(trimmed)) ||
        _hasTranslationExplanationPrefix(trimmed)) {
      throw const TranslationParseException(
        'Individual protected slot translation contains wrapper content.',
      );
    }
  }

  static bool _hasMarkdownWrapper(String value, {String sourceText = ''}) {
    if (RegExp(r'^`{1,2}[\s\S]+`{1,2}$').hasMatch(value) ||
        RegExp(r'^~~[\s\S]+~~$').hasMatch(value) ||
        RegExp(r'^\*\*[\s\S]+\*\*$').hasMatch(value) ||
        RegExp(r'^__[\s\S]+__$').hasMatch(value) ||
        RegExp(r'^\*[\s\S]+\*$').hasMatch(value) ||
        RegExp(r'^_[\s\S]+_$').hasMatch(value) ||
        RegExp(r'!?\[[^\]\r\n]+\]\([^\)\r\n]+\)').hasMatch(value)) {
      return true;
    }
    final numbered = RegExp(r'^\s*(\d+[.)])\s+');
    final sourceMarkers = sourceText
        .trim()
        .split(RegExp(r'\r?\n'))
        .map((line) => numbered.firstMatch(line)?.group(1))
        .toList();
    final lines = value.split(RegExp(r'\r?\n'));
    for (int index = 0; index < lines.length; index++) {
      final line = lines[index];
      final marker = numbered.firstMatch(line)?.group(1);
      if ((marker != null &&
              (index >= sourceMarkers.length ||
                  sourceMarkers[index] != marker)) ||
          RegExp(r'^\s*(?:#{1,6}|>|[-+*])\s+').hasMatch(line) ||
          RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line) ||
          RegExp(r'^\s*\|.*\|\s*$').hasMatch(line)) {
        return true;
      }
    }
    return false;
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
        // P2-#13: the confirmed false positive was a curly-quoted source whose
        // translation normalized the quotes to ASCII; quote-wrapped sources in
        // any recognized style must not be misjudged as JSON wrappers.
        if (source.length >= 2 && _isQuoteWrapped(source)) return false;
        return true;
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

  static bool _isQuoteWrapped(String s) =>
      (s.startsWith('"') && s.endsWith('"')) ||
      (s.startsWith('\u201C') && s.endsWith('\u201D')) ||
      (s.startsWith("'") && s.endsWith("'")) ||
      (s.startsWith('\u2018') && s.endsWith('\u2019'));

  static String _renderAndValidateProtectedSlots({
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required List<String> translatedSlots,
  }) {
    // renderElement keeps the rebuilt block in DOM form: wrapping it with
    // fromRoot avoids parsing the rendered string a second time.
    final dom.Element renderedRoot = request.template.renderElement(
      translatedSlots,
    );
    EpubChapterTranslator._validateTranslatedBlockQuality(
      config: config,
      block: request.block,
      sourceDom: _ResponseHtml.parse(request.block.sourceHtml, null),
      translatedDom: _ResponseHtml.fromRoot(renderedRoot, null),
    );
    return renderedRoot.outerHtml;
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

  /// Combined style-related system-prompt fragment: style profile,
  /// terminology gloss, and second-person rule.
  ///
  /// Normalizes the target language once and reuses the result (C-30):
  /// previously the terminology and second-person builders below each
  /// normalized [config.targetLanguage] independently on every batch,
  /// repeating identical regex work for an identical input.
  String _styleInstructionFragment({
    required TranslationConfig config,
    TranslationStyleProfile? styleProfile,
    bool confirmed = false,
  }) {
    final String normalizedTargetLanguage =
        EpubChapterTranslator.normalizeTargetLanguage(config.targetLanguage);
    return '${_styleProfileInstruction(config: config, styleProfile: styleProfile, confirmed: confirmed)}'
        '${_terminologyGlossInstruction(config: config, normalizedTargetLanguage: normalizedTargetLanguage)}'
        '${_chineseSecondPersonInstruction(config: config, normalizedTargetLanguage: normalizedTargetLanguage)}';
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
  String _terminologyGlossInstruction({
    required TranslationConfig config,
    String? normalizedTargetLanguage,
  }) {
    // CJK membership is tested against the already-normalized language when
    // the caller provides it (see [_styleInstructionFragment], C-30);
    // standalone callers fall back to normalizing here. The set mirrors
    // EpubChapterTranslator._isCjkTargetLanguage.
    final String normalized =
        normalizedTargetLanguage ??
        EpubChapterTranslator.normalizeTargetLanguage(config.targetLanguage);
    if (normalized != 'zh' && normalized != 'ja' && normalized != 'ko') {
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
  /// Second-person formality is a pragmatic judgment, not a fixed rule:
  /// 按关系选 您/你 — the model chooses between 您 (formal) and 你
  /// (informal) from the speaker/addressee relationship visible in
  /// context, rather than defaulting to 您 throughout. Prompt-level only:
  /// a model can still deviate, but in practice the explicit instruction
  /// holds. (质量-#56: the old comment wrongly said published translations
  /// conventionally use 您 throughout, contradicting this rule.)
  String _chineseSecondPersonInstruction({
    required TranslationConfig config,
    String? normalizedTargetLanguage,
  }) {
    // Reuses the caller's normalized value when provided (C-30); standalone
    // callers fall back to normalizing here.
    final String normalized =
        normalizedTargetLanguage ??
        EpubChapterTranslator.normalizeTargetLanguage(config.targetLanguage);
    if (normalized != 'zh') {
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
  _ProtectedSlotRequest({
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

  late final List<String> slotIds = List<String>.generate(
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
