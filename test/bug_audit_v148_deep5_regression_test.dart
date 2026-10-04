import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as hp;
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/settings/application/connection_diagnostic.dart';
import 'package:epub_translator_flutter/shared/widgets/app_shell.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/protected_anchor_text_slots.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/api_provider_preset.dart';
import 'bug_audit_v148_deep2_regression_test.dart'
    show chapter, translated, PendingRepository;
import 'bug_audit_round4_regression_test.dart' show writeBook;
import 'package:epub_translator_flutter/features/preview/presentation/pages/preview_page.dart';

class SharedSecrets implements SettingsSecretStore {
  String? legacy = 'key-old';
  String? custom = 'key-old';
  String? deep = 'deep-old';
  int mutations = 0;
  @override
  Future<String?> readApiKey() async => legacy;
  @override
  Future<String?> readCustomApiKey() async => custom;
  @override
  Future<String?> readDeepSeekApiKey() async => deep;
  @override
  Future<void> writeApiKey(String value) async {
    mutations++;
    legacy = value;
  }

  @override
  Future<void> writeCustomApiKey(String value) async {
    mutations++;
    custom = value;
  }

  @override
  Future<void> writeDeepSeekApiKey(String value) async {
    mutations++;
    deep = value;
  }

  @override
  Future<void> deleteApiKey() async {
    mutations++;
    legacy = null;
  }

  @override
  Future<void> deleteCustomApiKey() async {
    mutations++;
    custom = null;
  }

