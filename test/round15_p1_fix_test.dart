import 'dart:async';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/shared/io/settings_file_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _credentialRouteTests();
  _credentialReassertTests();
  group('round15 A-P1-1: body-loss gate for punctuation-only translations', () {
    const sourceText =
        'The travelers followed the river through the quiet valley, watching '
        'the morning light spread across the fields. They carried enough food '
        'for the journey and stopped near an old bridge to discuss the road '
        'ahead. By evening they hoped to reach the village and find a place '
        'to rest before continuing into the mountains.';

    test('rejects punctuation-only translation of long English prose', () {
      expect(
        sourceText.replaceAll(RegExp(r'\s+'), '').length,
        greaterThan(200),
      );
      expect(
        () => EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>$sourceText</p>',
          translatedHtml: '<p>。</p>',
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('allows a translated short chapter heading', () {
      expect(
        EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<h1>Chapter One</h1>',
          translatedHtml: '<h1>第一章</h1>',
        ),
        '<h1>第一章</h1>',
      );
    });

    test('conservatively allows punctuation for a short source', () {
      expect(
        EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>Hello</p>',
          translatedHtml: '<p>。</p>',
        ),
        '<p>。</p>',
      );
    });

    test('allows a normal long translation', () {
      const translatedHtml =
          '<p>旅人们沿着河流穿过宁静的山谷，看着晨光洒满田野。'
          '他们带着足够旅途中食用的粮食，在一座古老的桥边停下来，'
          '商量前方的道路。他们希望傍晚之前抵达村庄，找到一个可以'
          '休息的地方，然后再继续向山中进发。</p>';
      expect(
        EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>$sourceText</p>',
          translatedHtml: translatedHtml,
        ),
        translatedHtml,
      );
    });

    test('rejects punctuation-only translation at the 200-character source boundary', () {
      expect(
        () => EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>${'a' * 200}</p>',
          translatedHtml: '<p>${'。' * 9}</p>',
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('rejects an ASCII period as the whole translation of a long source', () {
      expect(
        () => EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>$sourceText</p>',
          translatedHtml: '<p>.</p>',
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('allows a tiny real translation of a long source', () {
      // Regression guard: existing tests (e.g. P2-#17) translate huge
      // sources with tiny mock translations; any real word must pass.
      const translatedHtml = '<p>译文</p>';
      expect(
        EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>${'a' * 200}</p>',
          translatedHtml: translatedHtml,
        ),
        translatedHtml,
      );
    });

    test(
      'source whitespace does not make a short body reach 200 characters',
      () {
        expect(
          EpubChapterTranslator.lockHtmlStructureForTest(
            sourceHtml: '<p>${'a \n\t' * 199}</p>',
            translatedHtml: '<p>。</p>',
          ),
          '<p>。</p>',
        );
      },
    );

    test('translation whitespace cannot inflate body coverage', () {
      expect(
        () => EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>$sourceText</p>',
          translatedHtml: '<p>${' \n\t' * 200}。</p>',
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('rejects zero translated body characters for a long source', () {
      expect(
        () => EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p>$sourceText</p>',
          translatedHtml: '<p> \n\t</p>',
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });
  });
}

class _ControlledSettingsStore extends SettingsStore {
  _ControlledSettingsStore(this.loadCompleter);

  final Completer<TranslationConfig> loadCompleter;
  TranslationConfig? persisted;
  Object? loadError;
  bool conflictNextSave = false;
  int loadCount = 0;
  final List<TranslationConfig> attempts = <TranslationConfig>[];
  final List<Set<SettingsSecretSlot>?> explicitSecretMutations =
      <Set<SettingsSecretSlot>?>[];

  @override
  Object? get configLoadError => loadError;

  @override
  Future<TranslationConfig> load() async {
    loadCount++;
    final config = persisted ?? await loadCompleter.future;
    loadError = null;
    return config;
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attempts.add(config);
    this.explicitSecretMutations.add(explicitSecretMutations);
    if (conflictNextSave) {
      conflictNextSave = false;
      final error = SettingsWriteConflict();
      loadError = error;
      throw error;
    }
    persisted = config;
  }
}

void _credentialRouteTests() {
  group('C-P1-1', () {
    final routeX = TranslationConfig.defaults().copyWith(
      apiProviderSelection: ApiProviderSelection.custom,
      apiBaseUrl: 'https://service-x.example/v1',
      customApiBaseUrl: 'https://service-x.example/v1',
      apiKey: 'old-X',
      customApiKey: 'old-X',
    );
    final recoveredRoutes = <String, TranslationConfig>{
      'custom endpoint changes': routeX.copyWith(
        apiBaseUrl: 'https://service-y.example/v1',
        customApiBaseUrl: 'https://service-y.example/v1',
        apiKey: 'K_Y',
        customApiKey: 'K_Y',
      ),
      'provider changes to DeepSeek': routeX.copyWith(
        apiProviderSelection: ApiProviderSelection.deepseek,
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'K_Y',
        deepseekApiKey: 'K_Y',
      ),
    };

    for (final entry in recoveredRoutes.entries) {
      test(
        'captures the pre-recovery credential route when ${entry.key}',
        () async {
          final loadCompleter = Completer<TranslationConfig>();
          final store = _ControlledSettingsStore(loadCompleter);
          int blockedNotices = 0;
          final controller = SettingsController(
            store,
            onReplayBlocked: () => blockedNotices++,
          );
          addTearDown(controller.dispose);
          loadCompleter.complete(routeX);
          await controller.ready;

          // Another instance saved Y; a previous conflict left this instance
          // displaying X with a load error, so setApiKey must recover first.
          store
            ..persisted = entry.value
            ..loadError = SettingsWriteConflict()
            ..conflictNextSave = true;
          expect(
            controller.state.apiProviderSelection,
            routeX.apiProviderSelection,
          );
          expect(controller.state.apiBaseUrl, routeX.apiBaseUrl);

          expect(await controller.setApiKey('K_X'), isFalse);
          expect(store.loadCount, 2, reason: 'The edit must auto-recover to Y');
          expect(
            controller.state.apiProviderSelection,
            entry.value.apiProviderSelection,
          );
          expect(controller.state.apiBaseUrl, entry.value.apiBaseUrl);
          expect(store.attempts.single.apiKey, 'K_X');
          expect(store.explicitSecretMutations.single, <SettingsSecretSlot>{
            SettingsSecretSlot.legacy,
            SettingsSecretSlot.custom,
          });
          expect(
            controller.blockedReplayCount,
            1,
            reason: 'The queued route must be call-time X, not recovered Y',
          );

          expect(await controller.reloadSettings(), isTrue);
          expect(controller.blockedReplayCount, 1);
          expect(blockedNotices, 1);
          expect(
            store.attempts,
            hasLength(1),
            reason: 'K_X must not replay onto Y without confirmation',
          );
          expect(controller.state.apiKey, 'K_Y');
          expect(store.persisted!.apiKey, 'K_Y');
        },
      );
    }
  });
}

class _LateCredentialSecretStore implements SettingsSecretStore {
  _LateCredentialSecretStore({required this.lateWrite});

  final bool lateWrite;
  final started = Completer<void>();
  final release = Completer<void>();
  final completed = Completer<void>();
  final Map<SettingsSecretSlot, String> values = {};
  final List<String> customWrites = [];

  @override
  Future<void> writeCustomApiKey(String value) async {
    customWrites.add(value);
    if (value == 'K1') {
      // Model both a late write and an already-landed write whose backend
      // completion notification arrives after the newer instance's commit.
      if (!lateWrite) values[SettingsSecretSlot.custom] = value;
      started.complete();
      await release.future;
      if (lateWrite) values[SettingsSecretSlot.custom] = value;
      completed.complete();
      return;
    }
    values[SettingsSecretSlot.custom] = value;
  }

  @override
  Future<String?> readCustomApiKey() async => values[SettingsSecretSlot.custom];
  @override
  Future<void> deleteCustomApiKey() async =>
      values.remove(SettingsSecretSlot.custom);
  @override
  Future<String?> readApiKey() async => values[SettingsSecretSlot.legacy];
  @override
  Future<void> writeApiKey(String value) async =>
      values[SettingsSecretSlot.legacy] = value;
  @override
  Future<void> deleteApiKey() async => values.remove(SettingsSecretSlot.legacy);
  @override
  Future<String?> readDeepSeekApiKey() async =>
      values[SettingsSecretSlot.deepSeek];
  @override
  Future<void> writeDeepSeekApiKey(String value) async =>
      values[SettingsSecretSlot.deepSeek] = value;
  @override
  Future<void> deleteDeepSeekApiKey() async =>
      values.remove(SettingsSecretSlot.deepSeek);
  @override
  Future<String?> readProxyAuthentication() async =>
      values[SettingsSecretSlot.proxy];
  @override
  Future<void> writeProxyAuthentication(String value) async =>
      values[SettingsSecretSlot.proxy] = value;
  @override
  Future<void> deleteProxyAuthentication() async =>
      values.remove(SettingsSecretSlot.proxy);
}

void _credentialReassertTests() {
  group('C-P1-2', () {
    for (final otherInstanceSaves in [false, true]) {
      test(
        otherInstanceSaves
            ? 'skips stale compensation after another instance commits K3'
            : 'reasserts K2 after a late write when settings are unchanged',
        () async {
          final temp = await Directory.systemTemp.createTemp('c_p1_2_');
          addTearDown(() => temp.delete(recursive: true));
          final file = File('${temp.path}/settings.json');
          final secrets = _LateCredentialSecretStore(
            lateWrite: !otherInstanceSaves,
          );
          SettingsStore makeStore() => SettingsStore(
            settingsFileProvider: () async => file,
            secretStore: secrets,
          );
          final a = makeStore();
          final loaded = await a.load();
          final failedSave = a.save(
            loaded.copyWith(customApiKey: 'K1'),
            explicitSecretMutations: const {SettingsSecretSlot.custom},
          );
          final failure = expectLater(
            failedSave,
            throwsA(isA<SettingsSecretSaveException>()),
          );
          await secrets.started.future;
          await failure;
          await a.save(
            loaded.copyWith(customApiKey: 'K2'),
            explicitSecretMutations: const {SettingsSecretSlot.custom},
          );
          expect(secrets.values[SettingsSecretSlot.custom], 'K2');
          final aSnapshot = await file.readAsString();

          if (otherInstanceSaves) {
            final b = makeStore();
            final bLoaded = await b.load();
            await b.save(
              bLoaded.copyWith(customApiKey: 'K3'),
              explicitSecretMutations: const {SettingsSecretSlot.custom},
            );
            expect(await file.readAsString(), isNot(aSnapshot));
            expect(secrets.values[SettingsSecretSlot.custom], 'K3');
          }
          final committed = await file.readAsString();

          // Hold the lock while the old operation completes: compensation
          // must queue behind it, never touch the backend outside the lock.
          await withSettingsFileLock(file, () async {
            secrets.release.complete();
            await secrets.completed.future;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            expect(
              secrets.customWrites,
              otherInstanceSaves ? ['K1', 'K2', 'K3'] : ['K1', 'K2'],
            );
          });
          // A lock barrier waits for the queued compensation to finish.
          await withSettingsFileLock(file, () async {});
          expect(
            secrets.values[SettingsSecretSlot.custom],
            otherInstanceSaves ? 'K3' : 'K2',
          );
          expect(
            secrets.customWrites,
            otherInstanceSaves ? ['K1', 'K2', 'K3'] : ['K1', 'K2', 'K2'],
          );
          expect(await file.readAsString(), committed);
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });
}
