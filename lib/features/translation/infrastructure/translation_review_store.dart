import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:html/parser.dart' as html;

import '../../../shared/io/atomic_file_writer.dart';
import '../domain/models/translation_config.dart';
import '../domain/models/inspected_chapter.dart';
import 'epub/epub_chapter_translator.dart';
import 'epub/epub_html_extractor.dart';
import 'epub/epub_repacker.dart';
import 'epub/epub_xml_characters.dart';
import 'epub/proper_name_normalizer.dart';
import 'epub/review_text_patch.dart';
import 'epub_isolate_worker.dart';

/// A review is an immutable baseline plus reversible user choices. Exporting
/// never overwrites the baseline or changes translation caches.
class TranslationReviewStore {
  const TranslationReviewStore();

  static String suggestionKey(Map item) =>
      '${item['chapter']}\u0000${item['id']}';

  /// Plain editing is offered only where it cannot flatten inline markup.
  static String? editableText(String markup) {
    final fragment = html.parseFragment(markup);
    if (fragment.children.length != 1 ||
        fragment.children.single.children.isNotEmpty) {
      return null;
    }
    return fragment.children.single.text;
  }

  static String editText(String markup, String text) {
    if (text.trim().isEmpty || editableText(markup) == null) {
      throw const FormatException(
        'This fragment cannot be edited as plain text.',
      );
    }
    final fragment = html.parseFragment(markup);
    fragment.children.single.text = text;
    return fragment.outerHtml;
  }

  static String replaceText(String markup, String before, String after) =>
      ReviewTextPatch.apply(markup, [
        {'before': before, 'after': after},
      ]);

