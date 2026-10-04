import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/api_provider_preset.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_text_decoder.dart';
import 'package:html/parser.dart' as hp;
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';

InspectedChapter chapter(
  String body, {
  String path = 'OPS/chapter.xhtml',
  String title = 'Book',
}) => const EpubHtmlExtractor()
    .inspectChapterBytes(
      chapterPath: path,
      bytes: utf8.encode(
        '<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>$title</title></head><body>$body</body></html>',
      ),
    )
    .copyWith(includeInTranslation: true);

InspectedChapter translated(InspectedChapter c, List<String> markup) =>
    c.copyWith(
      blocks: [
        for (var i = 0; i < c.blocks.length; i++)
          c.blocks[i].copyWith(translatedHtml: markup[i]),
      ],
    );

class PendingInspector extends EpubInspector {
  final reply = Completer<InspectionResult>();
  @override
  Future<InspectionResult> inspect({
    required String inputPath,
    required String outputDirectory,
    required CancelToken cancelToken,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
    AppStrings? strings,
  }) => reply.future;
}

class PendingSettingsSave extends SettingsStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<TranslationConfig> load() async => TranslationConfig.defaults();
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    entered.complete();
    await release.future;
  }
}

class PendingRepository implements TranslationRepository {
  final entered = Completer<void>();
  final inspection = Completer<InspectionResult>();
  final translationEntered = Completer<void>();
  final translation = Completer<TranslationRunResult>();
  final styleEntered = Completer<void>();
  final style = Completer<TranslationStyleProfile>();
  TranslationProgressCallback? progress;
  int cancelCount = 0;
  @override
  Future<void> cancelJob(String jobId) async {
    cancelCount++;
  }

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) {
    styleEntered.complete();
    return style.future;
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
  }) {
    progress = onProgress;
    translationEntered.complete();
    return translation.future;
  }

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    progress = onProgress;
    entered.complete();
    return inspection.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingTranslator extends EpubChapterTranslator {
  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
  }) async => throw const FormatException('Real style failure');
  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    required CancelToken cancelToken,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async => throw const FormatException('Real translation failure');
}

InspectionResult inspectedResult() => InspectionResult(
  job: TranslationJob(
    id: 'inspected',
    inputPath: 'book.epub',
    outputPath: '.',
    status: TranslationJobStatus.inspected,
    progress: 1,
  ),
  chapters: [chapter('<p>Hello.</p>')],
);

class ProviderSettings extends SettingsStore {
  final writes = <TranslationConfig>[];
  @override
  Future<TranslationConfig> load() async =>
      TranslationConfig.defaults().copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiKey: 'custom-old',
        customApiKey: 'custom-old',
        deepseekApiKey: 'deepseek-old',
        apiBaseUrl: 'https://custom.example/v1',
        customApiBaseUrl: 'https://custom.example/v1',
      );
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    writes.add(config);
  }
}

