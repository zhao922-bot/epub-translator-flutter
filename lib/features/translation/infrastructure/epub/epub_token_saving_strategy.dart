part of 'epub_chapter_translator.dart';

/// Adapts body request sizes within one invocation. Estimates include the
/// actual serialized messages and reserve generated tokens for the payload.
class _AdaptiveBodyBudget {
  _AdaptiveBodyBudget(this.config)
    : _contextLimit = config.capabilities.contextWindowTokens,
      _outputLimit = config.maxOutputTokens.clamp(512, 32768),
      _preferredBodyTokens = max(1, (config.chunkSize * 0.3).ceil()) {
    _target = _preferredBodyTokens;
  }

  final TranslationConfig config;
  late final _capabilities = config.capabilities;
  final int? _contextLimit;
  final int _outputLimit;
  final int _preferredBodyTokens;
  late int _target;
  int _streak = 0;
  double _inputRatio = 1;
  double _outputRatio = 1.35;
  int _observedReasoningReserve = 0;
  int get targetBodyTokens => _target;

  static int estimate(String value) =>
      _TranslationRequestBudget.estimateTokens(value);

  int get plannedChunkSize => max(
    1,
    min(TranslationBatchPlanner.maxChunkSize, (_target / 0.3).floor()),
  );

  _BodyRequestSize measure(
    Map<String, dynamic> data,
    Object outputShape, {
    int? reserveOutput,
  }) {
    final int prompt = estimate(jsonEncode(data['messages']));
    final int body = max(1, estimate(jsonEncode(outputShape)));
    final int predictedInput = (prompt * _inputRatio).ceil();
    final bool preferLowReasoning =
        data['_folioFerryPreferLowReasoning'] == true;
    final bool needsHeadroom = _capabilities.bodyNeedsReasoningHeadroom(
      preferLowReasoning: preferLowReasoning,
    );
    final int reasoningReserve =
        preferLowReasoning && _capabilities.bodyUsesLowerReasoning
        ? 0
        : max(
            _observedReasoningReserve,
            needsHeadroom ? min(1024, _outputLimit ~/ 2) : 0,
          );
    final int reserve = max(
      reserveOutput ?? 0,
      max(64, (body * _outputRatio).ceil() + 32) + reasoningReserve,
    );
    final contextLimit = _contextLimit;
    final int available = contextLimit == null
        ? _outputLimit
        : min(_outputLimit, contextLimit - predictedInput);
    return _BodyRequestSize(
      promptEstimate: prompt,
      bodyEstimate: body,
      reservedOutput: reserve,
      maximumOutput: available,
    );
  }

  void reduce(_BodyRequestSize size) {
    final floor = min(48, _preferredBodyTokens);
    _target = max(floor, min(_target * 2 ~/ 3, size.bodyEstimate * 2 ~/ 3));
    _streak = 0;
  }

  void observe(
    _BodyRequestSize size,
    Object? response, {
    required bool truncated,
    bool complete = true,
  }) {
    final bool reasoningOnly = truncated && isReasoningOnly(response);
    if (reasoningOnly) {
      _observedReasoningReserve = min(
        _outputLimit ~/ 2,
        max(_observedReasoningReserve, max(2048, size.wireOutput * 2)),
      );
    }
    if (response is Map && response['usage'] is Map) {
      final usage = response['usage'] as Map;
      final Object? prompt = usage['prompt_tokens'];
      if (prompt is int && prompt > 0 && size.promptEstimate > 0) {
        final double ratio = (prompt / size.promptEstimate).clamp(1.0, 4.0);
        _inputRatio = max(ratio, _inputRatio * 0.95);
      }
      final Object? completion = usage['completion_tokens'];
      final reasoning = _reportedReasoningTokens(usage);
      if (completion is int && completion > reasoning && !reasoningOnly) {
        final double ratio = ((completion - reasoning + 16) / size.bodyEstimate)
            .clamp(1.2, 12.0);
        _outputRatio = max(ratio, _outputRatio * 0.98);
      }
    }
    if (truncated) {
      reduce(size);
      return;
    }
    if (!complete) {
      _streak = 0;
      return;
    }
    if (++_streak >= 4) {
      final int ceiling = _preferredBodyTokens * 2;
      _target = min(ceiling, _target + max(1, _target ~/ 8));
      _streak = 0;
    }
  }