  /// Expose every translated block, including errors the model never flagged.
  Future<List<Map<String, String>>> manualBlocks(Map<String, dynamic> report) =>
      Isolate.run(() {
        final result = <Map<String, String>>[];
        final snapshots = (report['rendering'] as Map)['chapters'];
        if (snapshots is! Map) return result;
        for (final e in snapshots.entries) {
          final snapshot = e.value as Map;
          final chapter = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: e.key as String,
            bytes: utf8.encode(snapshot['originalHtml'] as String),
          );
          final translations = snapshot['translations'] as Map;
          for (final block in chapter.blocks) {
            final draft = translations[block.id];
            if (draft is! String) continue;
            result.add({
              'chapter': e.key as String,
              'id': block.id,
              'key': '${e.key}\u0000${block.id}',
              'sourceHtml': block.sourceHtml,
              'beforeHtml': draft,
            });
          }
        }
        return result;
      });

  Future<Map<String, dynamic>> load(
    String reportPath, {
    String? expectedOutputPath,
  }) => Isolate.run(() async {
    final file = File(reportPath);
    if (await file.length() > 64 * 1024 * 1024) {
      throw const FormatException('Review report exceeds the size limit.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 2 ||
        decoded['outputPath'] is! String ||
        decoded['corrections'] is! List ||
        decoded['rendering'] is! Map) {
      throw const FormatException('Unsupported review report.');
    }
    final reasons = decoded['unreviewedReasons'];
    if (reasons != null &&
        (reasons is! Map ||
            reasons.entries.any(
              (e) => e.key is! String || e.value is! String,
            ))) {
      throw const FormatException('Invalid review coverage reasons.');
    }
    if (decoded['lastExportBilingual'] != null &&
        decoded['lastExportBilingual'] is! bool) {
      throw const FormatException('Invalid reviewed output format.');
    }
    final seen = <String>{};
    final automatic = decoded['automaticCorrections'];
    if (automatic != null) {
      final automaticKeys = <String>{};
      if (automatic is! List ||
          automatic.any(
            (item) =>
                item is! Map ||
                [
                  'chapter',
                  'id',
                  'sourceHtml',
                  'beforeHtml',
                  'afterHtml',
                  'verificationReason',
                ].any((key) => item[key] is! String) ||
                item['verified'] != true ||
                !automaticKeys.add(suggestionKey(item)),
          )) {
        throw const FormatException('Invalid automatic correction history.');
      }
    }
    for (final item in decoded['corrections'] as List) {
      if (item is! Map ||
          [
            'chapter',
            'id',
            'sourceHtml',
            'beforeHtml',
            'afterHtml',
          ].any((k) => item[k] is! String) ||
          item['issues'] is! List ||
          (item['issues'] as List).any((v) => v is! String) ||
          (item['checksAfter'] != null && item['checksAfter'] is! List) ||
          !seen.add(suggestionKey(item))) {
        throw const FormatException('Invalid review suggestion.');
      }
    }
    if (decoded['unreviewed'] != null &&
        (decoded['unreviewed'] is! List ||
            (decoded['unreviewed'] as List).any((v) => v is! String))) {
      throw const FormatException('Invalid review coverage.');
    }
    if (decoded['findings'] != null) {
      if (decoded['findings'] is! List) {
        throw const FormatException('Invalid review findings.');
      }
      for (final item in decoded['findings'] as List) {
        if (item is! Map ||
            item['block'] is! String ||
            item['checks'] is! List ||
            (item['checks'] as List).any(
              (c) => c is! Map || c['detail'] is! String,
            )) {
          throw const FormatException('Invalid consistency finding.');
        }
      }
    }
    final edits = decoded['manualEdits'];
    final reviewed = decoded['manuallyReviewed'];
    if ((edits != null &&
            (edits is! Map ||
                edits.entries.any(
                  (e) => e.key is! String || e.value is! String,
                ))) ||
        (reviewed != null &&
            (reviewed is! List || reviewed.any((v) => v is! String)))) {
      throw const FormatException('Invalid manual review choices.');
    }
    final last = decoded['lastExportPath'];
    if (last != null &&
        (last is! String || path.extension(last).toLowerCase() != '.epub')) {
      throw const FormatException('Invalid reviewed output path.');
    }
    if (expectedOutputPath != null) {
      String identity(String p) => Platform.isWindows
          ? path.normalize(path.absolute(p)).toLowerCase()
          : path.normalize(path.absolute(p));
      if (identity(decoded['outputPath'] as String) !=
          identity(expectedOutputPath)) {
        throw const FormatException('Review output identity changed.');
      }
      final rendering = decoded['rendering'] as Map;
      // Partial/legacy reports also carry baseline hashes. Their format flag
      // only controls whole-book conversion; it must not bypass identity checks.
      final snapshots = _validatedSnapshots(decoded, rendering);
      final baseline = await EpubIsolateWorker.loadInspectionSnapshot(
        expectedOutputPath,
        selectEntries: (_, _) => snapshots.keys.toSet(),
      );
      for (final entry in snapshots.entries) {
        final bytes = baseline.files[entry.key];
        if (bytes == null ||
            sha256.convert(bytes).toString() !=
                (entry.value as Map)['baseHtmlSha256']) {
          throw const FormatException(
            'The review report belongs to an older EPUB.',
          );
        }
      }
    }
    return decoded;
  });

  /// Every displayed/exported suggestion must belong to a hashed chapter.
  /// A partial report may omit unrelated chapters, but never its own evidence.
  static Map<String, dynamic> _validatedSnapshots(Map report, Map rendering) {
    bool strings(Object? value) =>
        value is List && value.every((v) => v is String);
    if (rendering['targetLanguage'] is! String ||
        rendering['lockedGlossary'] is! String ||
        rendering['bilingual'] is! bool ||
        (rendering['completeSnapshot'] != null &&
            rendering['completeSnapshot'] is! bool) ||
        (rendering['residualQualityCheck'] != null &&
            rendering['residualQualityCheck'] is! bool)) {
      throw const FormatException('Invalid review rendering settings.');
    }
    if (rendering.containsKey('sourceLanguages') &&
        (!strings(rendering['sourceLanguages']) ||
            (rendering['sourceLanguages'] as List).any(
              (v) => (v as String).trim().isEmpty,
            ))) {
      throw const FormatException('Invalid review source languages.');
    }
    final chapters = rendering['chapters'];
    if (chapters is! Map || chapters.isEmpty) {
      throw const FormatException('Review baseline snapshots are missing.');
    }
    for (final entry in chapters.entries) {
      final snapshot = entry.value;
      if (entry.key is! String ||
          snapshot is! Map ||
          snapshot['originalHtml'] is! String ||
          snapshot['translations'] is! Map ||
          (snapshot['translations'] as Map).entries.any(
            (e) => e.key is! String || e.value is! String,
          ) ||
          !strings(snapshot['countedNames']) ||
          !strings(snapshot['degraded']) ||
          (snapshot['includeInTranslation'] != null &&
              snapshot['includeInTranslation'] is! bool) ||
          snapshot['baseHtmlSha256'] is! String ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(snapshot['baseHtmlSha256'] as String)) {
        throw const FormatException('Invalid review baseline snapshot.');
      }
    }
    final sourceBlocks = <String, Map<String, String>>{};
    Map<String, String> blocksFor(String chapterPath) =>
        sourceBlocks.putIfAbsent(
          chapterPath,
          () => {
            for (final block
                in const EpubHtmlExtractor()
                    .inspectChapterBytes(
                      chapterPath: chapterPath,
                      bytes: utf8.encode(
                        chapters[chapterPath]['originalHtml'] as String,
                      ),
                    )
                    .blocks)
              block.id: block.sourceHtml,
          },
        );
    // Manual review and export also consume drafts with no model suggestion.
    // An unknown ID would be silently skipped and could restore source text.
    for (final entry in chapters.entries) {
      final translations = (entry.value as Map)['translations'] as Map;
      if (translations.isEmpty) continue;
      final blocks = blocksFor(entry.key as String);
      if (translations.keys.any((id) => !blocks.containsKey(id))) {
        throw const FormatException('Review draft has no baseline block.');
      }
    }
    for (final item in (report['corrections'] as List).cast<Map>()) {
      if (!chapters.containsKey(item['chapter'])) {
        throw const FormatException(
          'Review suggestion has no baseline chapter.',
        );
      }
      final chapterPath = item['chapter'] as String;
      final snapshot = chapters[chapterPath] as Map;
      final blocks = blocksFor(chapterPath);
      // Chapter hashes alone do not establish that a suggestion's block
      // exists. Otherwise export could silently ignore it yet mark it accepted.
      if (blocks[item['id']] != item['sourceHtml'] ||
          (snapshot['translations'] as Map)[item['id']] != item['beforeHtml']) {
        throw const FormatException(
          'Suggestion does not match the baseline block.',
        );
      }
    }
    for (final item
        in (report['automaticCorrections'] as List? ?? []).cast<Map>()) {
      final chapterPath = item['chapter'] as String;
      if (!chapters.containsKey(chapterPath) ||
          blocksFor(chapterPath)[item['id']] != item['sourceHtml'] ||
          (chapters[chapterPath]['translations'] as Map)[item['id']] !=
              item['afterHtml']) {
        throw const FormatException(
          'Automatic correction does not match the baseline block.',
        );
      }
    }
    return Map<String, dynamic>.from(chapters);
  }

  /// Normalize review identities once, then perform constant-time lookups.
  static List<String> unresolvedBlockIds(
    Map report,
    Set<String> manuallyReviewed,
  ) {
    final reviewed = manuallyReviewed
        .map((key) => key.replaceAll('\u0000', ':'))
        .toSet();
    return [
      for (final id in (report['unreviewed'] as List? ?? []).cast<String>())
        if (!reviewed.contains(id)) id,
    ];
  }

  Future<String> export({
    required String reportPath,
    required String baseOutputPath,
    required Set<String> accepted,
    bool? bilingual,
    Map<String, String> editedSuggestions = const {},
    Map<String, String> manualEdits = const {},
    Set<String> manuallyReviewed = const {},
  }) async {
    final report = await load(reportPath);
    if (!path.equals(
      path.absolute(report['outputPath'] as String),
      path.absolute(baseOutputPath),
    )) {
      throw const FormatException('The report belongs to another EPUB.');
    }
    final rendering = Map<String, dynamic>.from(report['rendering'] as Map);
    final outputBilingual = bilingual ?? rendering['bilingual'] == true;
    if (outputBilingual != (rendering['bilingual'] == true) &&
        rendering['completeSnapshot'] != true) {
      throw const FormatException(
        'This legacy report cannot convert the whole book.',
      );
    }
    final keys = (report['corrections'] as List)
        .cast<Map>()
        .map(suggestionKey)
        .toSet();
    if (editedSuggestions.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unknown edited suggestion.');
    }
    final snapshots = await Isolate.run(
      () => _validatedSnapshots(report, rendering),
    );
    final paths = snapshots.keys.toSet();
    final baseline = await EpubIsolateWorker.loadInspectionSnapshot(
      baseOutputPath,
      selectEntries: (_, _) => paths,
    );
    // Bind every snapshot to the actual exported chapter. A changed/missing
    // baseline must not silently apply suggestions to another edition.
    for (final e in snapshots.entries) {
      final bytes = baseline.files[e.key];
      if (bytes == null ||
          sha256.convert(bytes).toString() !=
              (e.value as Map)['baseHtmlSha256']) {
        throw const FormatException(
          'The baseline EPUB changed. Run translation again before reviewing.',
        );
      }
    }
    final prepared = await Isolate.run(
      () => _render(
        report,
        accepted,
        bilingual: outputBilingual,
        editedSuggestions: editedSuggestions,
        manualEdits: manualEdits,
        manuallyReviewed: manuallyReviewed,
      ),
    );
    final targetTag = EpubRepacker.languageTagForTarget(
      rendering['targetLanguage'] as String,
    );
    List<String>? sourceLanguages;
    if (outputBilingual && targetTag != null) {
      if (rendering.containsKey('sourceLanguages')) {
        sourceLanguages = (rendering['sourceLanguages'] as List).cast<String>();
      } else if (rendering['bilingual'] != true) {
        // Version-2 reports predating sourceLanguages retain source XHTML.
        // Use document-level declarations only: an inline foreign quotation
        // must not become a source book language. Never guess from prose.
        final seen = <String>{};
        sourceLanguages = [];
        for (final snapshot in snapshots.values.cast<Map>()) {
          final document = html.parse(snapshot['originalHtml'] as String);
          final root = document.documentElement;
          final body = document.body;
          final language =
              root?.attributes['xml:lang'] ??
              root?.attributes['lang'] ??
              body?.attributes['xml:lang'] ??
              body?.attributes['lang'];
          if (language != null &&
              language.trim().isNotEmpty &&
              seen.add(language.trim().toLowerCase())) {
            sourceLanguages.add(language.trim());
          }
        }
        if (sourceLanguages.isEmpty) {
          throw const FormatException(
            'This legacy report has no source language metadata. '
            'Translate the original EPUB again to enable bilingual conversion.',
          );
        }
      }
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final output = path.join(
      path.dirname(baseOutputPath),
      EpubChapterTranslator.outputFileName(
        path.basenameWithoutExtension(baseOutputPath),
        '_reviewed_$stamp',
      ),
    );
    if (Platform.isWindows) {
      await EpubChapterTranslator.throwIfOutputPathTooLongForWindows(output);
    }
    await EpubIsolateWorker.writeTranslatedEpub(
      inputPath: baseOutputPath,
      outputFilePath: output,
      translatedHtmlByPath: prepared.html,
      navigationLabelsByPath: prepared.labels,
      navigationLanguageTag: targetTag,
      sourceLanguageTags: sourceLanguages,
      bilingual: outputBilingual,
      expectedSourceFingerprint: baseline.fingerprint,
    );
    for (final item in (report['corrections'] as List).cast<Map>()) {
      item['accepted'] = accepted.contains(suggestionKey(item));
      final edit = editedSuggestions[suggestionKey(item)];
      if (edit != null) item['customHtml'] = edit;
    }
    report['lastExportPath'] = output;
    report['manualEdits'] = manualEdits;
    report['manuallyReviewed'] = manuallyReviewed.toList()..sort();
    report['unresolvedAfterManualReview'] = unresolvedBlockIds(
      report,
      manuallyReviewed,
    );
    report['lastExportBilingual'] = outputBilingual;
    report['lastExportAt'] = DateTime.now().toIso8601String();
    try {
      await writeFileAtomically(
        File(reportPath),
        const JsonEncoder.withIndent('  ').convert(report),
      );
    } catch (_) {
      throw ReviewChoicesSaveException(output);
    }
    return output;
  }

  static ({Map<String, String> html, Map<String, String> labels}) _render(
    Map<String, dynamic> report,
    Set<String> accepted, {
    required bool bilingual,
    Map<String, String> editedSuggestions = const {},
    Map<String, String> manualEdits = const {},
    Set<String> manuallyReviewed = const {},
  }) {
    final rendering = report['rendering'] as Map;
    final snapshots = rendering['chapters'] as Map;
    final suggestions = <String, Map>{
      for (final item in (report['corrections'] as List).cast<Map>())
        suggestionKey(item): item,
    };
    if (accepted.any((key) => !suggestions.containsKey(key))) {
      throw const FormatException('Unknown review suggestion.');
    }
    if (manualEdits.keys.any(accepted.contains)) {
      throw const FormatException(
        'Choose either manual text or a model suggestion for a block.',
      );
    }
    final manualKeys = {...manualEdits.keys, ...manuallyReviewed};
    final matchedManualKeys = <String>{};
    final config = TranslationConfig.defaults().copyWith(
      targetLanguage: rendering['targetLanguage'] as String,
      bilingual: bilingual,
      lockedGlossary: rendering['lockedGlossary'] as String,
      residualQualityCheck: rendering['residualQualityCheck'] != false,
    );
    final html = <String, String>{}, labels = <String, String>{};
    final repacker = EpubRepacker();
    final chapters = <InspectedChapter>[];
    for (final e in snapshots.entries) {
      final chapterPath = e.key as String;
      final snapshot = e.value as Map;
      final inspected = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: chapterPath,
        bytes: utf8.encode(snapshot['originalHtml'] as String),
      );
      final translations = snapshot['translations'] as Map;
      final chapter = inspected.copyWith(
        includeInTranslation: snapshot['includeInTranslation'] != false,
        blocks: [
          for (final block in inspected.blocks)
            block.copyWith(
              translatedHtml: () {
                final draft = translations[block.id] as String?;
                final key = '$chapterPath\u0000${block.id}';
                if (manualKeys.contains(key)) {
                  if (draft == null) {
                    throw const FormatException(
                      'Manual review requires a translated block.',
                    );
                  }
                  matchedManualKeys.add(key);
                }
                if (manualEdits.containsKey(key)) {
                  return EpubChapterTranslator.validateReviewSuggestion(
                    config: config,
                    block: block,
                    translatedHtml: manualEdits[key]!,
                  );
                }
                if (!accepted.contains(key)) return draft;
                final suggestion = suggestions[key]!;
                if (suggestion['beforeHtml'] != draft ||
                    suggestion['sourceHtml'] != block.sourceHtml) {
                  throw const FormatException(
                    'Suggestion does not match the baseline block.',
                  );
                }
                return EpubChapterTranslator.validateReviewSuggestion(
                  config: config,
                  block: block,
                  translatedHtml:
                      editedSuggestions[key] ??
                      suggestion['afterHtml'] as String,
                );
              }(),
            ),
        ],
      );
      chapters.add(chapter);
      final names = ProperNameBookState()
        ..countedNames.addAll(
          (snapshot['countedNames'] as List).cast<String>(),
        );
      final rendered = repacker.renderTranslatedChapter(
        chapter: chapter,
        bilingual: config.bilingual,
        targetLanguage: config.targetLanguage,
        lockedGlossary: config.lockedGlossary,
        properNameState: names,
        degradedBlockIds: (snapshot['degraded'] as List).cast<String>().toSet(),
        navigationLabels: labels,
      );
      validateEpubXmlMarkup(rendered);
      html[chapterPath] = rendered;
    }
    if (!matchedManualKeys.containsAll(manualKeys)) {
      throw const FormatException('Unknown manual review block.');
    }
    repacker.synchronizeReviewNavigation(html, chapters, labels, config);
    for (final value in html.values) {
      validateEpubXmlMarkup(value);
    }
    return (html: html, labels: labels);
  }
}

class ReviewChoicesSaveException implements Exception {
  const ReviewChoicesSaveException(this.outputPath);
  final String outputPath;
}
