import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_style_profile_card.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

/// Round-10 bug-audit regressions (2026-09-29): 4 major + 15 minor fixed.
/// Three items were deliberately NOT fixed and have no tests here:
/// - m10 (proper-name across non-empty inline tags): fail-safe skip kept.
/// - m4 (cancel during isolate archive decode): needs rearchitecture.
/// - m5 (2x memory across the isolate boundary): needs TransferableTypedData
///   redesign + real low-memory device validation.
void main() {
  const List<ProperNameMap> mappings = <ProperNameMap>[
    ProperNameMap(source: 'Adam Smith', target: '亚当·斯密'),
  ];

  String normalize(String html) {
    return ProperNameNormalizer.normalizeHtml(
      html,
      mappings,
      targetLanguage: 'zh',
      state: ProperNameNormalizer.bookState(),
    );
  }

  group('M3 reverse gloss only rewrites the locked translation', () {
    test('an appositive is not disguised as a gloss', () {
      // Old code rewrote this to 英国经济学家（Adam Smith）, disguising the
      // appositive as the name's translation and polluting first-occurrence
      // book state.
      final String out = normalize('<p>Adam Smith（英国经济学家）说中文。</p>');
      expect(out, isNot(contains('英国经济学家（Adam Smith）')));
      expect(out, contains('英国经济学家'));
    });

    test('a variant gloss is unified to the locked target', () {
      final String out = normalize('<p>Adam Smith（亚当斯密）说中文。</p>');
      expect(out, contains('亚当·斯密（Adam Smith）'));
    });

    test('a truncated transliteration is left untouched', () {
      // Strict rule: 亚当 is not the locked 亚当·斯密 after normalization,
      // so the model wording is left alone rather than disguised as a gloss.
      final String out = normalize('<p>Adam Smith（亚当）说中文。</p>');
      expect(out, contains('Adam Smith（亚当）说中文'));
      expect(out, isNot(contains('亚当（Adam Smith）')));
    });
  });

  group('M4 forward half-width gloss only folds the locked translation', () {
    test('an unrelated preceding phrase is left alone', () {
      // Old code folded this to 他在北京（Adam Smith）, mislabeling the
      // phrase as the name's translation. (The bare name inside the parens
      // still gets its normal first-occurrence annotation.)
      final String out = normalize('<p>他在北京 (Adam Smith) 工作。</p>');
      expect(out, isNot(contains('他在北京（Adam Smith）')));
    });

    test('the real translation still folds', () {
      final String out = normalize('<p>亚当·斯密 (Adam Smith) 说中文。</p>');
      expect(out, contains('亚当·斯密（Adam Smith）'));
    });

    test('a separator variant is unified to the locked target', () {
      final String out = normalize('<p>亚当斯密 (Adam Smith) 说中文。</p>');
      expect(out, contains('亚当·斯密（Adam Smith）'));
    });
  });

  group('minor proper-name fixes', () {
    test('m8: #AdamSmith is not split into a fake name gap', () {
      final String out = normalize('<p>联系 #AdamSmith 获取帮助。</p>');
      expect(out, isNot(contains('亚当')));
    });

    test('m9: folding keeps the space after the closing paren', () {
      final String out = normalize('<p>亚当·斯密 (Adam Smith) is here.</p>');
      expect(out, contains('亚当·斯密（Adam Smith） is here.'));
    });

    test('m11: single-quoted bibliography class is exempt', () {
      final String out = normalize(
        "<div class='bibliography'><p>Adam Smith 的理论影响深远。</p></div>",
      );
      expect(out, isNot(contains('亚当')));
    });

    test('m12: a locked name after a work title is not protected away', () {
      final String out = normalize('<p>《国富论》(Adam Smith) 的作者。</p>');
      expect(out, contains('亚当·斯密（Adam Smith）'));
    });

    test('m18: a single-word name split by an anchor stays compact', () {
      // m18 concerns single-word locked names (e.g. a pagebreak anchor
      // emitted at fixed character intervals).
      final String out = ProperNameNormalizer.normalizeHtml(
        '<p>Ad<span></span>am 说中文。</p>',
        const <ProperNameMap>[ProperNameMap(source: 'Adam', target: '亚当')],
        targetLanguage: 'zh',
        state: ProperNameNormalizer.bookState(),
      );
      expect(out, contains('亚当（Adam）'));
      expect(out, isNot(contains('Ad am')));
    });
  });

  group('M1 duplicate spine entries are inspected once', () {
    test('repeated idrefs and aliased hrefs collapse to one chapter', () {
      const String opf =
          '<package xmlns="http://www.idpf.org/2007/opf">'
          '<manifest>'
          '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c1b" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest>'
          '<spine>'
          '<itemref idref="c1"/>'
          '<itemref idref="c1"/>'
          '<itemref idref="c1b"/>'
          '<itemref idref="c2"/>'
          '</spine>'
          '</package>';
      final result = EpubInspector.chapterPathsFromOpfBytes(
        files: <String, List<int>>{'OEBPS/content.opf': utf8.encode(opf)},
        opfPath: 'OEBPS/content.opf',
      );
      // Old code returned ch1.xhtml three times, causing double translation
      // and double API billing.
      expect(result.chapterPaths, <String>[
        'OEBPS/ch1.xhtml',
        'OEBPS/ch2.xhtml',
      ]);
    });
  });

  group('M2 single-letter dropcap is only removed before CJK', () {
    InspectedChapter chapterWith(String translatedHtml) {
      return InspectedChapter(
        path: 'OEBPS/ch1.xhtml',
        title: 'Chapter 1',
        body: 'Chapter 1',
        originalHtml: '<html><body><p>When in doubt.</p></body></html>',
        blocks: <ExtractedBlock>[
          ExtractedBlock(
            id: 'p-1',
            tagName: 'p',
            sourceHtml: '<p>When in doubt.</p>',
            sourceText: 'When in doubt.',
            translatedHtml: translatedHtml,
          ),
        ],
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      );
    }

    test('stray initial before a CJK sentence is removed', () {
      final String rendered = EpubRepacker().renderTranslatedChapter(
        chapter: chapterWith('<p><span class="dropcap">W</span>每当我提问时</p>'),
        bilingual: false,
      );
      final document = html_parser.parse(rendered);
      expect(document.querySelector('span.dropcap'), isNull);
      expect(document.querySelector('p')?.text, '每当我提问时');
    });

    test('an English word head is kept, only the class is dropped', () {
      // Old code deleted the letter, corrupting "Adam" into "dam".
      final String rendered = EpubRepacker().renderTranslatedChapter(
        chapter: chapterWith(
          '<p><span class="dropcap">A</span>dam Smith 说中文</p>',
        ),
        bilingual: false,
      );
      final document = html_parser.parse(rendered);
      expect(document.querySelector('span.dropcap'), isNull);
      final String? text = document.querySelector('p')?.text;
      // The head letter survives: "Adam" must not become "dam".
      expect(text, startsWith('Adam'));
      expect(text, contains('Adam Smith 说中文'));
    });
  });

  group('pipeline minor fixes', () {
    test('m1: real chapter titles are not ancillary', () {
      final EpubHtmlExtractor extractor = EpubHtmlExtractor();
      expect(
        extractor.categorizeChapter('ch1.xhtml', 'Copyright'),
        ChapterCategory.ancillary,
      );
      // Old code defaulted these to ancillary (unchecked for translation).
      expect(
        extractor.categorizeChapter('ch2.xhtml', 'Cover Story'),
        isNot(ChapterCategory.ancillary),
      );
      expect(
        extractor.categorizeChapter('ch3.xhtml', 'Copyright and Fair Use'),
        isNot(ChapterCategory.ancillary),
      );
    });

    test('m2: nav manifest href with #fragment still resolves', () {
      final Map<String, String> replacements = EpubRepacker()
          .renderNavigationMetadataForTest(
            archiveFiles: <String, List<int>>{
              'META-INF/container.xml': utf8.encode(
                '<container><rootfiles>'
                '<rootfile full-path="OPS/content.opf"/>'
                '</rootfiles></container>',
              ),
              'OPS/content.opf': utf8.encode(
                '<package><metadata/><manifest>'
                '<item id="nav" href="nav.xhtml#top" properties="nav" '
                'media-type="application/xhtml+xml"/>'
                '</manifest><spine/></package>',
              ),
              'OPS/nav.xhtml': utf8.encode(
                '<html><body><nav epub:type="toc">'
                '<a href="ch1.xhtml">Old Title</a>'
                '</nav></body></html>',
              ),
            },
            chapters: <InspectedChapter>[
              InspectedChapter(
                path: 'OPS/ch1.xhtml',
                title: 'One',
                body: 'One',
                originalHtml: '<html><body><h1>One</h1></body></html>',
                blocks: const <ExtractedBlock>[
                  ExtractedBlock(
                    id: 'h1-1',
                    tagName: 'h1',
                    sourceHtml: '<h1>One</h1>',
                    sourceText: 'One',
                    translatedHtml: '<h1>第一章</h1>',
                  ),
                ],
                category: ChapterCategory.content,
                recommendedForTranslation: true,
                includeInTranslation: true,
              ),
            ],
            targetLanguage: 'Chinese',
          );
      // Old code looked up 'OPS/nav.xhtml#top' in the archive map, missed,
      // and silently skipped translating the nav document.
      expect(replacements, contains('OPS/nav.xhtml'));
      expect(replacements['OPS/nav.xhtml'], contains('第一章'));
    });

    test('m6: a model-added lang marking is never overwritten', () {
      final String rendered = EpubRepacker().renderTranslatedChapter(
        chapter: InspectedChapter(
          path: 'OEBPS/ch1.xhtml',
          title: 'Chapter 1',
          body: 'Chapter 1',
          originalHtml: '<html><body><p>To be.</p></body></html>',
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>To be.</p>',
              sourceText: 'To be.',
              translatedHtml: '<span lang="en">to be or not to be</span> 是一个问题',
            ),
          ],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
        bilingual: false,
      );
      // Old code rewrote lang="en" to the target language, mislabeling a
      // foreign-language quote for TTS/readers.
      expect(rendered, contains('lang="en"'));
      expect(rendered, isNot(contains('lang="zh"')));
    });

    test('m6 refined: a source-marked quote kept verbatim keeps its lang', () {
      // The source itself marked the English quote and the model preserved
      // both text and marking: not a stale echo, the lang="en" must survive.
      final String rendered = EpubRepacker().renderTranslatedChapter(
        chapter: InspectedChapter(
          path: 'OEBPS/ch1.xhtml',
          title: 'Chapter 1',
          body: 'Chapter 1',
          originalHtml:
              '<html><body><p>He said <span lang="en">to be</span> and left.</p></body></html>',
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml:
                  '<p>He said <span lang="en">to be</span> and left.</p>',
              sourceText: 'He said to be and left.',
              translatedHtml: '他说 <span lang="en">to be</span> 然后走了',
            ),
          ],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
        bilingual: false,
      );
      expect(rendered, contains('lang="en"'));
    });

    test('m7: single-quoted toc class is recognized', () {
      final String out = EpubRepacker().synchronizeHtmlTocForTest(
        tocPath: 'OEBPS/toc.xhtml',
        tocHtml:
            '<html><body><div class=\'toc\'><a href="ch1.xhtml">Old One</a></div></body></html>',
        chapters: <InspectedChapter>[
          InspectedChapter(
            path: 'OEBPS/toc.xhtml',
            title: 'Contents',
            body: 'Contents',
            originalHtml:
                '<html><body><div class=\'toc\'><a href="ch1.xhtml">Old One</a></div></body></html>',
            blocks: const <ExtractedBlock>[],
            category: ChapterCategory.content,
            recommendedForTranslation: true,
            includeInTranslation: true,
          ),
          InspectedChapter(
            path: 'OEBPS/ch1.xhtml',
            title: 'One',
            body: 'One',
            originalHtml: '<html><body><h1>One</h1></body></html>',
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'h1-1',
                tagName: 'h1',
                sourceHtml: '<h1>One</h1>',
                sourceText: 'One',
                translatedHtml: '<h1>第一章</h1>',
              ),
            ],
            category: ChapterCategory.content,
            recommendedForTranslation: true,
            includeInTranslation: true,
          ),
        ],
      );
      // Old code only matched class="toc", leaving single-quoted TOC labels
      // in the source language.
      expect(out, contains('第一章'));
      expect(out, isNot(contains('>Old One</a>')));
    });
  });

  group('controller fixes', () {
    test(
      'm3: retrying a pre-1.4.3 failed job uses the recommended selection',
      () async {
        final _Round10FakeRepository repository = _Round10FakeRepository();
        final _Round10FakeHistoryStore historyStore = _Round10FakeHistoryStore(
          jobs: <TranslationJob>[
            TranslationJob(
              id: 'old-job',
              inputPath: 'C:\\Books\\old.epub',
              outputPath: 'C:\\Out',
              status: TranslationJobStatus.failed,
              phase: TranslationJobPhase.translation,
              progress: 0.5,
              completedBlocks: 5,
              totalBlocks: 10,
              // Jobs written before 1.4.3 have no selectedChapterPaths field.
              selectedChapterPaths: null,
            ),
          ],
        );
        final TranslationDashboardController controller =
            TranslationDashboardController(
              repository: repository,
              historyStore: historyStore,
            );
        await Future<void>.delayed(Duration.zero);

        await controller.retryJob('old-job');

        // Null means "unknown": fall back to the inspection's recommended
        // selection. Old code passed [], stalling the retry with nothing to
        // translate.
        expect(controller.state.inspectedChapters, isNotEmpty);
        expect(
          controller.state.inspectedChapters.every(
            (InspectedChapter c) => c.includeInTranslation,
          ),
          isTrue,
        );
        // A pre-style-profile job gets one generated, not silently skipped.
        expect(repository.styleGenerateCount, 1);
        // The selection was unknown, so the retry must NOT auto-translate:
        // it waits for the user to confirm the recommended selection first.
        expect(repository.translateCount, 0);
        expect(
          controller.state.logs.any(
            (String line) => line.contains('no saved chapter selection'),
          ),
          isTrue,
        );
      },
    );

    test('m16: startInspection rejects a non-EPUB manual path', () async {
      final _Round10FakeRepository repository = _Round10FakeRepository();
      final TranslationDashboardController controller =
          TranslationDashboardController(repository: repository);
      await Future<void>.delayed(Duration.zero);

      controller.setInputPath('C:\\Books\\notes.txt');
      await controller.startInspection();

      expect(repository.startCount, 0);
      expect(
        controller.state.logs.any(
          (String line) => line.contains('Please choose a .epub file'),
        ),
        isTrue,
      );
    });

    test(
      'm17: toggling chapters after inspection drops the stale progress',
      () async {
        final _Round10FakeRepository repository = _Round10FakeRepository();
        final TranslationDashboardController controller =
            TranslationDashboardController(repository: repository);
        await Future<void>.delayed(Duration.zero);

        controller.setInputPath('C:\\Books\\book.epub');
        await controller.startInspection();
        // The fake inspection job carries completedBlocks=1; a fresh estimate
        // must not present it as run progress.
        expect(controller.state.runEstimate?.completedBlocks, 0);

        controller.toggleChapterInclusion('chapter.xhtml', false);

        final estimate = controller.state.runEstimate;
        expect(estimate, isNotNull);
        expect(estimate?.completedBlocks, 0);
        // No stale stopwatch: with elapsed null there is no runtime data.
        expect(estimate?.hasRuntimeData, isFalse);
        expect(estimate?.estimatedRemaining, isNull);
        // Static part still describes the new selection (now empty).
        expect(estimate?.totalBlocks, 0);
        expect(estimate?.hasSelection, isFalse);
      },
    );
  });

  group('m15 card stays editable while generating', () {
    testWidgets('fields and confidence are enabled during generation', (
      WidgetTester tester,
    ) async {
      const AppStrings strings = AppStrings(UiLanguage.chinese);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TranslationStyleProfileCard(
                strings: strings,
                profile: TranslationStyleProfile.empty,
                confirmed: false,
                enabled: true,
                editable: true,
                isGenerating: true,
                canGenerate: false,
                onGenerate: () {},
                onConfirm: () {},
                onChanged:
                    ({
                      primaryGenre,
                      secondaryGenresCsv,
                      tone,
                      sentenceStyle,
                      constraintsText,
                      avoidText,
                      confidence,
                    }) {},
              ),
            ),
          ),
        ),
      );

      final Finder field = find.byWidgetPredicate(
        (Widget widget) =>
            widget is TextField &&
            widget.decoration?.labelText == strings.styleProfilePrimaryGenre,
      );
      expect(field, findsOneWidget);
      // Old code disabled every input while isGenerating was true, which
      // contradicted the controller's edit-during-generation merge design.
      expect(tester.widget<TextField>(field).enabled, isTrue);
    });
  });
}

