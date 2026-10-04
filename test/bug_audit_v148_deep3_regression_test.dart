import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:html/parser.dart' as hp;
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/widgets/settings_fields.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/session_path_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/protected_anchor_text_slots.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'bug_audit_v148_deep2_regression_test.dart'
    show chapter, translated, PendingRepository, inspectedResult;

const historyJob = TranslationJob(
  id: 'old',
  inputPath: 'old.epub',
  outputPath: '.',
  status: TranslationJobStatus.failed,
  progress: 0,
);

class History extends JobHistoryStore {
  final loaded = Completer<({List<TranslationJob> jobs, int clearedAt})>();
  int writes = 0;
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})> loadWithTombstone() =>
      loaded.future;
  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    writes++;
    return (written: true, fileClearedAt: clearedAtEpochMs);
  }
}

class RememberedPaths extends SessionPathStore {
  @override
  Future<({String inputPath, String outputDirectory})> load() async =>
      (inputPath: 'remembered.epub', outputDirectory: 'remembered-output');
  @override
  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {}
}

class DelayedExistsFile implements File {
  DelayedExistsFile(this.path);
  @override
  final String path;
  final entered = Completer<void>();
  final existsReply = Completer<bool>();
  @override
  Future<bool> exists() {
    entered.complete();
    return existsReply.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecoveryStore extends SettingsStore {
  bool readable = false;
  Object? error = const FileSystemException('locked');
  int loads = 0;
  @override
  Object? get configLoadError => error;
  @override
  Future<TranslationConfig> load() async {
    loads++;
    if (!readable) {
      error = const FileSystemException('locked');
      throw error!;
    }
    error = null;
    return TranslationConfig.defaults();
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

class DelayedSettings extends SettingsStore {
  final reply = Completer<TranslationConfig>();
  @override
  Future<TranslationConfig> load() => reply.future;
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

class FailingSaveSettings extends SettingsStore {
  bool failing = true;
  int writes = 0;
  @override
  Future<TranslationConfig> load() async => TranslationConfig.defaults();
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    writes++;
    if (failing) throw const FileSystemException('write locked');
  }
}

void main() {
  test(
    'D8 inherited bindings survive extraction without changing original markup',
    () {
      const original =
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:ops="http://www.idpf.org/2007/ops"><head><title>Book</title></head><body><p>Read <a ops:type="noteref" href="notes.xhtml#n1">1</a>.</p><span ops:type="pagebreak">12</span></body></html>';
      final c = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/body.xhtml',
        bytes: utf8.encode(original),
      );
      expect(c.originalHtml, original);
      expect(c.blocks.length, 1);
      final slots = ProtectedAnchorTextSlots.parse(c.blocks.single.sourceHtml);
      expect(slots.hasProtectedAnchors, true);
      expect(slots.slotTexts.where((text) => text.trim() == '1'), isEmpty);
    },
  );
  test('D8 a locally shadowed foreign namespace is not EPUB semantics', () {
    for (final prefix in ['epub', 'ops']) {
      final fragment = hp.parseFragment(
        '<p xmlns:$prefix="http://www.idpf.org/2007/ops"><a xmlns:$prefix="urn:foreign" $prefix:type="noteref" href="other.xhtml#n1">1</a></p>',
      );
      expect(
        ProtectedAnchorTextSlots.parse(fragment.outerHtml).hasProtectedAnchors,
        false,
      );
    }
  });
  test(
    'D3 disposed clear writes an empty history and tombstone to disk',
    () async {
      final dir = await Directory.systemTemp.createTemp('deep3_history_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/job-history.json');
      final store = JobHistoryStore(historyFileProvider: () async => file);
      await store.save([historyJob]);
      final controller = TranslationDashboardController(
        repository: PendingRepository(),
        historyStore: store,
      );
      final clear = controller.clearJobHistory();
      controller.dispose();
      expect(await clear, true);
      final persisted = await store.loadWithTombstone();
      expect(persisted.jobs, isEmpty);
      expect(persisted.clearedAt, greaterThan(0));
    },
  );
  testWidgets('D5 failed persistence retries the same value', (tester) async {
    final store = FailingSaveSettings();
    final controller = SettingsController(store);
    addTearDown(controller.dispose);
    await controller.ready;
    final key = GlobalKey<SettingsTextFieldState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsTextField(
            key: key,
            fieldKey: const ValueKey('key'),
            value: controller.state.apiKey,
            onChanged: controller.setApiKey,
            onCommit: controller.setApiKey,
            decoration: const InputDecoration(),
            strings: AppStrings(UiLanguage.english),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'new-key');
    expect(await key.currentState!.commitPending(), false);
    store.failing = false;
    expect(await key.currentState!.commitPending(), true);
    expect(store.writes, 2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'D7 reverting while an older commit waits still persists the revert',
    (tester) async {
      final first = Completer<bool>();
      final writes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTextField(
              fieldKey: const ValueKey('key'),
              value: 'old',
              onChanged: (_) {},
              onCommit: (text) {
                writes.add(text);
                return writes.length == 1 ? first.future : Future.value(true);
              },
              decoration: const InputDecoration(),
              strings: AppStrings(UiLanguage.english),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextFormField), 'new');
      await tester.pump(const Duration(milliseconds: 801));
      await tester.enterText(find.byType(TextFormField), 'old');
      first.complete(true);
      await tester.pump(const Duration(milliseconds: 801));
      expect(writes, ['new', 'old']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final prefix in ['epub', 'ops']) {
    test('D8 structure locking preserves namespaced marker prefix=$prefix', () {
      final source =
          '<p xmlns:$prefix="http://www.idpf.org/2007/ops">Read <a href="notes.xhtml#n1" $prefix:type="noteref">1</a>.</p>';
      final locked = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: source,
        translatedHtml: source
            .replaceAll('Read', '阅读')
            .replaceAll('>1<', '>二<'),
      );
      expect(
        hp.parseFragment(locked).querySelector('a')!.text,
        '1',
        reason: locked,
      );
    });
    test('D8 namespaced noteref marker prefix=$prefix is source-owned', () {
      final source =
          '<p xmlns:$prefix="http://www.idpf.org/2007/ops">Read <a href="notes.xhtml#n1" $prefix:type="noteref">1</a>.</p>';
      final slots = ProtectedAnchorTextSlots.parse(source);
      expect(slots.hasProtectedAnchors, true);
      expect(slots.slotTexts.where((s) => s.trim() == '1'), isEmpty);
    });
  }
  test('D2 interrupted history load is safe after disposal', () async {
    final errors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() async {
      final history = History();
      final controller = TranslationDashboardController(
        repository: PendingRepository(),
        historyStore: history,
      );
      controller.dispose();
      history.loaded.complete((
        jobs: [historyJob.copyWith(status: TranslationJobStatus.running)],
        clearedAt: 0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      done.complete();
    }, (error, stack) => errors.add(error));
    await done.future;
    expect(errors, isEmpty);
  });
  test('control unchanged sibling language alignment works', () {
    final c = chapter(
      '<p><em lang="en">Poison</em> / <em lang="en">Gift</em></p>',
    );
    final out = EpubRepacker().renderTranslatedChapter(
      chapter: translated(c, [
        '<p><em lang="en">毒药</em> / <em lang="en">Gift</em></p>',
      ]),
      bilingual: false,
    );
    expect(
      hp.parse(out).querySelectorAll('em').first.attributes['lang'],
      'zh-CN',
    );
    expect(hp.parse(out).querySelectorAll('em').last.attributes['lang'], 'en');
  });
  test('control clear history persists while mounted', () async {
    final history = History()
      ..loaded.complete((jobs: [historyJob], clearedAt: 0));
    final controller = TranslationDashboardController(
      repository: PendingRepository(),
      historyStore: history,
    );
    addTearDown(controller.dispose);
    expect(await controller.clearJobHistory(), true);
    expect(history.writes, 1);
  });
  test(
    'control settings controller can recover with a real second setter',
    () async {
      final store = RecoveryStore();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;
      await controller.setApiKey('new-key');
      store.readable = true;
      await controller.setApiKey('new-key');
      expect(controller.state.apiKey, 'new-key');
    },
  );
  testWidgets('D7 initial load and an older commit do not erase newer typing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    NativePlatformBridge.debugWindowsProcessStarter = (_, _) async =>
        throw UnsupportedError('audit');
    addTearDown(() => NativePlatformBridge.debugWindowsProcessStarter = null);
    final store = DelayedSettings();
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    final finder = find.byKey(const ValueKey('settings-api-key'));
    await tester.enterText(finder, 'first-edit');
    final field = tester.state<SettingsTextFieldState>(
      find.ancestor(of: finder, matching: find.byType(SettingsTextField)),
    );
    final commit = field.commitPending();
    await tester.enterText(finder, 'newest-edit');
    store.reply.complete(
      TranslationConfig.defaults().copyWith(apiKey: 'stored-key'),
    );
    await tester.pump();
    await commit;
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<TextFormField>(finder).controller!.text,
      'newest-edit',
    );
    expect(container.read(settingsProvider).apiKey, 'newest-edit');
    await tester.pumpWidget(const SizedBox());
  });
  test('D2 opening missing history output is safe after disposal', () async {
    final history = History()
      ..loaded.complete((
        jobs: [
          historyJob.copyWith(
            status: TranslationJobStatus.completed,
            phase: TranslationJobPhase.translation,
            outputPath: 'missing-audit-output.epub',
          ),
        ],
        clearedAt: 0,
      ));
    final controller = TranslationDashboardController(
      repository: PendingRepository(),
      historyStore: history,
    );
    await Future<void>.delayed(Duration.zero);
    final open = controller.openJobOutput('old');
    controller.dispose();
    await open;
  });
  for (final bilingual in [false, true]) {
    test('D1 unwrapped nested emphasis language bilingual=$bilingual', () {
      final c = chapter(
        '<p><span class="smallcaps"><em lang="en">POISON</em></span> / <em lang="en">Gift</em></p>',
      );
      final prepared = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
        sourceHtml: c.blocks.single.sourceHtml,
        targetLanguage: 'Chinese',
      );
      final locked = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: prepared,
        translatedHtml:
            '<p><em lang="en">毒药</em> / <em lang="en">Gift</em></p>',
      );
      final out = EpubRepacker().renderTranslatedChapter(
        chapter: translated(c, [locked]),
        bilingual: bilingual,
      );
      final em = hp
          .parse(out)
          .querySelectorAll('em')
          .firstWhere((e) => e.text == '毒药');
      expect(em.attributes['lang'], 'zh-CN', reason: out);
      final kept = hp.parse(out).querySelectorAll('em').last;
      expect(kept.text, 'Gift');
      expect(kept.attributes['lang'], 'en');
    });
  }
  test('D2 retry continuation is safe after disposal', () async {
    final history = History()
      ..loaded.complete((jobs: [historyJob], clearedAt: 0));
    final repository = PendingRepository();
    final controller = TranslationDashboardController(
      repository: repository,
      historyStore: history,
    );
    await Future<void>.delayed(Duration.zero);
    final retry = controller.retryJob('old');
    await repository.entered.future;
    controller.dispose();
    repository.inspection.complete(inspectedResult());
    await retry;
  });
  test(
    'D3 clear history really persists if disposed while initial load is pending',
    () async {
      final history = History();
      final controller = TranslationDashboardController(
        repository: PendingRepository(),
        historyStore: history,
      );
      final clear = controller.clearJobHistory();
      controller.dispose();
      history.loaded.complete((jobs: [historyJob], clearedAt: 0));
      expect(await clear, true);
      expect(history.writes, 1);
    },
  );
  test(
    'D4 session restore does not overwrite a newer manual selection',
    () async {
      final file = DelayedExistsFile('remembered.epub');
      await IOOverrides.runZoned(() async {
        final controller = TranslationDashboardController(
          repository: PendingRepository(),
          pathStore: RememberedPaths(),
        );
        addTearDown(controller.dispose);
        await file.entered.future;
        controller.setInputPath('new.epub');
        controller.setOutputDirectory('new-output');
        file.existsReply.complete(true);
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.inputPath, 'new.epub');
        expect(controller.state.outputDirectory, 'new-output');
      }, createFile: (name) => file);
    },
  );
  testWidgets(
    'D5 same displayed key can be retried after configuration read recovers',
    (tester) async {
      final store = RecoveryStore();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;
      final key = GlobalKey<SettingsTextFieldState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTextField(
              key: key,
              fieldKey: const ValueKey('key'),
              value: controller.state.apiKey,
              onChanged: controller.setApiKey,
              onCommit: controller.setApiKey,
              decoration: const InputDecoration(),
              strings: AppStrings(UiLanguage.english),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextFormField), 'new-key');
      await key.currentState!.commitPending();
      store.readable = true;
      await key.currentState!.commitPending();
      expect(controller.state.apiKey, 'new-key');
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final tag in ['summary', 'figcaption']) {
    test('D6 bilingual output retains one structural $tag', () {
      final body = tag == 'summary'
          ? '<details><summary>Hello</summary><p>Body.</p></details>'
          : '<figure><img src="cover.jpg"/><figcaption>Hello</figcaption></figure>';
      final c = chapter(body);
      final texts = c.blocks
          .map(
            (b) => b.sourceHtml
                .replaceAll('Hello', '你好')
                .replaceAll('Body.', '内容。'),
          )
          .toList();
      final out = EpubRepacker().renderTranslatedChapter(
        chapter: translated(c, texts),
        bilingual: true,
      );
      final nodes = hp.parse(out).querySelectorAll(tag);
      expect(nodes.length, 1, reason: out);
      expect(nodes.single.text, contains('Hello'));
      expect(nodes.single.text, contains('你好'));
      expect(
        nodes.single
            .querySelector('[data-translation="true"]')!
            .attributes['lang'],
        'zh-CN',
      );
    });
  }
}
