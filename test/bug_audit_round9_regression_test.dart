import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_inputs.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_style_profile_card.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

import 'bug_audit_round4_regression_test.dart' as audit4;

/// Round-9 bug-audit regressions (2026-09-29): 1 major + 11 minor.
void main() {
  group('Major: navigation fragment labels', () {
    InspectedChapter chapterFor(
      String bodyHtml,
      Map<String, String> translatedByBlock,
    ) {
      const EpubHtmlExtractor extractor = EpubHtmlExtractor();
      final String originalHtml =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>$bodyHtml</body></html>';
      final blocks = extractor
          .extractBlocks(
            html_parser.parse(originalHtml),
            chapterPath: 'OEBPS/ch.xhtml',
          )
          .map(
            (block) => block.copyWith(
              translatedHtml:
                  translatedByBlock[block.id] ??
                  '<${block.tagName}></${block.tagName}>',
            ),
          )
          .toList();
      return InspectedChapter(
        path: 'OEBPS/ch.xhtml',
        title: 'Chapter',
        body: '',
        originalHtml: originalHtml,
        blocks: blocks,
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      );
    }

    test('EPUB2 empty anchor before the heading resolves to the label', () {
      final chapter = chapterFor(
        '<a id="ch1"></a><h1>Chapter One</h1><p>Body text.</p>',
        {'h1-1': '<h1>第一章</h1>', 'p-2': '<p>正文。</p>'},
      );
      final labels = EpubRepacker().debugNavigationLabels([chapter]);
      expect(labels['OEBPS/ch.xhtml#ch1'], '第一章');
    });

    test('EPUB3 section ancestor id resolves to the heading label', () {
      final chapter = chapterFor(
        '<section id="sec1"><h1>Chapter One</h1></section><p>Body.</p>',
        {'h1-1': '<h1>第一章</h1>', 'p-2': '<p>正文。</p>'},
      );
      final labels = EpubRepacker().debugNavigationLabels([chapter]);
      expect(labels['OEBPS/ch.xhtml#sec1'], '第一章');
    });

    test('first heading claims a shared ancestor id', () {
      final chapter = chapterFor(
        '<section id="sec"><h1>One</h1><h2>Two</h2></section>',
        {'h1-1': '<h1>一</h1>', 'h2-2': '<h2>二</h2>'},
      );
      final labels = EpubRepacker().debugNavigationLabels([chapter]);
      expect(labels['OEBPS/ch.xhtml#sec'], '一');
    });

    test('heading own id still registers (control)', () {
      final chapter = chapterFor('<h1 id="h1">Chapter One</h1>', {
        'h1-1': '<h1>第一章</h1>',
      });
      final labels = EpubRepacker().debugNavigationLabels([chapter]);
      expect(labels['OEBPS/ch.xhtml#h1'], '第一章');
    });
  });

  group('Minor1: path field focus guard', () {
    Future<void> pumpInputs(
      WidgetTester tester,
      ValueNotifier<String> inputPath,
      void Function(String) onInputChanged,
    ) async {
      const strings = AppStrings(UiLanguage.english);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<String>(
                valueListenable: inputPath,
                builder: (context, value, _) => TranslationInputs(
                  strings: strings,
                  inputPath: value,
                  outputDirectory: 'C:/Output',
                  targetLanguage: 'Chinese',
                  bilingual: false,
                  enabled: true,
                  onInputChanged: onInputChanged,
                  onOutputChanged: (_) {},
                  onTargetLanguageChanged: (_) {},
                  onBilingualChanged: (_) {},
                  onPickInputPressed: () {},
                  onPickOutputPressed: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text(strings.advancedPaths));
      await tester.tap(find.text(strings.advancedPaths));
      await tester.pump();
    }

    testWidgets('focused-but-untouched field accepts the external value', (
      tester,
    ) async {
      final inputPath = ValueNotifier<String>('A.epub');
      final commits = <String>[];
      addTearDown(inputPath.dispose);
      await pumpInputs(tester, inputPath, commits.add);

      final inputField = find.byType(TextFormField).first;
      await tester.ensureVisible(inputField);
      await tester.tap(inputField);
      await tester.pump();

      // External update (e.g. dropped EPUB) while focused but untyped.
      inputPath.value = 'B.epub';
      await tester.pump();

      final editable = find.descendant(
        of: inputField,
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).controller.text, 'B.epub');

      // Blurring must not revert the external update with the old text.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, isEmpty);
      expect(inputPath.value, 'B.epub');
    });

    testWidgets('typed text still wins over a mid-edit external update', (
      tester,
    ) async {
      final inputPath = ValueNotifier<String>('A.epub');
      final commits = <String>[];
      addTearDown(inputPath.dispose);
      await pumpInputs(tester, inputPath, commits.add);

      final inputField = find.byType(TextFormField).first;
      await tester.ensureVisible(inputField);
      await tester.tap(inputField);
      await tester.pump();
      final editable = find.descendant(
        of: inputField,
        matching: find.byType(EditableText),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'AX.epub',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();

      // External update while the user has typed: keep the typed text.
      inputPath.value = 'B.epub';
      await tester.pump();
      expect(tester.widget<EditableText>(editable).controller.text, 'AX.epub');

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, ['AX.epub']);
    });
  });

  group('Minor2+3: BOM-prefixed JSON', () {
    test('settings.json with a BOM loads', () async {
      final temp = await Directory.systemTemp.createTemp(
        'audit9_bom_settings_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString(
        'ï»¿${jsonEncode({'targetLanguage': 'Japanese'})}',
        encoding: latin1,
      );
      // Sanity: the file really starts with the UTF-8 BOM bytes.
      final bytes = await file.readAsBytes();
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);

      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: _FakeSettingsSecretStore(),
      );
      final config = await store.load();
      expect(config.targetLanguage, 'Japanese');
    });

    test('job-history.json with a BOM loads', () async {
      final temp = await Directory.systemTemp.createTemp('audit9_bom_history_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/job-history.json');
      final job = const TranslationJob(
        id: 'job-1',
        inputPath: 'book.epub',
        outputPath: 'out',
        status: TranslationJobStatus.completed,
        progress: 1,
      );
      await file.writeAsString(
        'ï»¿${jsonEncode([job.toJson()])}',
        encoding: latin1,
      );

      final store = JobHistoryStore(historyFileProvider: () async => file);
      final jobs = await store.load();
      expect(jobs.single.id, 'job-1');
    });

    test(
      'corrupt job-history.json is quarantined, not silently overwritten',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'audit9_bad_history_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/job-history.json');
        await file.writeAsString('{"jobs": [broken');

        final store = JobHistoryStore(historyFileProvider: () async => file);
        final jobs = await store.load();
        expect(jobs, isEmpty);
        // The corrupt file must be preserved for diagnosis...
        final badFiles = temp
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.bad-'))
            .toList();
        expect(badFiles, hasLength(1));
        // ...and a later save must not silently clobber the quarantine.
        await store.save(const <TranslationJob>[]);
        expect(badFiles.single.existsSync(), isTrue);
      },
    );
  });

  group('Minor4: cross-process history merge', () {
    TranslationJob job(String id) => TranslationJob(
      id: id,
      inputPath: 'book.epub',
      outputPath: 'out',
      status: TranslationJobStatus.completed,
      progress: 1,
    );

    test('two instances appending concurrently keep both jobs', () async {
      final temp = await Directory.systemTemp.createTemp('audit9_merge_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/job-history.json');
      final a = JobHistoryStore(historyFileProvider: () async => file);
      final b = JobHistoryStore(historyFileProvider: () async => file);

      await Future.wait([
        a.saveMerged(
          merge: (fileJobs, _) => [...fileJobs, job('job-a')],
          clearedAtEpochMs: 0,
        ),
        b.saveMerged(
          merge: (fileJobs, _) => [...fileJobs, job('job-b')],
          clearedAtEpochMs: 0,
        ),
      ]);

      final ids = (await a.load()).map((j) => j.id).toList();
      expect(ids, containsAll(['job-a', 'job-b']));
    });

    test('a stale instance cannot resurrect jobs cleared elsewhere', () async {
      final temp = await Directory.systemTemp.createTemp('audit9_tombstone_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/job-history.json');
      final clearer = JobHistoryStore(historyFileProvider: () async => file);
      final stale = JobHistoryStore(historyFileProvider: () async => file);

      // Stale instance reads [old] and holds it; the other clears.
      await clearer.save([job('old')]);
      final staleJobs = await stale.load();
      final clearedAt = DateTime.now().millisecondsSinceEpoch;
      await clearer.save(const <TranslationJob>[], clearedAtEpochMs: clearedAt);

      final result = await stale.saveMerged(
        merge: (fileJobs, fileClearedAt) => [
          ...fileJobs,
          ...staleJobs.where((j) => true),
        ],
        clearedAtEpochMs: 0,
      );
      expect(result.written, isFalse);
      expect((await clearer.load()), isEmpty);
    });
  });

  group('Minor5: style card blur resync', () {
    testWidgets('skipped sync while editing is applied on blur', (
      tester,
    ) async {
      const strings = AppStrings(UiLanguage.english);
      final profile = ValueNotifier<TranslationStyleProfile>(
        const TranslationStyleProfile(tone: 'old tone'),
      );
      addTearDown(profile.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<TranslationStyleProfile>(
                valueListenable: profile,
                builder: (context, value, _) => TranslationStyleProfileCard(
                  strings: strings,
                  profile: value,
                  confirmed: false,
                  enabled: true,
                  editable: true,
                  isGenerating: false,
                  canGenerate: false,
                  onGenerate: () {},
                  onConfirm: () {},
                  onChanged:
                      ({
                        String? primaryGenre,
                        String? secondaryGenresCsv,
                        String? tone,
                        String? sentenceStyle,
                        String? constraintsText,
                        String? avoidText,
                        TranslationStyleConfidence? confidence,
                      }) {},
                ),
              ),
            ),
          ),
        ),
      );

      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == strings.styleProfileTone,
      );
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'user draft',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      // Book switch pushes a new profile while the field is focused+edited:
      // the sync is skipped, the draft stays visible.
      profile.value = const TranslationStyleProfile(tone: 'new tone');
      await tester.pump();
      final editable = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(editable).controller.text,
        'user draft',
      );

      // On blur the pending sync is applied; stale text cannot linger.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(tester.widget<EditableText>(editable).controller.text, 'new tone');
    });
  });

  group('Minor6: inspector progress guard', () {
    test('a throwing onProgress does not abort inspection', () async {
      final dir = await Directory.systemTemp.createTemp('audit9_inspector_');
      addTearDown(() => dir.delete(recursive: true));
      final source = await audit4.writeBook(
        dir,
        body: '<h1>Chapter One</h1><p>Hello world.</p>',
      );

      var calls = 0;
      final result = await EpubInspector().inspect(
        inputPath: source.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
        onProgress: (job, logLine) {
          calls += 1;
          throw StateError('disposed');
        },
      );

      expect(calls, greaterThan(0));
      expect(result.chapters, hasLength(1));
      expect(result.chapters.single.blocks, isNotEmpty);
    });
  });

  group('Minor7: style generation merge', () {
    test('manual tone and confidence edits survive the merge', () async {
      final repository = _BlockingStyleRepository();
      final controller = TranslationDashboardController(
        repository: repository,
        historyStore: _MemoryJobHistoryStore(),
      );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: true),
      );
      controller.setInputPath('book.epub');

      // startInspection auto-starts style-profile generation (enabled in
      // config), which blocks on profileCompleter.
      final Future<void> inspection = controller.startInspection();
      // Wait for the generation window to open.
      for (
        var i = 0;
        i < 100 && !controller.state.isGeneratingStyleProfile;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.state.isGeneratingStyleProfile, isTrue);

      controller.setStyleProfileField(
        tone: 'manual tone',
        confidence: TranslationStyleConfidence.high,
      );
      repository.profileCompleter.complete(
        const TranslationStyleProfile(
          primaryGenre: 'Generated Genre',
          tone: 'generated tone',
          confidence: TranslationStyleConfidence.low,
        ),
      );
      await inspection;

      final merged = controller.state.styleProfile;
      expect(merged.tone, 'manual tone');
      expect(merged.confidence, TranslationStyleConfidence.high);
      // Untouched fields come from the generated profile.
      expect(merged.primaryGenre, 'Generated Genre');
    });
  });

  group('Minor8: proper-name gloss spacing', () {
    const mappings = <ProperNameMap>[
      ProperNameMap(source: 'Adam Smith', target: '亚当·斯密'),
    ];

    test('empty tag between words keeps the space', () {
      final out = ProperNameNormalizer.normalizeHtml(
        '<p>这是Adam<span></span>Smith的著作。</p>',
        mappings,
        targetLanguage: 'Chinese',
      );
      expect(out, contains('亚当·斯密（Adam Smith）的著作'));
    });

    test('empty tag inside a word adds no space', () {
      final out = ProperNameNormalizer.normalizeHtml(
        '<p>这是Ad<span></span>am Smith的著作。</p>',
        mappings,
        targetLanguage: 'Chinese',
      );
      expect(out, contains('亚当·斯密（Adam Smith）的著作'));
    });
  });

  group('Minor9: chapter filename classification', () {
    const EpubHtmlExtractor extractor = EpubHtmlExtractor();

    InspectedChapter classify(String fileName) => extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/$fileName',
      bytes: utf8.encode(
        '<html><head><title>Body</title></head><body><p>Translatable body text.</p></body></html>',
      ),
    );

    test('prose words containing markers are not misclassified', () {
      expect(classify('discover.xhtml').category, ChapterCategory.content);
      expect(classify('attack.xhtml').category, ChapterCategory.content);
      expect(classify('back.xhtml').category, ChapterCategory.content);
      expect(classify('subtitle.xhtml').category, ChapterCategory.content);
    });

    test('real markers still classify', () {
      expect(classify('cover.xhtml').category, ChapterCategory.ancillary);
      expect(
        classify('acknowledgments.xhtml').category,
        ChapterCategory.backMatter,
      );
    });
  });

  group('Minor10: retry hint expiry', () {
    test(
      'a retry blocked by the style gate leaves no stale hint for the next manual inspection',
      () async {
        final repository = _SuccessfulInspectionRepository(blockCount: 2);
        repository.generatedStyleProfile = const TranslationStyleProfile(
          primaryGenre: 'Sci-Fi',
        );
        final controller = TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(
            initial: const <TranslationJob>[
              TranslationJob(
                id: 'failed-1',
                inputPath: 'book.epub',
                outputPath: 'out',
                status: TranslationJobStatus.failed,
                phase: TranslationJobPhase.translation,
                progress: 0.5,
                completedBlocks: 1,
                totalBlocks: 2,
                selectedChapterPaths: ['chapter.xhtml'],
              ),
            ],
          ),
        );
        controller.syncSettings(
          TranslationConfig.defaults().copyWith(styleProfileEnabled: true),
        );
        // The controller loads job history asynchronously on construction;
        // wait until the failed job is visible before retrying.
        for (var i = 0; i < 100; i++) {
          if (controller.state.jobHistory.any((job) => job.id == 'failed-1')) {
            break;
          }
          await Future<void>.delayed(Duration.zero);
        }

        await controller.retryJob('failed-1');
        // Style gate blocks: nothing was translated.
        expect(repository.translateCount, 0);

        // User confirms the style, then re-inspects manually.
        controller.confirmStyleProfile();
        await controller.startInspection();
        controller.confirmStyleProfile();

        final started = await controller.startTranslation();
        expect(started, isTrue);
        expect(repository.translateCount, 1);
        // The failed job's 1-block checkpoint is expired: the fresh job
        // must not carry it as a pending resume hint.
        expect(controller.state.job?.resumeCheckpointBlocks, 0);
      },
    );
  });

  group('Minor11: estimate memoization', () {
    List<InspectedChapter> chapters() => <InspectedChapter>[
      InspectedChapter(
        path: 'ch1.xhtml',
        title: 'Chapter 1',
        body: '',
        originalHtml: '',
        blocks: List<ExtractedBlock>.generate(
          3,
          (i) => ExtractedBlock(
            id: 'p-$i',
            tagName: 'p',
            sourceHtml: '<p>中文测试文本 block $i</p>',
            sourceText: '中文测试文本 block $i',
          ),
        ),
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      ),
    ];

    test('staticPart + withProgress matches fromChapters', () {
      final list = chapters();
      final full = TranslationRunEstimate.fromChapters(list, chunkSize: 2);
      final rebuilt = TranslationRunEstimate.staticPart(list, chunkSize: 2)
          .withProgress(
            completedBlocks: 0,
            totalBlocks: full.totalBlocks,
            elapsed: Duration.zero,
          );

      expect(rebuilt.totalBlocks, full.totalBlocks);
      expect(rebuilt.estimatedApiBatches, full.estimatedApiBatches);
      expect(rebuilt.estimatedSourceChars, full.estimatedSourceChars);
      expect(rebuilt.estimatedInputTokens, full.estimatedInputTokens);
    });

    test('progress ticks reuse the cached static estimate', () async {
      final repository = _SuccessfulInspectionRepository(blockCount: 2);
      final controller = TranslationDashboardController(
        repository: repository,
        historyStore: _MemoryJobHistoryStore(),
      );
      controller.syncSettings(TranslationConfig.defaults());
      controller.setInputPath('book.epub');
      await controller.startInspection();

      final first = controller.debugStaticEstimateCache;
      expect(first, isNotNull);

      // A config change that keeps chapters + chunk size must reuse the
      // cached static part (progress ticks hit this path per callback).
      controller.syncSettings(
        controller.state.config.copyWith(targetLanguage: 'Japanese'),
      );
      expect(identical(controller.debugStaticEstimateCache, first), isTrue);

      // Changing the chunk size invalidates the cache.
      controller.syncSettings(controller.state.config.copyWith(chunkSize: 7));
      expect(identical(controller.debugStaticEstimateCache, first), isFalse);
    });
  });
}