class _Round10FakeRepository implements TranslationRepository {
  int startCount = 0;
  int styleGenerateCount = 0;
  int translateCount = 0;
  List<InspectedChapter>? lastTranslateChapters;

  List<InspectedChapter> _chapters() => <InspectedChapter>[
    const InspectedChapter(
      path: 'chapter.xhtml',
      title: 'Chapter',
      body: '',
      originalHtml: '',
      blocks: <ExtractedBlock>[
        ExtractedBlock(
          id: 'block-0',
          tagName: 'p',
          sourceHtml: 'short text',
          sourceText: 'short text',
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    ),
  ];

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    startCount += 1;
    final TranslationJob job = TranslationJob(
      id: 'job-1',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      progress: 1,
      completedBlocks: 1,
      totalBlocks: 1,
    );
    return InspectionResult(job: job, chapters: _chapters());
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    translateCount += 1;
    lastTranslateChapters = chapters;
    final TranslationJob job = TranslationJob(
      id: 'job-1',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.completed,
      progress: 1,
      completedBlocks: 1,
      totalBlocks: 1,
    );
    return TranslationRunResult(job: job, chapters: chapters);
  }

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async {
    styleGenerateCount += 1;
    return TranslationStyleProfile.empty;
  }

  @override
  Future<String> testConnection({required TranslationConfig config}) async =>
      'OK';

  @override
  Future<void> cancelJob(String jobId) async {}
}

class _Round10FakeHistoryStore extends JobHistoryStore {
  _Round10FakeHistoryStore({required this.jobs});

  final List<TranslationJob> jobs;

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: jobs, clearedAt: 0);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {}

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    return (written: true, fileClearedAt: 0);
  }
}