void main() {
  test(
    'N4 removing a decorative span keeps the other language nodes aligned',
    () {
      final c = chapter(
        '<p><span class="dropcap">T</span>ext <em lang="en">Poison</em> / <em lang="en">Gift</em></p>',
      );
      final prepared = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
        sourceHtml: c.blocks.single.sourceHtml,
        targetLanguage: 'Chinese',
      );
      final locked = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: prepared,
        translatedHtml:
            '<p>文本 <em lang="en">毒药</em> / <em lang="en">Gift</em></p>',
      );
      final out = EpubRepacker().renderTranslatedChapter(
        chapter: translated(c, [locked]),
        bilingual: false,
      );
      final nodes = hp.parse(out).querySelectorAll('em');
      expect(nodes.first.attributes['lang'], 'zh-CN');
      expect(nodes.last.attributes['lang'], 'en');
    },
  );
  test(
    'N8 key update followed by endpoint update retains the original provider key',
    () async {
      final store = ProviderSettings();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;
      await controller.applyApiProviderPreset(ApiProviderPreset.deepseek);
      await Future.wait([
        controller.setApiKey('deepseek-new'),
        controller.setApiBaseUrl('https://other.example'),
      ]);
      expect(controller.state.deepseekApiKey, 'deepseek-new');
      expect(
        controller.state.apiProviderSelection,
        ApiProviderSelection.custom,
      );
      expect(controller.state.apiKey, 'deepseek-new');
    },
  );
  test('N6 failed pending settings save is safe after disposal', () async {
    final store = PendingSettingsSave();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    final controller = container.read(settingsProvider.notifier);
    await controller.ready;
    final update = controller.setModel('new');
    await store.entered.future;
    container.dispose();
    store.release.completeError(const FileSystemException('Write failed'));
    await update;
  });
  test(
    'N7 inspection error and progress callbacks are safe after disposal',
    () async {
      final repo = PendingRepository();
      final controller = TranslationDashboardController(repository: repo);
      controller.setInputPath('book.epub');
      controller.setOutputDirectory('.');
      final run = controller.startInspection(generateStyle: false);
      await repo.entered.future;
      controller.dispose();
      repo.progress!(inspectedResult().job, 'late progress');
      expect(repo.cancelCount, 1);
      repo.inspection.completeError(const FormatException('Failed inspection'));
      await run;
    },
  );
  for (final failure in [false, true]) {
    for (final style in [false, true]) {
      test(
        'N7 ${style ? 'style' : 'translation'} completion failure=$failure after disposal is safe',
        () async {
          final repo = PendingRepository();
          final controller = TranslationDashboardController(repository: repo);
          controller.syncSettings(
            TranslationConfig.defaults().copyWith(styleProfileEnabled: style),
          );
          controller.setInputPath('book.epub');
          controller.setOutputDirectory('.');
          final inspect = controller.startInspection(generateStyle: false);
          await repo.entered.future;
          repo.inspection.complete(inspectedResult());
          await inspect;
          final Future<dynamic> run = style
              ? controller.generateStyleProfile()
              : controller.startTranslation();
          await (style
              ? repo.styleEntered.future
              : repo.translationEntered.future);
          controller.dispose();
          expect(repo.cancelCount, 1);
          repo.progress!(inspectedResult().job, 'late progress');
          if (style) {
            if (failure) {
              repo.style.completeError(const FormatException('Failed style'));
            } else {
              repo.style.complete(TranslationStyleProfile.empty);
            }
          } else {
            if (failure) {
              repo.translation.completeError(
                const FormatException('Failed translation'),
              );
            } else {
              repo.translation.complete(
                TranslationRunResult(
                  job: inspectedResult().job.copyWith(
                    status: TranslationJobStatus.completed,
                  ),
                  chapters: inspectedResult().chapters,
                ),
              );
            }
          }
          await run;
        },
      );
    }
  }
  for (final style in [false, true]) {
    test(
      'N3 genuine ${style ? 'style' : 'translation'} error survives cancellation flag',
      () async {
        final repo = EpubTranslationRepository(translator: FailingTranslator());
        final config = TranslationConfig.defaults();
        final Future<dynamic> run = style
            ? repo.generateStyleProfile(
                config: config,
                chapters: [],
                isCancelled: () => true,
              )
            : repo.translateChapters(
                inputPath: 'book.epub',
                outputDirectory: '.',
                config: config,
                chapters: [],
                isCancelled: () => true,
              );
        await expectLater(run, throwsFormatException);
      },
    );
  }
  test(
    'N2 CJK preprocessing preserves decorative classes inside protected spans',
    () {
      const protected =
          '<code><span class="smallcaps" lang="en">API</span>中文注释</code>';
      final c = chapter('<p>Hello $protected</p>');
      final prepared = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
        sourceHtml: c.blocks.single.sourceHtml,
        targetLanguage: 'Chinese',
      );
      expect(
        hp.parseFragment(prepared).querySelector('code')!.innerHtml,
        hp.parseFragment(protected).querySelector('code')!.innerHtml,
      );
      final locked = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: prepared,
        translatedHtml: '<p>你好 $protected</p>',
      );
      final out = EpubRepacker().renderTranslatedChapter(
        chapter: translated(c, [locked]),
        bilingual: false,
      );
      expect(
        hp.parse(out).querySelector('code')!.innerHtml,
        hp.parseFragment(protected).querySelector('code')!.innerHtml,
      );
    },
  );
  testWidgets('N8 immediate provider chip tap keeps the pending custom key', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    NativePlatformBridge.debugWindowsProcessStarter = (_, _) async =>
        throw UnsupportedError('No real process during audit');
    addTearDown(() => NativePlatformBridge.debugWindowsProcessStarter = null);
    final store = ProviderSettings();
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        translationDashboardProvider.overrideWith(
          (ref) =>
              TranslationDashboardController(repository: PendingRepository()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ready;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-api-key')),
      'custom-new',
    );
    await tester.tap(find.byKey(const ValueKey('api-provider-deepseek')));
    await tester.pumpAndSettle();
    final config = container.read(settingsProvider);
    expect(config.customApiKey, 'custom-new');
    expect(config.apiKey, 'deepseek-old');
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'N8 key blur followed by provider selection preserves separate keys',
    () async {
      final store = ProviderSettings();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;
      await Future.wait([
        controller.setApiKey('custom-new'),
        controller.applyApiProviderPreset(ApiProviderPreset.deepseek),
      ]);
      expect(
        controller.state.apiProviderSelection,
        ApiProviderSelection.deepseek,
      );
      expect(controller.state.apiKey, 'deepseek-old');
      expect(controller.state.customApiKey, 'custom-new');
      expect(controller.state.deepseekApiKey, 'deepseek-old');
    },
  );
  test(
    'N7 dashboard inspection completion safely ignores disposed controller',
    () async {
      final repo = PendingRepository();
      final controller = TranslationDashboardController(repository: repo);
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath('book.epub');
      controller.setOutputDirectory('.');
      final run = controller.startInspection(generateStyle: false);
      await repo.entered.future;
      controller.dispose();
      repo.inspection.complete(
        InspectionResult(
          job: TranslationJob(
            id: 'done',
            inputPath: 'book.epub',
            outputPath: '.',
            status: TranslationJobStatus.inspected,
            progress: 1,
          ),
          chapters: [chapter('<p>Hello.</p>')],
        ),
      );
      await run;
    },
  );
  for (final tricky in [false, true]) {
    test(
      '${tricky ? 'N1' : 'control'} actual EPUB legacy TOC export, tricky CDATA=$tricky',
      () async {
        final dir = await Directory.systemTemp.createTemp('deep2-toc-');
        addTearDown(() => dir.delete(recursive: true));
        final source =
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title><script><![CDATA[var sample = "${tricky ? '</script><p>sample</p>' : 'ordinary'}";]]></script></head><body><p><a href="chapter.xhtml">Chapter One</a></p></body></html>';
        final toc = const EpubHtmlExtractor()
            .inspectChapterBytes(
              chapterPath: 'OPS/toc.xhtml',
              bytes: utf8.encode(source),
            )
            .copyWith(includeInTranslation: true);
        final body = translated(chapter('<h1>Chapter One</h1>'), [
          '<h1>第一章</h1>',
        ]);
        final files = {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
          'OPS/content.opf':
              '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">test</dc:identifier><dc:title>Test</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-03T00:00:00Z</meta></metadata><manifest><item id="toc" href="toc.xhtml" media-type="application/xhtml+xml" properties="scripted"/><item id="body" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="toc"/><itemref idref="body"/></spine></package>',
          'OPS/nav.xhtml':
              '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Navigation</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter One</a></li></ol></nav></body></html>',
          'OPS/toc.xhtml': source,
          'OPS/chapter.xhtml': body.originalHtml,
        };
        final archive = Archive();
        for (final entry in files.entries) {
          final bytes = utf8.encode(entry.value);
          archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
        }
        final input = File('${dir.path}/input.epub');
        await input.writeAsBytes(ZipEncoder().encode(archive));
        final output = File('${dir.path}/output.epub');
        await EpubRepacker().writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          config: TranslationConfig.defaults().copyWith(bilingual: false),
          chapters: [toc, body],
        );
        final result = ZipDecoder().decodeBytes(await output.readAsBytes());
        final out = XmlDocument.parse(
          utf8.decode(result.findFile('OPS/toc.xhtml')!.content),
        );
        expect(
          out.findAllElements('script').single.innerText,
          XmlDocument.parse(source).findAllElements('script').single.innerText,
        );
        expect(out.findAllElements('a').single.innerText, '第一章');
      },
    );
  }
  for (final head in [
    '<!-- Example declaration: <?xml version="1.0" encoding="GBK"?> -->',
    '<script><![CDATA[var sample = "</script><meta charset=GBK>";]]></script>',
    '<!-- <meta charset="GBK"> ${'x' * 8300} -->',
  ]) {
    test('N5 charset sniffer ignores inert markup ${head.substring(0, 20)}', () {
      final source =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Book</title>$head</head><body><p>Hello world.</p></body></html>';
      XmlDocument.parse(source);
      final result = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/chapter.xhtml',
        bytes: utf8.encode(source),
      );
      expect(result.blocks.map((b) => b.sourceText), ['Hello world.']);
    });
  }
  test('control: genuine unsupported charset is still rejected', () {
    expect(
      () => decodeEpubText(
        bytes: utf8.encode('<?xml version="1.0" encoding="GBK"?><x/>'),
        filePath: 'chapter.xhtml',
      ),
      throwsFormatException,
    );
  });
  test(
    'N6 successful pending settings save can finish after container disposal',
    () async {
      final store = PendingSettingsSave();
      final container = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      final controller = container.read(settingsProvider.notifier);
      await controller.ready;
      final update = controller.setModel('new-model');
      await store.entered.future;
      container.dispose();
      store.release.complete();
      await update;
    },
  );
  test('control: repaired first render preserves script CDATA', () {
    const source =
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title><script><![CDATA[var text = "</script><p>example</p>";]]></script></head><body><p>Hello.</p></body></html>';
    final c = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/toc.xhtml',
      bytes: utf8.encode(source),
    );
    final out = EpubRepacker().renderTranslatedChapter(
      chapter: c,
      bilingual: false,
    );
    expect(
      XmlDocument.parse(out).findAllElements('script').single.innerText,
      XmlDocument.parse(source).findAllElements('script').single.innerText,
    );
  });
  test('N1 legacy TOC synchronization preserves valid script CDATA', () {
    const source =
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title><script><![CDATA[var text = "</script><p>example</p>";]]></script></head><body><p><a href="chapter.xhtml">Chapter One</a></p></body></html>';
    final toc = const EpubHtmlExtractor()
        .inspectChapterBytes(
          chapterPath: 'OPS/toc.xhtml',
          bytes: utf8.encode(source),
        )
        .copyWith(includeInTranslation: true);
    final body = translated(chapter('<h1>Chapter One</h1>'), ['<h1>第一章</h1>']);
    final repacker = EpubRepacker();
    final rendered = repacker.renderTranslatedChapter(
      chapter: toc,
      bilingual: false,
    );
    final out = repacker.synchronizeHtmlTocForTest(
      tocPath: toc.path,
      tocHtml: rendered,
      chapters: [toc, body],
    );
    final parsed = XmlDocument.parse(out);
    expect(
      parsed.findAllElements('script').single.innerText,
      XmlDocument.parse(source).findAllElements('script').single.innerText,
    );
    expect(parsed.findAllElements('a').single.innerText, '第一章');
  });
  for (final protected in [
    '<code><b class="dropcap">A</b>中文注释</code>',
    '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi class="dropcap">A</mi><mtext>中文注释</mtext></math>',
  ]) {
    final tag = protected.startsWith('<code>') ? 'code' : 'math';
    test('N2 CJK cleanup preserves protected $tag content', () {
      final c = chapter('<p>Hello world. $protected</p>');
      expect(c.blocks.length, 1);
      final prepared = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
        sourceHtml: c.blocks.single.sourceHtml,
        targetLanguage: 'Chinese',
      );
      final locked = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: prepared,
        translatedHtml: '<p>你好世界。 $protected</p>',
      );
      final out = EpubRepacker().renderTranslatedChapter(
        chapter: translated(c, [locked]),
        bilingual: false,
      );
      expect(hp.parse(out).querySelector(tag)!.text, 'A中文注释');
    });
  }
  test(
    'N3 format error remains observable when cancellation races it',
    () async {
      final inspector = PendingInspector();
      final repository = EpubTranslationRepository(inspector: inspector);
      var cancelled = false;
      final run = repository.startJob(
        inputPath: 'broken.epub',
        outputDirectory: '.',
        config: TranslationConfig.defaults(),
        isCancelled: () => cancelled,
      );
      final assertion = expectLater(run, throwsA(isA<FormatException>()));
      cancelled = true;
      inspector.reply.completeError(const FormatException('EPUB invalid XML'));
      await assertion;
    },
  );
  test(
    'N4 language marking follows corresponding node, not equal text elsewhere',
    () {
      final c = chapter(
        '<p><em lang="en">Poison</em> / <em lang="en">Gift</em></p>',
      );
      final locked = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: c.blocks.single.sourceHtml,
        translatedHtml:
            '<p><em lang="en">Gift</em> / <em lang="en">Gift</em></p>',
      );
      final out = EpubRepacker().renderTranslatedChapter(
        chapter: translated(c, [locked]),
        bilingual: false,
        targetLanguage: 'German',
      );
      final nodes = hp.parse(out).querySelectorAll('em');
      expect(nodes.first.attributes['lang'], 'de');
      expect(nodes.last.attributes['lang'], 'en');
    },
  );
}