class _MemoryJobHistoryStore extends JobHistoryStore {
  _MemoryJobHistoryStore({List<TranslationJob> initial = const []})
    : _jobs = List.of(initial);

  final List<TranslationJob> _jobs;

  @override
  Future<List<TranslationJob>> load() async => List.of(_jobs);

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: List.of(_jobs), clearedAt: 0);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    _jobs
      ..clear()
      ..addAll(jobs);
  }

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    _jobs
      ..clear()
      ..addAll(merge(List.of(_jobs), 0));
    return (written: true, fileClearedAt: 0);
  }
}

class _SuccessfulInspectionRepository implements TranslationRepository {
  _SuccessfulInspectionRepository({this.blockCount = 1});

  final int blockCount;
  int translateCount = 0;
  TranslationStyleProfile generatedStyleProfile = TranslationStyleProfile.empty;

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final chapters = <InspectedChapter>[
      InspectedChapter(
        path: 'chapter.xhtml',
        title: 'Chapter',
        body: '',
        originalHtml: '',
        blocks: List<ExtractedBlock>.generate(
          blockCount,
          (index) => ExtractedBlock(
            id: 'block-$index',
            tagName: 'p',
            sourceHtml: 'short text $index',
            sourceText: 'short text $index',
          ),
        ),
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      ),
    ];
    final job = TranslationJob(
      id: 'job-1',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      progress: 1,
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: blockCount,
      totalBlocks: blockCount,
    );
    onProgress?.call(job, 'Inspection complete.');
    return InspectionResult(job: job, chapters: chapters);
  }

  @override
  Future<String> testConnection({required TranslationConfig config}) async =>
      'OK';

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async => generatedStyleProfile;

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
    final job = TranslationJob(
      id: 'translated-job',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.completed,
      phase: TranslationJobPhase.translation,
      progress: 1,
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: blockCount,
      totalBlocks: blockCount,
    );
    onProgress?.call(job, 'Translation complete.');
    return TranslationRunResult(job: job, chapters: chapters);
  }
}

class _BlockingStyleRepository extends _SuccessfulInspectionRepository {
  final Completer<TranslationStyleProfile> profileCompleter =
      Completer<TranslationStyleProfile>();

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) => profileCompleter.future;
}

class _FakeSettingsSecretStore implements SettingsSecretStore {
  @override
  Future<String?> readApiKey() async => null;

  @override
  Future<void> writeApiKey(String value) async {}

  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readDeepSeekApiKey() async => null;

  @override
  Future<void> writeDeepSeekApiKey(String value) async {}

  @override
  Future<void> deleteDeepSeekApiKey() async {}

  @override
  Future<String?> readCustomApiKey() async => null;

  @override
  Future<void> writeCustomApiKey(String value) async {}

  @override
  Future<void> deleteCustomApiKey() async {}
}