  static int _reportedReasoningTokens(Object? usage) {
    final details = usage is Map ? usage['completion_tokens_details'] : null;
    final tokens = details is Map ? details['reasoning_tokens'] : null;
    return tokens is int ? max(0, tokens) : 0;
  }

  static bool isReasoningOnly(Object? response) {
    final choices = response is Map ? response['choices'] : null;
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return false;
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) return false;
    final content = message['content'];
    final reasoning = message['reasoning_content'];
    return (content == null || (content is String && content.trim().isEmpty)) &&
        ((reasoning is String && reasoning.isNotEmpty) ||
            _reportedReasoningTokens((response as Map)['usage']) > 0);
  }
}

class _BodyRequestSize {
  const _BodyRequestSize({
    required this.promptEstimate,
    required this.bodyEstimate,
    required this.reservedOutput,
    required this.maximumOutput,
  });

  final int promptEstimate;
  final int bodyEstimate;
  final int reservedOutput;
  final int maximumOutput;

  bool get fits => maximumOutput >= reservedOutput;
  int get wireOutput => min(maximumOutput, reservedOutput);
}

class _LocalBodyLimitException extends TranslationParseException {
  const _LocalBodyLimitException()
    : super('The request exceeds the model context limit.');
}

enum _BodyRepairReason { missing, structure, residual, truncated }

/// A paragraph or heading whose XHTML stays local throughout translation.
class _PlainBodyText {
  _PlainBodyText(this._source, this._rootIndex, this._sourceText);

  static const _tags = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};
  static final _layoutDeclaration = RegExp(
    r'^\s*(?:text-align(?:-last)?|text-indent|line-height|letter-spacing|'
    r'word-spacing|widows|orphans|font-style|font-weight|'
    r'(?:margin|padding)(?:-(?:top|right|bottom|left|'
    r'(?:inline|block)(?:-start|-end)?))?)\s*:\s*'
    r'[a-z0-9.%+ ]+(?:!important)?\s*$',
    caseSensitive: false,
  );
  static final _specialIdentifiers = RegExp(
    r'notranslate|no[-_]?translate|footnote|endnote|noteref|note[-_]?ref|'
    r'backlink|page[-_]?break|bibliograph|(?:^|[\s_-])'
    r'(?:notes?|verse|poems?|poetry|code|literal|index(?:main)?|'
    r'references?|hidden|sr-only)\d*(?:$|[\s_-])',
    caseSensitive: false,
  );
  static final _letter = RegExp(r'\p{L}', unicode: true);
  static final _preservedSpacing = RegExp(r'[^\S ]| {2,}', unicode: true);

  final _ResponseHtml _source;
  final int _rootIndex;
  final String _sourceText;
  String get text => _sourceText.trim();

  static _PlainBodyText? fromBlock(ExtractedBlock block) {
    if (block.isAuthorSignature || !_tags.contains(block.tagName)) return null;
    // Inline tags, comments, and other multi-tag fragments can go directly to
    // the existing HTML/anchor path without parsing them twice.
    final html = block.sourceHtml;
    final int opening = html.indexOf('<');
    final int closing = html.indexOf('<', opening + 1);
    if (opening < 0 ||
        closing < 0 ||
        !html.startsWith('</${block.tagName}>', closing) ||
        html.indexOf('<', closing + 1) >= 0) {
      return null;
    }
    final _ResponseHtml source;
    try {
      source = _ResponseHtml.parse(block.sourceHtml, null);
    } on FormatException {
      return null;
    }
    final nodes = source.fragment.nodes;
    final int rootIndex = nodes.indexWhere((node) => node is dom.Element);
    if (rootIndex < 0) return null;
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (i != rootIndex &&
          (node is! dom.Text || node.data.trim().isNotEmpty)) {
        return null;
      }
    }
    final root = nodes[rootIndex] as dom.Element;
    if (root.localName != block.tagName ||
        !root.attributes.entries.every(_isPresentationAttribute) ||
        root.nodes.length != 1) {
      return null;
    }
    final node = root.nodes.single;
    if (node is! dom.Text) return null;
    final text = node.data.trim();
    if (!_letter.hasMatch(text) || _preservedSpacing.hasMatch(text)) {
      return null;
    }
    return _PlainBodyText(source, rootIndex, node.data);
  }

  static bool _isPresentationAttribute(MapEntry<Object, String> attribute) =>
      switch (attribute.key) {
        'id' || 'class' => !_specialIdentifiers.hasMatch(attribute.value),
        'style' =>
          attribute.value
              .split(';')
              .every(
                (declaration) =>
                    declaration.trim().isEmpty ||
                    _layoutDeclaration.hasMatch(declaration),
              ),
        _ => false,
      };

  String render({
    required TranslationConfig config,
    required ExtractedBlock block,
    required String translation,
  }) {
    validateEpubXmlCharacters(translation);
    _EpubTranslationStrategy._validateIndividualSlotTranslation(
      sourceText: text,
      translatedText: translation,
      checkHtmlTags: false,
    );
    final rendered = _source.fragment.clone(true);
    final root = rendered.nodes[_rootIndex] as dom.Element;
    final node = root.nodes.single as dom.Text;
    final int leading = _sourceText.length - _sourceText.trimLeft().length;
    final int trailing = _sourceText.trimRight().length;
    node.data =
        '${_sourceText.substring(0, leading)}${translation.trim()}'
        '${_sourceText.substring(trailing)}';
    EpubChapterTranslator._validateTranslatedBlockQuality(
      config: config,
      block: block,
      sourceDom: _source,
      translatedDom: _ResponseHtml(rendered),
    );
    return rendered.outerHtml;
  }
}