  @override
  Future<void> deleteDeepSeekApiKey() async {
    mutations++;
    deep = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Control ordinary prose extraction preserves one block', () {
    expect(chapter('<p>The room was quiet.</p>').blocks, hasLength(1));
  });
  for (final marker in [
    '<span id="page" epub:type="pagebreak">12</span>',
    '<span id="page" role="doc-pagebreak">12</span>',
    '<a role="doc-noteref" href="#n1">1</a>',
  ]) {
    test(
      'Control bare protected marker must not create a billed block: $marker',
      () {
        final c = chapter('$marker<p>The room was quiet.</p>');
        expect(c.blocks.map((b) => b.sourceText), ['The room was quiet.']);
      },
    );
  }
  for (final marker in [
    '<span id="marker" epub:type="pagebreak">12</span>',
    '<span id="marker" role="doc-pagebreak">12</span>',
    '<span id="marker" epub:type="noteref">12</span>',
    '<span id="marker" role="doc-noteref">12</span>',
    '<span id="marker" role="doc-backlink">12</span>',
    '<span id="marker" epub:type="backlink">12</span>',
    '<span xmlns:ops="http://www.idpf.org/2007/ops" id="marker" ops:type="pagebreak">12</span>',
  ]) {
    test(
      'F1 protected slot rendering keeps source-owned span marker: $marker',
      () async {
        final c = chapter(
          '<p>Before $marker <a role="doc-noteref" href="#n1">1</a> after.</p>',
        );
        final template = ProtectedAnchorTextSlots.parse(
          c.blocks.single.sourceHtml,
        );
        expect(template.hasProtectedAnchors, true);
        final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/v1'));
        addTearDown(() => dio.close(force: true));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final request = options.data as Map;
              final payload =
                  jsonDecode(
                        (request['messages'] as List).last['content'] as String,
                      )
                      as Map;
              final blocks = (payload['blocks'] as List)
                  .map(
                    (dynamic block) => {
                      'id': block['id'],
                      'slots': (block['slots'] as List)
                          .map(
                            (dynamic slot) => {
                              'id': slot['id'],
                              'text': (slot['text'] as String).trim() == '12'
                                  ? '一二'
                                  : '译文',
                            },
                          )
                          .toList(),
                    },
                  )
                  .toList();
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'choices': [
                      {
                        'finish_reason': 'stop',
                        'message': {
                          'content': jsonEncode({'blocks': blocks}),
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
          blocks: c.blocks,
        );
        expect(
          hp.parseFragment(result.single).querySelector('#marker')!.text,
          '12',
          reason:
              'slots=${template.slotTexts}; degraded=${translator.getDegradedBlockIdsForTest()}; result=$result',
        );
        expect(template.slotTexts.map((s) => s.trim()), ['Before', 'after.']);
        expect(translator.getDegradedBlockIdsForTest(), isEmpty);
      },
    );
  }
  test('Control ordinary protected anchor is excluded from slots', () {
    final slots = ProtectedAnchorTextSlots.parse(
      '<p>Before <a role="doc-noteref" href="#n1">1</a> after.</p>',
    );
    expect(slots.slotTexts.map((s) => s.trim()), ['Before', 'after.']);
  });

  for (final entry in ['inspection', 'inputPicker', 'dragDrop']) {
    test(
      'F2 default-directory failure is reported without escaping $entry',
      () async {
        final controller = TranslationDashboardController(
          repository: PendingRepository(),
          epubPickerOverride: ({onWindowsNotice}) =>
              Future<String?>.value('book.epub'),
          defaultOutputDirectoryResolver: (_) async =>
              throw const FileSystemException('Cannot create output directory'),
        );
        addTearDown(controller.dispose);
        final Future<Object?> action;
        if (entry == 'inspection') {
          controller.setInputPath('book.epub');
          action = controller.startInspection(generateStyle: false);
        } else if (entry == 'dragDrop') {
          action = controller.importDroppedEpubPath('book.epub');
        } else {
          action = controller.pickInputPath();
        }
        await expectLater(action, completes);
        expect(
          controller.state.logs.join('\n'),
          contains('Cannot create output directory'),
        );
      },
    );
  }

  test(
    'F3 unrelated setting in stale instance must not revert another instance API key',
    () async {
      final dir = await Directory.systemTemp.createTemp('deep5_settings_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      await file.writeAsString(
        jsonEncode(
          TranslationConfig.defaults()
              .copyWith(apiProviderSelection: ApiProviderSelection.custom)
              .toJson(),
        ),
      );
      final secrets = SharedSecrets();
      SettingsStore store() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final first = SettingsController(store());
      final second = SettingsController(store());
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await Future.wait([first.ready, second.ready]);
      expect(await second.setApiKey('key-new'), true);
      expect(secrets.custom, 'key-new');
      await first.setUiLanguage(UiLanguage.chinese);
      await first.setThemeMode(AppThemeMode.dark);
      await first.setMaxRetries(2);
      expect(secrets.custom, 'key-new');
      expect(secrets.legacy, 'key-new');
      expect(secrets.deep, 'deep-old');
      expect(secrets.mutations, 2);
      expect((await store().load()).apiKey, 'key-new');
    },
  );

  test(
    'F3 direct stale store save also leaves unchanged secrets alone',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'deep5_direct_settings_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = SharedSecrets();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final stale = await store.load();
      secrets.legacy = 'external-legacy';
      secrets.custom = 'external-custom';
      secrets.deep = 'external-deep';
      await store.save(stale.copyWith(themeMode: AppThemeMode.dark));
      expect(secrets.mutations, 0);
      expect(secrets.legacy, 'external-legacy');
      expect(secrets.custom, 'external-custom');
      expect(secrets.deep, 'external-deep');
    },
  );

  test(
    'F3 provider switches, endpoint edits and explicit clears still persist keys',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'deep5_provider_settings_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final secrets = SharedSecrets();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final settings = SettingsController(store);
      addTearDown(settings.dispose);
      await settings.ready;
      await settings.applyApiProviderPreset(ApiProviderPreset.custom);
      expect(secrets.legacy, 'key-old');
      await settings.applyApiProviderPreset(ApiProviderPreset.deepseek);
      expect(secrets.legacy, 'deep-old');
      await settings.setApiBaseUrl('https://custom.example/v1');
      expect(secrets.custom, 'deep-old');
      expect(
        (await SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        ).load()).apiKey,
        'deep-old',
      );
      expect(await settings.setApiKey(''), true);
      expect(secrets.legacy, isNull);
      expect(secrets.custom, isNull);
      expect(secrets.deep, 'deep-old');
    },
  );

  for (final disposed in [false, true]) {
    test(
      'F2 stale/default directory failure has no late state effects disposed=$disposed',
      () async {
        final pending = Completer<String>();
        final controller = TranslationDashboardController(
          repository: PendingRepository(),
          defaultOutputDirectoryResolver: (_) => pending.future,
        );
        final action = controller.importDroppedEpubPath('old.epub');
        if (disposed) {
          controller.dispose();
        } else {
          addTearDown(controller.dispose);
          controller.setInputPath('new.epub');
        }
        pending.completeError(
          const FileSystemException('Stale directory failure'),
        );
        expect(await action, false);
        if (!disposed) {
          expect(controller.state.inputPath, 'new.epub');
          expect(
            controller.state.logs.join('\n'),
            isNot(contains('Stale directory failure')),
          );
        }
      },
    );
  }

  for (final bilingual in [false, true]) {
    test(
      'F4 OPF foreign language metadata remains intact bilingual=$bilingual',
      () {
        const original =
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:custom="urn:custom"><dc:language>en</dc:language><custom:language code="source">en</custom:language></metadata><manifest/><spine/></package>';
        final result = EpubIsolateWorker.renderNavigationMetadata(
          archiveFiles: {
            'META-INF/container.xml': utf8.encode(
              '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
            ),
            'OPS/content.opf': utf8.encode(original),
          },
          labelsByPath: {},
          languageTag: 'zh-CN',
          bilingual: bilingual,
        );
        final opf = XmlDocument.parse(result['OPS/content.opf']!);
        final foreign = opf.descendants
            .whereType<XmlElement>()
            .where(
              (e) => e.name.prefix == 'custom' && e.name.local == 'language',
            )
            .toList();
        expect(foreign, hasLength(1));
        expect(foreign.single.innerText, 'en');
        final languages = opf.descendants
            .whereType<XmlElement>()
            .where(
              (e) =>
                  e.name.local == 'language' &&
                  e.namespaceUri == 'http://purl.org/dc/elements/1.1/',
            )
            .map((e) => e.innerText);
        expect(languages, bilingual ? ['en', 'zh-CN'] : ['zh-CN']);
      },
    );
  }

  test('F4 foreign-only language does not suppress creation of dc language', () {
    final result = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: {
        'META-INF/container.xml': utf8.encode(
          '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
        ),
        'OPS/content.opf': utf8.encode(
          '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:custom="urn:custom"><custom:language>en</custom:language><custom:extra><custom:language>fr</custom:language></custom:extra></metadata><manifest/><spine/></package>',
        ),
      },
      labelsByPath: {},
      languageTag: 'zh-CN',
    );
    final opf = XmlDocument.parse(result['OPS/content.opf']!);
    final languages = opf.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'language',
    );
    expect(
      languages
          .where((e) => e.namespaceUri == 'urn:custom')
          .map((e) => e.innerText),
      ['en', 'fr'],
    );
    expect(
      languages
          .where((e) => e.namespaceUri == 'http://purl.org/dc/elements/1.1/')
          .single
          .innerText,
      'zh-CN',
    );
  });

  for (final epub3 in [false, true]) {
    for (final bilingual in [false, true]) {
      for (final selectedToc in [false, true]) {
        test(
          'F5 TOC preserves correct source/translation labels epub3=$epub3 bilingual=$bilingual selectedToc=$selectedToc',
          () async {
            final dir = await Directory.systemTemp.createTemp(
              'deep5_bilingual_toc_',
            );
            addTearDown(() => dir.delete(recursive: true));
            final file = await writeBook(
              dir,
              body: '<h1 id="ch1">First chapter</h1>',
            );
            final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
            archive.addFile(
              ArchiveFile.string(
                'OPS/toc.xhtml',
                '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en"><head><title>Contents</title></head><body>${epub3 ? '<nav epub:type="toc">' : ''}<p><a href="chapter.xhtml#ch1">First chapter</a></p>${epub3 ? '</nav>' : ''}</body></html>',
              ),
            );
            archive.addFile(
              ArchiveFile.string(
                'OPS/content.opf',
                '<package xmlns="http://www.idpf.org/2007/opf" version="${epub3 ? '3.0' : '2.0'}"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:language>en</dc:language></metadata><manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="toc" href="toc.xhtml" ${epub3 ? 'properties="nav"' : ''} media-type="application/xhtml+xml"/></manifest><spine><itemref idref="toc"/><itemref idref="ch"/></spine></package>',
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
                .copyWith(includeInTranslation: selectedToc);
            final content = inspected.chapters.singleWhere(
              (c) => c.path == 'OPS/chapter.xhtml',
            );
            final output = '${dir.path}/out.epub';
            await EpubRepacker().writeTranslatedEpub(
              inputPath: file.path,
              outputFilePath: output,
              config: TranslationConfig.defaults().copyWith(
                bilingual: bilingual,
              ),
              chapters: [
                translated(toc, ['<p><a href="chapter.xhtml#ch1">第一章</a></p>']),
                translated(content, ['<h1 id="ch1">第一章</h1>']),
              ],
            );
            final exported = ZipDecoder().decodeBytes(
              await File(output).readAsBytes(),
            );
            final markup = utf8.decode(
              exported.findFile('OPS/toc.xhtml')!.content,
            );
            XmlDocument.parse(markup);
            final doc = hp.parse(markup);
            expect(
              doc.querySelector('p:not([data-translation]) a')!.text,
              bilingual && selectedToc ? 'First chapter' : '第一章',
              reason: markup,
            );
            if (bilingual && selectedToc) {
              expect(doc.querySelector('p[data-translation] a')!.text, '第一章');
              expect(
                doc
                    .querySelector('p:not([data-translation]) a')!
                    .attributes['lang'],
                isNot('zh-CN'),
              );
            } else {
              expect(doc.querySelector('p[data-translation] a'), isNull);
            }
          },
        );
      }
    }
  }

  for (final size in [
    const Size(600, 300),
    const Size(600, 240),
    const Size(600, 400),
    const Size(1000, 800),
  ]) {
    testWidgets(
      '${size.height >= 400 ? 'Control' : 'F6'} preview in app shell does not overflow at $size',
      (tester) async {
        final controller = TranslationDashboardController(
          repository: PendingRepository(),
        );
        controller.state = controller.state.copyWith(
          inspectedChapters: [chapter('<p>The room was quiet.</p>')],
        );
        final container = ProviderContainer(
          overrides: [
            translationDashboardProvider.overrideWith((_) => controller),
          ],
        );
        addTearDown(container.dispose);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: AppShell(currentLocation: '/preview', child: PreviewPage()),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final proxy in ['socks5://127.0.0.1:1080', 'badproxy']) {
    test('F7 connection diagnostic preserves proxy failure: $proxy', () async {
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://example.invalid/v1',
        apiKey: 'dummy',
        model: 'dummy-model',
        httpProxy: proxy,
      );
      Object? failure;
      try {
        await const TranslationApiClient().testConnection(config: config);
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<FormatException>());
      final diagnostic = ConnectionDiagnostic.fromError(
        failure!,
        config: config,
      );
      expect(
        diagnostic.message,
        isNot(contains('Fill in the Base URL')),
        reason: 'Original: $failure; shown: ${diagnostic.message}',
      );
    });
  }
  test('F7 connection diagnostic preserves truncated API response', () {
    final config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'https://example.invalid/v1',
      apiKey: 'dummy',
      model: 'dummy-model',
    );
    Object? failure;
    try {
      const TranslationApiClient().extractMessageContent({
        'choices': [
          {
            'finish_reason': 'length',
            'message': {'content': 'O'},
          },
        ],
      });
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<TranslationParseException>());
    final diagnostic = ConnectionDiagnostic.fromError(failure!, config: config);
    expect(
      diagnostic.message,
      isNot(contains('Fill in the Base URL')),
      reason: 'Original: $failure; shown: ${diagnostic.message}',
    );
    expect(diagnostic.message, contains('finish_reason=length'));
  });

  test(
    'F7 missing required configuration retains its specific diagnostic',
    () async {
      final config = TranslationConfig.defaults().copyWith(apiKey: '');
      Object? failure;
      try {
        await const TranslationApiClient().testConnection(config: config);
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<MissingApiConfigurationException>());
      expect(
        ConnectionDiagnostic.fromError(failure!, config: config).message,
        contains('Fill in'),
      );
    },
  );
}
