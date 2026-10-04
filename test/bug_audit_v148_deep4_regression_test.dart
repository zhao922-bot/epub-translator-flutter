import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/features/settings/presentation/widgets/settings_fields.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:html/parser.dart' as hp;
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'bug_audit_v148_deep2_regression_test.dart'
    show chapter, PendingRepository, ProviderSettings;
import 'bug_audit_v148_deep3_regression_test.dart'
    show FailingSaveSettings, historyJob, History;
import 'bug_audit_round4_regression_test.dart' show writeBook;

class BlockingSave extends ProviderSettings {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool blocked = false;
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    if (!blocked) {
      blocked = true;
      entered.complete();
      await release.future;
    }
    await super.save(config, explicitSecretMutations: explicitSecretMutations);
  }
}

class DeferredHistory extends JobHistoryStore {
  DeferredHistory(File file) : super(historyFileProvider: () async => file);
  final loadRelease = Completer<void>();
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async {
    await loadRelease.future;
    return super.loadWithTombstone();
  }
}

class ConflictingHistory extends History {
  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    writes++;
    return (written: false, fileClearedAt: clearedAtEpochMs + 1);
  }
}

void additionalRegressionTests() {
  test(
    'E3 persistent clear conflicts report failure after bounded retries',
    () async {
      final history = ConflictingHistory()
        ..loaded.complete((jobs: [historyJob], clearedAt: 0));
      final controller = TranslationDashboardController(
        repository: PendingRepository(),
        historyStore: history,
      );
      addTearDown(controller.dispose);
      expect(await controller.clearJobHistory(), false);
      expect(history.writes, 3);
      expect(
        controller.state.logs.join('\n'),
        contains(AppStrings(UiLanguage.english).logClearHistoryFailed),
      );
    },
  );

  test(
    'E5 disposal while history loads prevents launching input picker',
    () async {
      final history = History();
      var picks = 0;
      final controller = TranslationDashboardController(
        repository: PendingRepository(),
        historyStore: history,
        epubPickerOverride: ({onWindowsNotice}) async {
          picks++;
          return 'book.epub';
        },
      );
      final picking = controller.pickInputPath();
      controller.dispose();
      history.loaded.complete((jobs: <TranslationJob>[], clearedAt: 0));
      await picking;
      expect(picks, 0);
    },
  );

  test('E5 late Windows picker notice is safe after disposal', () async {
    final entered = Completer<void>();
    final reply = Completer<String?>();
    void Function(WindowsPathNotice)? notice;
    final controller = TranslationDashboardController(
      repository: PendingRepository(),
      directoryPickerOverride: ({onWindowsNotice}) {
        notice = onWindowsNotice;
        entered.complete();
        return reply.future;
      },
    );
    final picking = controller.pickOutputDirectory();
    await entered.future;
    controller.dispose();
    expect(() => notice!(WindowsPathNotice.dialogOpened), returnsNormally);
    reply.complete('out');
    await picking;
  });

  test('E5 disposal during input output-directory resolution is safe', () async {
    final entered = Completer<void>();
    final reply = Completer<String>();
    final controller = TranslationDashboardController(
      repository: PendingRepository(),
      epubPickerOverride: ({onWindowsNotice}) =>
          Future<String?>.value('book.epub'),
      defaultOutputDirectoryResolver: (_) {
        entered.complete();
        return reply.future;
      },
    );
    final picking = controller.pickInputPath();
    await Future.any([
      entered.future,
      picking.then((_) {
        if (!entered.isCompleted) {
          fail(
            'Picker ended before resolving directory: ${controller.state.logs}',
          );
        }
      }),
    ]);
    controller.dispose();
    reply.complete('out');
    await picking;
  });

  test(
    'E5 late directory selection cannot change paths during inspection',
    () async {
      final entered = Completer<void>();
      final reply = Completer<String?>();
      final repository = PendingRepository();
      final controller = TranslationDashboardController(
        repository: repository,
        directoryPickerOverride: ({onWindowsNotice}) {
          entered.complete();
          return reply.future;
        },
      );
      controller.setInputPath('book.epub');
      controller.setOutputDirectory('original-output');
      final picking = controller.pickOutputDirectory();
      await entered.future;
      final inspection = controller.startInspection(generateStyle: false);
      await repository.entered.future;
      reply.complete('late-output');
      await picking;
      expect(controller.state.outputDirectory, 'original-output');
      controller.dispose();
      repository.inspection.completeError(
        const FormatException('test stopped'),
      );
      await inspection;
    },
  );

  for (final source in [
    'Adam<span id="between" name="anchor"></span> Smith',
    'Ad<span id="between" name="anchor"></span>am Smith',
  ]) {
    test('E6 first and later names preserve empty markup in $source', () {
      final state = ProperNameNormalizer.bookState();
      final mappings = ProperNameNormalizer.parseGlossary(
        'Adam Smith => 亚当·斯密',
      );
      for (var occurrence = 0; occurrence < 2; occurrence++) {
        final result = ProperNameNormalizer.normalizeHtml(
          '<p>$source 走进房间。</p>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        final document = hp.parseFragment(result);
        final marker = document.querySelector('#between');
        expect(marker, isNotNull);
        expect(marker!.attributes['name'], 'anchor');
        expect(marker.text, isEmpty);
        expect(document.text, contains('亚当·斯密'));
        expect(document.text!.contains('（Adam Smith）'), occurrence == 0);
        XmlDocument.parse(result);
      }
    });
  }

  test('E6 opaque nested markup retains its marker and original name', () {
    const source =
        '<p>Adam<span id="between" name="anchor"><i></i></span> Smith 走进房间。</p>';
    final result = ProperNameNormalizer.normalizeHtml(
      source,
      ProperNameNormalizer.parseGlossary('Adam Smith => 亚当·斯密'),
      targetLanguage: 'Chinese',
    );
    expect(result, source);
    expect(
      hp.parseFragment(result).querySelector('#between')!.attributes['name'],
      'anchor',
    );
    XmlDocument.parse(result);
  });

  for (final marker in [
    '<span id="page" lang="en" role="presentation doc-pagebreak">12</span>',
    '<span id="page" lang="en" xmlns:ops="http://www.idpf.org/2007/ops" ops:type="pagebreak">12</span>',
    '<span id="page" lang="en" epub:type="pagebreak">12</span>',
    '<span id="page" lang="en" class="pagenum">12</span>',
  ]) {
    for (final legacy in [true, false]) {
      test(
        'E7/E8 ${legacy ? "legacy" : "EPUB3"} TOC preserves page before label: $marker',
        () {
          final link =
              '<a href="chapter.xhtml#ch1">$marker<span lang="en" xml:lang="en">First chapter</span></a>';
          final original =
              '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en"><body>${legacy ? '<p>$link</p>' : '<nav epub:type="toc"><ol><li>$link</li></ol></nav>'}</body></html>';
          final content = chapter('<h1 id="ch1">First chapter</h1>').copyWith(
            blocks: [
              chapter(
                '<h1 id="ch1">First chapter</h1>',
              ).blocks.single.copyWith(translatedHtml: '<h1 id="ch1">第一章</h1>'),
            ],
          );
          final toc = chapter(
            '',
            path: 'OPS/toc.xhtml',
            title: 'Contents',
          ).copyWith(originalHtml: original, includeInTranslation: false);
          final result = legacy
              ? EpubRepacker().synchronizeHtmlTocForTest(
                  tocPath: toc.path,
                  tocHtml: original,
                  chapters: [toc, content],
                )
              : synchronizeEpub3Navigation(
                  markup: original,
                  documentPath: 'OPS/nav.xhtml',
                  labelsByPath: {'OPS/chapter.xhtml#ch1': '第一章'},
                  languageTag: 'zh-CN',
                );
          final document = hp.parse(result);
          expect(document.querySelector('#page')!.text, '12');
          expect(document.querySelector('#page')!.attributes['lang'], 'en');
          final label = document.querySelector('a > span:last-child')!;
          expect(label.text, '第一章');
          expect(label.attributes['lang'], 'zh-CN');
          expect(label.attributes['xml:lang'], 'zh-CN');
          XmlDocument.parse(result);
        },
      );
    }
  }

  test('E7 unknown target language keeps existing language metadata', () {
    final source = chapter('<h1 id="ch1">First chapter</h1>');
    final content = source.copyWith(
      blocks: [
        source.blocks.single.copyWith(
          translatedHtml: '<h1 id="ch1">Translated</h1>',
        ),
      ],
    );
    const original =
        '<html xmlns="http://www.w3.org/1999/xhtml"><body><p><a href="chapter.xhtml#ch1"><span lang="en">First chapter</span></a></p></body></html>';
    final toc = chapter(
      '',
      path: 'OPS/toc.xhtml',
      title: 'Contents',
    ).copyWith(originalHtml: original, includeInTranslation: false);
    final result = EpubRepacker().synchronizeHtmlTocForTest(
      tocPath: toc.path,
      tocHtml: original,
      chapters: [toc, content],
      targetLanguage: 'Unknown target',
    );
    final label = hp.parse(result).querySelector('a span')!;
    expect(label.text, 'Translated');
    expect(label.attributes['lang'], 'en');
  });

  test(
    'E7 actual EPUB export updates excluded legacy TOC and preserves page',
    () async {
      final dir = await Directory.systemTemp.createTemp('deep4_toc_');
      addTearDown(() => dir.delete(recursive: true));
      final file = await writeBook(
        dir,
        body: '<h1 id="ch1">First chapter</h1>',
      );
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      archive.addFile(
        ArchiveFile.string(
          'OPS/toc.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><p><a href="chapter.xhtml#ch1"><span lang="en" xml:lang="en">First chapter</span><span id="page" epub:type="pagebreak">12</span></a></p></body></html>',
        ),
      );
      archive.addFile(
        ArchiveFile.string(
          'OPS/content.opf',
          '<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:language>en</dc:language></metadata><manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="toc" href="toc.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="toc"/><itemref idref="ch"/></spine></package>',
        ),
      );
      await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final inspected = await EpubInspector().inspect(
        inputPath: file.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      final toc = inspected.chapters
          .singleWhere((c) => c.path == 'OPS/toc.xhtml')
          .copyWith(includeInTranslation: false);
      final source = inspected.chapters.singleWhere(
        (c) => c.path == 'OPS/chapter.xhtml',
      );
      final content = source.copyWith(
        blocks: [
          source.blocks.single.copyWith(
            translatedHtml: '<h1 id="ch1">第一章</h1>',
          ),
        ],
      );
      final output = '${dir.path}/translated.epub';
      await EpubRepacker().writeTranslatedEpub(
        inputPath: file.path,
        outputFilePath: output,
        config: TranslationConfig.defaults(),
        chapters: [toc, content],
      );
      final exported = ZipDecoder().decodeBytes(
        await File(output).readAsBytes(),
      );
      final markup = utf8.decode(exported.findFile('OPS/toc.xhtml')!.content);
      final document = hp.parse(markup);
      expect(document.querySelector('a > span')!.text, '第一章');
      expect(document.querySelector('a > span')!.attributes['lang'], 'zh-CN');
      expect(document.querySelector('#page')!.text, '12');
      XmlDocument.parse(markup);
    },
  );

  for (final reason in [null, 'stop']) {
    test(
      'E4 complete legacy response finish_reason=$reason remains compatible',
      () {
        final response = {
          'choices': [
            {
              'finish_reason': reason,
              'message': {'content': 'Complete text'},
            },
          ],
        };
        expect(
          const TranslationApiClient().extractMessageContent(response),
          'Complete text',
        );
        if (reason == null) {
          (response['choices']!.single as Map).remove('finish_reason');
          expect(
            const TranslationApiClient().extractMessageContent(response),
            'Complete text',
          );
        }
      },
    );
  }

  Dio interruptedDio(String reason, String content) {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/v1'));
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'choices': [
                  {
                    'finish_reason': reason,
                    'message': {'content': content},
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    return dio;
  }

  test(
    'E4 interrupted protected-slot response restores source and note marker',
    () async {
      final source = chapter(
        '<p>Before <a role="doc-noteref" href="#n1">1</a> after.</p>',
      );
      final translator = EpubChapterTranslator();
      final result = await translator.translateBlockBatchForTest(
        dio: interruptedDio('length', '半句'),
        config: TranslationConfig.defaults().copyWith(maxRetries: 1),
        blocks: source.blocks,
      );
      expect(result.single, source.blocks.single.sourceHtml);
      expect(translator.getDegradedBlockIdsForTest(), isNotEmpty);
      expect(hp.parseFragment(result.single).querySelector('a')!.text, '1');
    },
  );

  test(
    'E4 interrupted valid style JSON must not become an accepted profile',
    () async {
      await expectLater(
        EpubChapterTranslator().generateStyleProfileForTest(
          dio: interruptedDio('aborted', '{"primaryGenre":"novel"}'),
          config: TranslationConfig.defaults().copyWith(maxRetries: 1),
          chapters: [chapter('<p>A quiet morning in the village.</p>')],
        ),
        throwsA(isA<TranslationParseException>()),
      );
    },
  );
}

void main() {
  additionalRegressionTests();
  test('Control EPUB3 TOC preserves class-marked page number', () {
    final result = synchronizeEpub3Navigation(
      markup:
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#ch1"><span>First chapter</span><span class="pagenum" id="p12">12</span></a></li></ol></nav></body></html>',
      documentPath: 'OPS/nav.xhtml',
      labelsByPath: {'OPS/chapter.xhtml#ch1': '第一章'},
      languageTag: 'zh-CN',
    );
    expect(hp.parse(result).querySelector('#p12')!.text, '12');
  });
  for (final filename in [
    'chapter#1.xhtml',
    'chapter;1.xhtml',
    'chapter+1.xhtml',
    'chapter 1.xhtml',
  ]) {
    test(
      'Control encoded manifest filename $filename resolves to the actual ZIP entry',
      () async {
        final dir = await Directory.systemTemp.createTemp('audit4_uri_');
        addTearDown(() => dir.delete(recursive: true));
        final file = await writeBook(dir, chapterName: filename);
        final inspection = await EpubInspector().inspect(
          inputPath: file.path,
          outputDirectory: dir.path,
          cancelToken: CancelToken(),
        );
        expect(
          inspection.chapters.map((c) => c.path),
          ['OPS/$filename'],
          reason: inspection.warnings.toString(),
        );
      },
    );
  }
  for (final input in [false, true]) {
    for (final fails in [false, true]) {
      test(
        'E5 picker input=$input fails=$fails must be safe after controller disposal',
        () async {
          final entered = Completer<void>();
          final reply = Completer<String?>();
          Future<String?> pick({
            void Function(WindowsPathNotice)? onWindowsNotice,
          }) {
            entered.complete();
            return reply.future;
          }

          final controller = TranslationDashboardController(
            repository: PendingRepository(),
            epubPickerOverride: pick,
            directoryPickerOverride: pick,
            defaultOutputDirectoryResolver: (_) async => 'out',
          );
          final action = input
              ? controller.pickInputPath()
              : controller.pickOutputDirectory();
          final assertion = expectLater(action, completes);
          await entered.future;
          controller.dispose();
          if (fails) {
            reply.completeError(StateError('picker error'));
          } else {
            reply.complete(input ? 'chosen.epub' : 'chosen-output');
          }
          await assertion;
        },
      );
    }
  }
  for (final markerTag in ['a', 'span']) {
    for (final bilingual in [false, true]) {
      test(
        'E6 name normalization keeps source $markerTag marker bilingual=$bilingual',
        () {
          final c = chapter(
            '<p>Adam<$markerTag id="namepoint"></$markerTag> Smith entered the room.</p>',
          );
          final translation =
              '<p>Adam<$markerTag id="namepoint"></$markerTag> Smith 进入房间。</p>';
          final locked = EpubChapterTranslator.lockHtmlStructureForTest(
            sourceHtml: c.blocks.single.sourceHtml,
            translatedHtml: translation,
          );
          expect(
            hp.parseFragment(locked).querySelector('#namepoint'),
            isNotNull,
          );
          final translated = c.copyWith(
            blocks: [c.blocks.single.copyWith(translatedHtml: locked)],
          );
          final html = EpubRepacker().renderTranslatedChapter(
            chapter: translated,
            bilingual: bilingual,
            lockedGlossary: 'Adam Smith => 亚当·斯密',
          );
          final withoutGlossary = EpubRepacker().renderTranslatedChapter(
            chapter: translated,
            bilingual: bilingual,
          );
          expect(
            hp.parse(withoutGlossary).body!.querySelectorAll(markerTag).length,
            bilingual ? 2 : 1,
          );
          final anchors = hp.parse(html).querySelectorAll('#namepoint');
          // Bilingual rendering intentionally removes duplicate IDs; count
          // elements rather than requiring duplicate IDs in that mode.
          if (!bilingual) {
            expect(anchors.length, 1, reason: html);
          } else {
            expect(
              hp.parse(html).body!.querySelectorAll(markerTag).length,
              2,
              reason: html,
            );
          }
        },
      );
    }
  }
  test('E7 legacy TOC replacement label carries target language', () {
    final content = chapter('<h1 id="ch1">First chapter</h1>');
    final translated = content.copyWith(
      blocks: [
        content.blocks.single.copyWith(translatedHtml: '<h1 id="ch1">第一章</h1>'),
      ],
    );
    final toc = chapter(
      '<p><a href="chapter.xhtml#ch1"><span lang="en" xml:lang="en">First chapter</span></a></p>',
      path: 'OPS/toc.xhtml',
      title: 'Contents',
    ).copyWith(includeInTranslation: false);
    final result = EpubRepacker().synchronizeHtmlTocForTest(
      tocPath: toc.path,
      tocHtml: toc.originalHtml,
      chapters: [toc, translated],
    );
    final label = hp.parse(result).querySelector('a span')!;
    expect(label.text, '第一章');
    expect(label.attributes['lang'], 'zh-CN', reason: result);
  });
  for (final prefix in ['epub', 'ops']) {
    test('E8 EPUB3 TOC synchronization preserves $prefix pagebreak text', () {
      final result = synchronizeEpub3Navigation(
        markup:
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:$prefix="http://www.idpf.org/2007/ops"><body><nav $prefix:type="toc"><ol><li><a href="chapter.xhtml#ch1"><span>First chapter</span><span $prefix:type="pagebreak" id="p12">12</span></a></li></ol></nav></body></html>',
        documentPath: 'OPS/nav.xhtml',
        labelsByPath: {'OPS/chapter.xhtml#ch1': '第一章'},
        languageTag: 'zh-CN',
      );
      final doc = hp.parse(result);
      expect(doc.querySelector('#p12')!.text, '12', reason: result);
    });
  }
  testWidgets(
    'E1 provider switch locks editing, saves the current key and then unlocks',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      NativePlatformBridge.debugWindowsProcessStarter = (_, _) async =>
          throw UnsupportedError('audit');
      addTearDown(() => NativePlatformBridge.debugWindowsProcessStarter = null);
      final store = BlockingSave();
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
      final keyField = find.byKey(const ValueKey('settings-api-key'));
      await tester.enterText(keyField, 'newest-key');
      await tester.tap(find.byKey(const ValueKey('api-provider-deepseek')));
      await tester.pump();
      expect(store.entered.isCompleted, true);
      for (final fieldKey in [
        'settings-api-key',
        'settings-api-base-url',
        'settings-model',
        'settings-http-proxy',
      ]) {
        expect(
          tester
              .widget<TextField>(
                find.descendant(
                  of: find.byKey(ValueKey(fieldKey)),
                  matching: find.byType(TextField),
                ),
              )
              .readOnly,
          true,
        );
      }
      store.release.complete();
      await tester.pumpAndSettle();
      final config = container.read(settingsProvider);
      expect(config.customApiKey, 'newest-key');
      expect(config.deepseekApiKey, 'deepseek-old');
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: keyField, matching: find.byType(TextField)),
            )
            .readOnly,
        false,
      );
      await tester.enterText(keyField, 'new-deepseek-key');
      final field = tester.state<SettingsTextFieldState>(
        find.ancestor(of: keyField, matching: find.byType(SettingsTextField)),
      );
      expect(await field.commitPending(), true);
      expect(
        container.read(settingsProvider).deepseekApiKey,
        'new-deepseek-key',
      );
      expect(container.read(settingsProvider).customApiKey, 'newest-key');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('E2 temporarily disabled failed save must remain retryable', (
    tester,
  ) async {
    final store = FailingSaveSettings();
    final controller = SettingsController(store);
    addTearDown(controller.dispose);
    await controller.ready;
    final key = GlobalKey<SettingsTextFieldState>();
    Widget field(bool enabled) => MaterialApp(
      home: Scaffold(
        body: SettingsTextField(
          key: key,
          fieldKey: const ValueKey('key'),
          value: controller.state.apiKey,
          onChanged: controller.setApiKey,
          onCommit: controller.setApiKey,
          decoration: const InputDecoration(),
          strings: AppStrings(UiLanguage.english),
          enabled: enabled,
        ),
      ),
    );
    await tester.pumpWidget(field(true));
    await tester.enterText(find.byType(TextFormField), 'new-key');
    expect(await key.currentState!.commitPending(), false);
    await tester.pumpWidget(field(false));
    store.failing = false;
    await tester.pumpWidget(field(true));
    expect(await key.currentState!.commitPending(), true);
    final writes = store.writes;
    await tester.pumpWidget(const SizedBox());
    expect(writes, 2);
  });

  test(
    'E3 clear must remove rows when a peer file tombstone is ahead of local state',
    () async {
      final dir = await Directory.systemTemp.createTemp('audit4_history_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/history.json');
      final futureClear = DateTime.now()
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'clearedAt': 0,
          'jobs': [historyJob.toJson()],
        }),
      );
      final store = DeferredHistory(file);
      final controller = TranslationDashboardController(
        repository: PendingRepository(),
        historyStore: store,
      );
      final visible = Completer<void>();
      final remove = controller.addListener((state) {
        if (state.jobHistory.isNotEmpty && !visible.isCompleted) {
          visible.complete();
        }
      });
      store.loadRelease.complete();
      await visible.future;
      remove();
      // The clear action is now visible in the real JobsPage. A peer writes
      // after this instance loaded; a wall-clock adjustment can leave its
      // tombstone ahead of our current time.
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'clearedAt': futureClear,
          'jobs': [
            historyJob
                .copyWith(id: 'peer-new', inputPath: 'peer.epub')
                .toJson(),
          ],
        }),
      );
      final cleared = await controller.clearJobHistory();
      controller.dispose();
      expect(cleared, true);
      final rows =
          (jsonDecode(await file.readAsString()) as Map)['jobs'] as List;
      expect(rows, isEmpty);
    },
  );

  for (final reason in [
    'stop',
    'length',
    'content_filter',
    'insufficient_system_resource',
    'aborted',
  ]) {
    test(
      reason == 'stop'
          ? 'Control natural-stop response is accepted'
          : 'E4 incomplete completion $reason must not become a successful block',
      () async {
        final c = chapter(
          '<p>The door opened. A man came inside and put the letter on the desk.</p>',
        );
        final block = c.blocks.single;
        const incomplete = '<p>门开了。</p>';
        final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/v1'));
        addTearDown(() => dio.close(force: true));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'choices': [
                      {
                        'finish_reason': reason,
                        'message': {
                          'content': jsonEncode({
                            'blocks': [
                              {'id': block.id, 'html': incomplete},
                            ],
                          }),
                        },
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
        final translator = EpubChapterTranslator();
        final result = await translator.translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(maxRetries: 1),
          blocks: [block],
        );
        if (reason == 'stop') {
          expect(result.single, incomplete);
        } else {
          expect(
            result.single,
            isNot(incomplete),
            reason:
                'Provider status=$reason, degraded blocks=${translator.getDegradedBlockIdsForTest()}. Incomplete output must not be accepted as successful.',
          );
          expect(translator.getDegradedBlockIdsForTest(), isNotEmpty);
          expect(result.single, block.sourceHtml);
        }
      },
    );
  }
}
