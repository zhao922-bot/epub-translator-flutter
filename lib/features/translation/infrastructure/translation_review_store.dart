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

  Future<Map<String, dynamic>> load(String reportPath) => Isolate.run(() async {
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
    final seen = <String>{};
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
    return decoded;
  });

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
    final snapshots = Map<String, dynamic>.from(rendering['chapters'] as Map);
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
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final output =
        '${path.withoutExtension(baseOutputPath)}_reviewed_$stamp.epub';
    await EpubIsolateWorker.writeTranslatedEpub(
      inputPath: baseOutputPath,
      outputFilePath: output,
      translatedHtmlByPath: prepared.html,
      navigationLabelsByPath: prepared.labels,
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
    report['unresolvedAfterManualReview'] = [
      for (final id in (report['unreviewed'] as List? ?? []))
        if (!manuallyReviewed.any((key) => key.replaceAll('\u0000', ':') == id))
          id,
    ];
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