typedef _ReadReusableBody =
    Future<Map<String, String>> Function(
      List<ExtractedBlock> blocks,
      Map<String, dynamic> request,
    );

typedef _RememberReusableBody =
    Future<void> Function(
      List<ExtractedBlock> blocks,
      Map<String, dynamic> request,
      Map<String, String> translated,
    );

/// Keeps checked rows and sends at most one smaller grouped repair for
/// the remaining body blocks before using the existing atomic fallback.
class _TokenSavingBodyStrategy {
  _TokenSavingBodyStrategy(this.strategy);

  final _EpubTranslationStrategy strategy;
  EpubChapterTranslator get owner => strategy.owner;

  Future<List<String>> translate({
    required Dio dio,
    required TranslationConfig config,
    required TranslationBlockBatch batch,
    required Map<String, _PlainBodyText> plainText,
    String? chapterPath,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    int? fallbackWindow,
    Future<void> Function(String, String)? onValidated,
    _ReadReusableBody? readReusable,
    _RememberReusableBody? rememberReusable,
  }) async {
    final accepted = <String, String>{};
    final budget = owner._bodyBudget(config);
    final failures = <String, _BodyRepairReason>{};
    final originals = {for (final block in batch.blocks) block.id: block};
    if (originals.length != batch.blocks.length) {
      throw const FormatException('Requested block ids must be unique.');
    }

    Future<void> runGroup(
      List<ExtractedBlock> blocks, {
      required bool repair,
    }) async {
      owner._run.throwIfCancelled();
      final TranslationBatchContext context = strategy._bodyRequestContext(
        config,
        batch,
        blocks,
        compact: repair,
      );
      final textById = repair ? const <String, _PlainBodyText>{} : plainText;
      final outputBlocks = <Map<String, String>>[
        for (final block in blocks)
          {
            'id': block.id,
            if (textById[block.id] case final plain?)
              'text': plain.text
            else
              'html': block.sourceHtml,
          },
      ];
      final payloadBlocks = repair
          ? [
              for (final row in outputBlocks)
                {
                  ...row,
                  'reason':
                      (failures[row['id']] ?? _BodyRepairReason.missing).name,
                },
            ]
          : outputBlocks;
      final data = _request(config, context, payloadBlocks, repair: repair);
      final size = budget.measure(data, {'blocks': outputBlocks});
      if (blocks.length > 1 &&
          (!size.fits || size.bodyEstimate > budget.targetBodyTokens)) {
        final int half = blocks.length ~/ 2;
        await runGroup(blocks.sublist(0, half), repair: repair);
        await runGroup(blocks.sublist(half), repair: repair);
        return;
      }
      data['max_tokens'] = size.wireOutput;
      if (!repair && readReusable != null) {
        final reused = await readReusable(blocks, data);
        if (blocks.every((block) => reused.containsKey(block.id))) {
          for (final block in blocks) {
            final String html = reused[block.id]!;
            accepted[block.id] = html;
            await onValidated?.call(block.id, html);
          }
          // This exact group completed on the provider in an earlier run.
          // Preserve successful-group sizing without counting historical usage.
          budget.observe(size, null, truncated: false);
          return;
        }
      }
      if (size.wireOutput <= 0 || (!size.fits && !repair)) {
        for (final block in blocks) {
          failures[block.id] = _BodyRepairReason.truncated;
        }
        return;
      }

      try {
        final response = await owner._apiClient.runRetried<Response<dynamic>>(
          config: config,
          retryDelayOverride: retryDelayOverride,
          shouldRetry: (error) =>
              !(error is DioException &&
                  TranslationApiClient.shouldFallbackBatchDioException(
                    error,
                  )) &&
              TranslationApiClient.shouldRetryBatchError(error),
          cancelToken: cancelToken,
          operation: () => owner._postChatCompletions(
            dio: dio,
            data: data,
            cancelToken: cancelToken,
          ),
        );
        final bool truncated = _isTruncated(response.data);
        final List<Object?> rows = _responseRows(
          response.data,
          truncated: truncated,
        );
        final requested = {for (final block in blocks) block.id};
        final unique = _uniqueResponseRows(rows, requested);
        for (final block in blocks) {
          final row = unique[block.id];
          final plain = textById[block.id];
          final String field = plain == null ? 'html' : 'text';
          final Object? value = row?[field];
          if (row != null && (row.length != 2 || !row.containsKey(field))) {
            failures[block.id] = _BodyRepairReason.structure;
            continue;
          }
          if (value is! String || value.trim().isEmpty) {
            failures[block.id] = truncated
                ? _BodyRepairReason.truncated
                : _BodyRepairReason.missing;
            continue;
          }
          final String locked;
          try {
            locked = plain == null
                ? EpubChapterTranslator._lockAndValidateTranslatedBlock(
                    config: config,
                    block: block,
                    translatedHtml: value.trim(),
                  )
                : plain.render(
                    config: config,
                    block: block,
                    translation: value,
                  );
          } on FormatException catch (error) {
            failures[block.id] =
                _EpubTranslationStrategy._isQualityRejection(error)
                ? _BodyRepairReason.residual
                : _BodyRepairReason.structure;
            continue;
          }
          accepted[block.id] = locked;
          failures.remove(block.id);
          await onValidated?.call(block.id, locked);
        }
        final bool complete =
            !repair && blocks.every((block) => accepted.containsKey(block.id));
        budget.observe(
          size,
          response.data,
          truncated: truncated,
          complete: complete,
        );
        if (complete && !truncated && rememberReusable != null) {
          await rememberReusable(blocks, data, {
            for (final block in blocks) block.id: accepted[block.id]!,
          });
        }
      } on DioException catch (error) {
        if (EpubChapterTranslator._isCancelError(error)) {
          throw const TranslationCancelledException();
        }
        if (TranslationApiClient.shouldFallbackBatchDioException(error)) {
          budget.reduce(size);
          for (final block in blocks) {
            failures[block.id] = _BodyRepairReason.truncated;
          }
          return;
        }
        if (TranslationApiClient.isDeterministicHttpError(error)) {
          throw StateError(
            TranslationApiClient.deterministicHttpErrorMessage(error, config),
          );
        }
        if (TranslationApiClient.isConnectionTimeout(error)) {
          for (final block in blocks) {
            owner._markDegradedBlock(
              chapterPath: chapterPath ?? '',
              blockId: block.id,
              apiCounted: true,
              reason: _EpubTranslationStrategy._degradationReason(
                error,
                config,
              ),
            );
            accepted[block.id] = block.sourceHtml;
            failures.remove(block.id);
          }
          return;
        }
        rethrow;
      }
    }

    await runGroup(batch.blocks, repair: false);
    final pending = [
      for (final block in batch.blocks)
        if (failures.containsKey(block.id)) block,
    ];
    // Use short, bounded groups after a missing/invalid reply. Truncated
    // batches additionally reduce the group size rather than repeating it.
    for (int start = 0; start < pending.length;) {
      final bool hadTruncation = pending
          .skip(start)
          .take(4)
          .any((block) => failures[block.id] == _BodyRepairReason.truncated);
      final int limit = hadTruncation ? min(3, max(1, pending.length ~/ 2)) : 4;
      final int end = min(start + limit, pending.length);
      await runGroup(pending.sublist(start, end), repair: true);
      start = end;
    }
    final remaining = [
      for (final block in batch.blocks)
        if (!accepted.containsKey(block.id)) block,
    ];
    if (remaining.isNotEmpty) {
      final fallback = await strategy.translateBlocksIndividually(
        dio: dio,
        config: config,
        batch: strategy._batchSubset(batch, remaining),
        chapterPath: chapterPath,
        styleProfile: _EpubBookMemory._styleProfileFromBookMemoryJson(
          batch.context.bookMemory,
        ),
        styleProfileConfirmed:
            _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
              batch.context.bookMemory,
            ),
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        fallbackWindow: fallbackWindow,
        onValidated: onValidated,
      );
      for (int i = 0; i < remaining.length; i++) {
        accepted[remaining[i].id] = fallback[i];
      }
    }
    return [for (final block in batch.blocks) accepted[block.id]!];
  }

  Map<String, dynamic> _request(
    TranslationConfig config,
    TranslationBatchContext context,
    List<Map<String, String>> blocks, {
    required bool repair,
  }) {
    final profile = _EpubBookMemory._styleProfileFromBookMemoryJson(
      context.bookMemory,
    );
    final confirmed = _EpubBookMemory._styleProfileConfirmedFromBookMemoryJson(
      context.bookMemory,
    );
    final String instruction = repair
        ? 'Repair only the requested EPUB fragments in ${config.targetLanguage}. Each reason is read-only. For residual source text, translate every readable text node completely; for truncated or missing output, return the complete block; for structure, preserve all markup and links.'
        : context.needsContinuity
        ? 'Translate these EPUB fragments into ${config.targetLanguage}. Use read-only context for continuity, pronouns, tone, terminology and paragraph flow. Preserve known relationships without guessing gender, age or unsupported specificity.'
        : 'Translate these EPUB fragments into ${config.targetLanguage}. Use relevant read-only context to keep terminology and tone consistent.';
    final int textRows = blocks
        .where((block) => block.containsKey('text'))
        .length;
    final String responseShape = switch (textRows) {
      0 =>
        'Return only JSON with a blocks array of {"id", "html"} objects in order. Keep all ids and translate only readable text. Preserve every HTML tag, attribute, entity, footnote marker and emphasis.',
      _ when textRows == blocks.length =>
        'Return only JSON with a blocks array of {"id", "text"} objects in order. Keep all ids. Translate the plain text without adding markup or commentary.',
      _ =>
        'Return only JSON with a blocks array in order. Keep each id and return its original text or html field. Translate text as plain text. In html, translate only readable text and preserve all tags, attributes, entities, footnote markers and emphasis.',
    };
    return {
      '_folioFerryBudgetedBody': true,
      if (!repair && !context.needsContinuity)
        '_folioFerryPreferLowReasoning': true,
      'model': config.model,
      'temperature': 0.2,
      'messages': <Map<String, String>>[
        {
          'role': 'system',
          'content':
              '$instruction $responseShape${strategy._styleInstructionFragment(config: config, styleProfile: profile, confirmed: confirmed)}${strategy._bodyGlossaryInstruction(config, context)}${strategy._idiomaticTranslationInstruction()}',
        },
        {
          'role': 'user',
          'content': jsonEncode({
            if (repair) 'kind': 'bodyRepair',
            if (!context.isEmpty) 'context': context.toJson(),
            'blocks': blocks,
          }),
        },
      ],
    };
  }

  static Map<String, Map<String, dynamic>> _uniqueResponseRows(
    List<Object?> rows,
    Set<String> requested,
  ) {
    final unique = <String, Map<String, dynamic>>{};
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic> || row['id'] is! String) continue;
      final id = row['id'] as String;
      if (!requested.contains(id)) continue;
      if (seen.add(id)) {
        unique[id] = row;
      } else {
        unique.remove(id);
      }
    }
    return unique;
  }

  static bool _isTruncated(Object? envelope) {
    final choices = envelope is Map ? envelope['choices'] : null;
    return choices is List &&
        choices.isNotEmpty &&
        choices.first is Map &&
        choices.first['finish_reason'] == 'length';
  }

  List<Object?> _responseRows(dynamic envelope, {required bool truncated}) {
    try {
      if (truncated && envelope is Map) {
        final choices = envelope['choices'] as List;
        final first = choices.first as Map;
        // Inspect completed rows only. The transport's general extractor
        // correctly rejects a length-truncated reply as a whole.
        final completeRows = owner._apiClient.extractMessageContent(
          <String, dynamic>{
            ...envelope,
            'choices': <Map<String, dynamic>>[
              {...Map<String, dynamic>.from(first), 'finish_reason': 'stop'},
            ],
          },
        );
        return _completedRowsBeforeTruncation(completeRows);
      }
      final decoded = owner._apiClient.decodeJsonObject(
        owner._apiClient.extractMessageContent(envelope),
      );
      final rows = decoded['blocks'];
      return rows is List ? rows : const [];
    } on FormatException {
      return const [];
    }
  }

  static final RegExp _blockArrayStart = RegExp(
    r'^\s*(?:```(?:json)?\s*)?\{\s*"blocks"\s*:\s*\[',
  );

  List<Object?> _completedRowsBeforeTruncation(String text) {
    final Match? head = _blockArrayStart.firstMatch(text);
    if (head == null) return const [];
    final rows = <Object?>[];
    int skipWhitespace(int index) {
      while (index < text.length && text.codeUnitAt(index) <= 32) {
        index++;
      }
      return index;
    }

    int start = skipWhitespace(head.end);
    while (start < text.length && text.codeUnitAt(start) == 123) {
      int depth = 0;
      bool quoted = false;
      bool escaped = false;
      int end = start;
      for (; end < text.length; end++) {
        final int char = text.codeUnitAt(end);
        if (quoted) {
          if (escaped) {
            escaped = false;
          } else if (char == 92) {
            escaped = true;
          } else if (char == 34) {
            quoted = false;
          }
        } else if (char == 34) {
          quoted = true;
        } else if (char == 123) {
          depth++;
        } else if (char == 125 && --depth == 0) {
          break;
        }
      }
      if (end == text.length) break;
      final int next = skipWhitespace(end + 1);
      final int delimiter = next == text.length ? -1 : text.codeUnitAt(next);
      if (delimiter != -1 && delimiter != 44 && delimiter != 93) break;
      try {
        rows.add(
          owner._apiClient.decodeJsonObject(text.substring(start, end + 1)),
        );
      } on FormatException {
        // A malformed row cannot be reused. Continue with the next complete row.
      }
      if (delimiter != 44) break;
      start = skipWhitespace(next + 1);
    }
    return rows;
  }
}
