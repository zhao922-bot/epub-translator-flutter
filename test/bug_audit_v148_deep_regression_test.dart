import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/features/settings/presentation/widgets/settings_fields.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'bug_audit_round4_regression_test.dart' show writeBook;
import 'bug_audit_v148_regression_test.dart' show ReadFailureFile;

class LockedSettingsFile extends ReadFailureFile {
  LockedSettingsFile(super.delegate);
  @override
  Future<File> rename(String newPath) async => throw FileSystemException(
    'Simulated sharing violation during backup',
    path,
    const OSError('Sharing violation', 32),
  );
}

class BackupFailureFile extends LockedSettingsFile {
  BackupFailureFile(super.delegate);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      delegate.readAsString(encoding: encoding);
}

class SequenceConnection implements TranslationRepository {
  final replies = <Completer<String>>[];
  @override
  Future<String> testConnection({required TranslationConfig config}) {
    final reply = Completer<String>();
    replies.add(reply);
    return reply.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class EmptySecrets implements SettingsSecretStore {
  @override
  Future<String?> readApiKey() async => null;
  @override
  Future<String?> readDeepSeekApiKey() async => null;
  @override
  Future<String?> readCustomApiKey() async => null;
  @override
  Future<void> writeApiKey(String value) async {}
  @override
  Future<void> writeDeepSeekApiKey(String value) async {}
  @override
  Future<void> writeCustomApiKey(String value) async {}
  @override
  Future<void> deleteApiKey() async {}
  @override
  Future<void> deleteDeepSeekApiKey() async {}
  @override
  Future<void> deleteCustomApiKey() async {}
}

Map<String, List<int>> navBook({
  String href = 'main.ncx',
  bool alternate = false,
}) => {
  'META-INF/container.xml': utf8.encode(
    '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
  ),
  'OPS/content.opf': utf8.encode(
    '<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:language>en</dc:language></metadata><manifest>${alternate ? '<item id="alternate" href="alternate.ncx" media-type="application/x-dtbncx+xml"/>' : ''}<item id="main" href="$href" media-type="application/x-dtbncx+xml"/></manifest><spine toc="main"/></package>',
  ),
  'OPS/main.ncx': utf8.encode(ncx),
  'OPS/alternate.ncx': utf8.encode(ncx),
};
const ncx =
    '<ncx><navMap><navPoint id="n"><navLabel><text>Chapter</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>';

class PendingConnection implements TranslationRepository {
  final result = Completer<String>();
  TranslationConfig? used;
  @override
  Future<String> testConnection({required TranslationConfig config}) {
    used = config;
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemorySettings extends SettingsStore {
  @override
  Future<TranslationConfig> load() async => TranslationConfig.defaults()
      .copyWith(apiKey: 'old-key', uiLanguage: UiLanguage.english);
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

void main() {
  testWidgets(
    'testing waits for an already started asynchronous field commit',
    (tester) async {
      final release = Completer<void>();
      final key = GlobalKey<SettingsTextFieldState>();
      var saved = 'old-key';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTextField(
              key: key,
              fieldKey: const ValueKey('pending-key'),
              value: saved,
              onChanged: (text) async {
                await release.future;
                saved = text;
              },
              decoration: const InputDecoration(),
              strings: const AppStrings(UiLanguage.english),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('pending-key')),
        'new-key',
      );
      await tester.pump(const Duration(milliseconds: 801));
      var completed = false;
      final flush = key.currentState!.commitPending().then(
        (_) => completed = true,
      );
      await tester.pump();
      expect(completed, isFalse);
      release.complete();
      await tester.pump();
      await flush;
      expect(saved, 'new-key');
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('history saves keep one sidecar identity for waiting writers', () async {
    final dir = await Directory.systemTemp.createTemp('stable-history-lock-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/history.json');
    final store = JobHistoryStore(historyFileProvider: () async => file);
    await store.saveMerged(merge: (jobs, _) => jobs, clearedAtEpochMs: 0);
    final sidecar = File('${file.path}.lock');
    expect(await sidecar.exists(), isTrue);
    final waiter = await sidecar.open(mode: FileMode.append);
    try {
      await store.saveMerged(merge: (jobs, _) => jobs, clearedAtEpochMs: 0);
      expect(await sidecar.exists(), isTrue);
    } finally {
      await waiter.close();
    }
  });
  test(
    'settings recover from failed load without resetting unrelated values',
    () async {
      final dir = await Directory.systemTemp.createTemp('recover-settings-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final original = TranslationConfig.defaults().copyWith(
        model: 'custom-recovered',
        targetLanguage: 'French',
        lockedGlossary: 'Alice=艾丽丝',
      );
      final writer = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: EmptySecrets(),
      );
      await writer.save(original);
      var fail = true;
      final store = SettingsStore(
        settingsFileProvider: () async =>
            fail ? LockedSettingsFile(file) : file,
        secretStore: EmptySecrets(),
      );
      final errors = <Object?>[];
      final controller = SettingsController(store, onSaveError: errors.add);
      addTearDown(controller.dispose);
      await controller.ready;
      expect(errors.last, isA<FileSystemException>());
      expect(store.didCorruptReset, isFalse);
      await expectLater(
        store.save(TranslationConfig.defaults()),
        throwsStateError,
      );
      fail = false;
      await Future.wait([
        controller.setThemeMode(AppThemeMode.dark),
        controller.setBilingual(true),
      ]);
      final restored = await writer.load();
      expect(restored.model, 'custom-recovered');
      expect(restored.targetLanguage, 'French');
      expect(restored.lockedGlossary, 'Alice=艾丽丝');
      expect(restored.themeMode, AppThemeMode.dark);
      expect(restored.bilingual, isTrue);
    },
  );
  test(
    'corrupt settings whose backup fails remain protected from saves',
    () async {
      final dir = await Directory.systemTemp.createTemp('backup-settings-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      const broken = '{"model":"custom", broken';
      await file.writeAsString(broken);
      final store = SettingsStore(
        settingsFileProvider: () async => BackupFailureFile(file),
        secretStore: EmptySecrets(),
      );
      await expectLater(store.load(), throwsFormatException);
      await expectLater(
        store.save(TranslationConfig.defaults()),
        throwsStateError,
      );
      expect(await file.readAsString(), broken);
    },
  );
  test('a later connection result wins over an older failed request', () async {
    final repository = SequenceConnection();
    final controller = ConnectionTestController(repository);
    addTearDown(controller.dispose);
    final old = controller.run(TranslationConfig.defaults());
    controller.clear();
    final next = controller.run(
      TranslationConfig.defaults().copyWith(model: 'new'),
    );
    repository.replies[1].complete('new connection');
    await next;
    repository.replies[0].completeError(StateError('old connection failed'));
    await old;
    expect(controller.state.valueOrNull, 'new connection');
  });
  for (final tag in ['script', 'style']) {
    for (final bilingual in [false, true]) {
      test('$tag literal close tags in CDATA survive bilingual=$bilingual', () {
        final raw =
            '<![CDATA[var one="</$tag>";]]><![CDATA[var two="</$tag>";]]>';
        final source =
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Book</title><$tag>$raw</$tag></head><body><p>Hello world.</p></body></html>';
        final chapter = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: 'OPS/chapter.xhtml',
          bytes: utf8.encode(source),
        );
        final out = EpubRepacker().renderTranslatedChapter(
          chapter: chapter.copyWith(
            blocks: [
              chapter.blocks.single.copyWith(translatedHtml: '<p>你好。</p>'),
            ],
          ),
          bilingual: bilingual,
        );
        expect(
          XmlDocument.parse(out).findAllElements(tag).first.innerText,
          XmlDocument.parse(source).findAllElements(tag).first.innerText,
        );
        expect(out, isNot(contains('epub-translator-raw-v1:')));
        expect(chapter.blocks.map((block) => block.sourceText), [
          'Hello world.',
        ]);
      });
    }
  }
  test('explicit missing NCX id falls back to a usable manifest NCX', () {
    final files = navBook(alternate: true);
    files['OPS/content.opf'] = utf8.encode(
      utf8
          .decode(files['OPS/content.opf']!)
          .replaceAll('toc="main"', 'toc="missing"'),
    );
    expect(
      EpubInspector.ncxPathFromOpfBytes(
        files: files,
        opfPath: 'OPS/content.opf',
      ),
      'OPS/alternate.ncx',
    );
    final out = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: files,
      labelsByPath: {'OPS/chapter.xhtml': '章节'},
      languageTag: 'zh-CN',
    );
    expect(out['OPS/alternate.ncx'], contains('章节'));
  });
  test('D8 CJK typography preparation preserves navigation anchor ids', () {
    final prepared = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
      sourceHtml:
          '<p><span id="opening" class="dropcap">T</span>he wind was cold.</p>',
      targetLanguage: 'Chinese',
    );
    expect(prepared, contains('id="opening"'));
  });
  test('D8 exported chapter retains anchor removed from API input', () {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/chapter.xhtml',
      bytes: utf8.encode(
        '<html><head><title>Book</title></head><body><p><span id="opening" class="dropcap">T</span>he wind was cold.</p></body></html>',
      ),
    );
    final block = chapter.blocks.single;
    final prepared = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
      sourceHtml: block.sourceHtml,
      targetLanguage: 'Chinese',
    );
    final translated = EpubChapterTranslator.lockHtmlStructureForTest(
      sourceHtml: prepared,
      translatedHtml: '<p>寒风刺骨。</p>',
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter.copyWith(
        blocks: [
          block.copyWith(sourceHtml: prepared, translatedHtml: translated),
        ],
      ),
      bilingual: false,
    );
    expect(output, contains('id="opening"'));
  });
  test('control: single NCX is rewritten', () {
    final out = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: navBook(),
      labelsByPath: {'OPS/chapter.xhtml': '章节'},
      languageTag: 'zh-CN',
    );
    expect(out['OPS/main.ncx'], contains('章节'));
  });
  test('D1 inspector follows explicit spine toc instead of first NCX', () {
    expect(
      EpubInspector.ncxPathFromOpfBytes(
        files: navBook(alternate: true),
        opfPath: 'OPS/content.opf',
      ),
      'OPS/main.ncx',
    );
  });
  test('D1 export rewrites the active NCX', () {
    final out = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: navBook(alternate: true),
      labelsByPath: {'OPS/chapter.xhtml': '章节'},
      languageTag: 'zh-CN',
    );
    expect(out['OPS/main.ncx'], contains('章节'));
  });
  for (final filename in [
    'chapter#1.xhtml',
    'chapter?1.xhtml',
    'chapter+1.xhtml',
  ]) {
    test(
      'D2 inspection resolves escaped reserved filename $filename',
      () async {
        final dir = await Directory.systemTemp.createTemp('epub-deep-');
        addTearDown(() => dir.delete(recursive: true));
        final book = await writeBook(dir, chapterName: filename);
        final result = await EpubInspector().inspect(
          inputPath: book.path,
          outputDirectory: dir.path,
          cancelToken: CancelToken(),
        );
        expect(result.chapters.map((c) => c.path), contains('OPS/$filename'));
        expect(result.warnings, isEmpty);
      },
    );
  }
  test('D2 encoded NCX filename is found and rewritten', () {
    final files = navBook(href: 'main%231.ncx');
    files['OPS/main#1.ncx'] = files.remove('OPS/main.ncx')!;
    final out = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: files,
      labelsByPath: {'OPS/chapter.xhtml': '章节'},
      languageTag: 'zh-CN',
    );
    expect(out['OPS/main#1.ncx'], contains('章节'));
  });
  test('D3 valid XHTML script CDATA survives chapter rendering', () {
    const source =
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Book</title><script><![CDATA[var text = "</script><p>example</p>";]]></script></head><body><p>Hello world.</p></body></html>';
    final original = XmlDocument.parse(source);
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/chapter.xhtml',
      bytes: utf8.encode(source),
    );
    final out = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: false,
    );
    final rendered = XmlDocument.parse(out);
    expect(
      rendered.findAllElements('script').single.innerText,
      original.findAllElements('script').single.innerText,
    );
    expect(chapter.blocks.map((b) => b.sourceText), ['Hello world.']);
  });
  testWidgets('D4 clicking connection test uses freshly typed setting', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    NativePlatformBridge.debugWindowsProcessStarter = (_, _) async =>
        throw UnsupportedError('No real process during audit');
    addTearDown(() => NativePlatformBridge.debugWindowsProcessStarter = null);
    final repository = PendingConnection();
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemorySettings()),
        settingsRepositoryProvider.overrideWithValue(repository),
        translationDashboardProvider.overrideWith(
          (ref) => TranslationDashboardController(repository: repository),
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
      'new-key',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Test'));
    await tester.pump();
    final actual = repository.used?.apiKey;
    repository.result.complete('OK');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(actual, 'new-key');
  });
  test('D5 changing settings invalidates an old connection success', () async {
    final repository = PendingConnection();
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemorySettings()),
        settingsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final settings = container.read(settingsProvider.notifier);
    await settings.ready;
    final controller = container.read(connectionTestProvider.notifier);
    final running = controller.run(container.read(settingsProvider));
    await settings.setApiBaseUrl('https://another-endpoint.invalid/v1');
    repository.result.complete('Connection successful');
    await running;
    expect(controller.state.valueOrNull, isNull);
  });
  test(
    'D6 settings read IO failure must not allow defaults to overwrite healthy JSON',
    () async {
      final dir = await Directory.systemTemp.createTemp('settings-deep-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      final original = TranslationConfig.defaults().copyWith(
        model: 'my-custom-model',
        targetLanguage: 'French',
        lockedGlossary: 'Alice=艾丽丝',
      );
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: EmptySecrets(),
      );
      await store.save(original);
      final failing = SettingsStore(
        settingsFileProvider: () async => LockedSettingsFile(file),
        secretStore: EmptySecrets(),
      );
      try {
        final loaded = await failing.load();
        await failing.save(loaded.copyWith(themeMode: AppThemeMode.dark));
      } catch (_) {}
      final after =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(after['model'], 'my-custom-model');
    },
  );
  test('D7 bilingual OPF added language must have an in-scope namespace', () {
    final files = navBook();
    files['OPS/content.opf'] = utf8.encode(
      '<package xmlns="http://www.idpf.org/2007/opf"><metadata><dc:language xmlns:dc="http://purl.org/dc/elements/1.1/">en</dc:language></metadata><manifest/><spine/></package>',
    );
    final output = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: files,
      labelsByPath: {},
      languageTag: 'zh-CN',
      bilingual: true,
    );
    final opf = XmlDocument.parse(output['OPS/content.opf']!);
    final added = opf.descendants.whereType<XmlElement>().singleWhere(
      (element) =>
          element.name.local == 'language' && element.innerText == 'zh-CN',
    );
    expect(added.namespaceUri, 'http://purl.org/dc/elements/1.1/');
  });
}
