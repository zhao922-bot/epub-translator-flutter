import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeSecrets implements SettingsSecretStore {
  final values = <SettingsSecretSlot, String>{};
  bool failWrites = false;
  bool failCustomWrite = false;
  bool failReads = false;
  bool unsupportedBackend = false;

  Never _fail() {
    if (unsupportedBackend) throw UnsupportedError('no secret backend');
    throw StateError('backend unavailable');
  }

  Future<String?> _read(SettingsSecretSlot slot) async {
    if (failReads || unsupportedBackend) _fail();
    return values[slot];
  }

  Future<void> _write(SettingsSecretSlot slot, String value) async {
    if (failWrites ||
        (slot == SettingsSecretSlot.custom && failCustomWrite) ||
        unsupportedBackend) {
      _fail();
    }
    values[slot] = value;
  }

  Future<void> _delete(SettingsSecretSlot slot) async {
    if (failWrites || unsupportedBackend) _fail();
    values.remove(slot);
  }

  @override
  Future<String?> readApiKey() => _read(SettingsSecretSlot.legacy);
  @override
  Future<String?> readDeepSeekApiKey() => _read(SettingsSecretSlot.deepSeek);
  @override
  Future<String?> readCustomApiKey() => _read(SettingsSecretSlot.custom);
  @override
  Future<String?> readProxyAuthentication() =>
      _read(SettingsSecretSlot.proxy);
  @override
  Future<void> writeApiKey(String value) =>
      _write(SettingsSecretSlot.legacy, value);
  @override
  Future<void> writeDeepSeekApiKey(String value) =>
      _write(SettingsSecretSlot.deepSeek, value);
  @override
  Future<void> writeCustomApiKey(String value) =>
      _write(SettingsSecretSlot.custom, value);
  @override
  Future<void> writeProxyAuthentication(String value) =>
      _write(SettingsSecretSlot.proxy, value);
  @override
  Future<void> deleteApiKey() => _delete(SettingsSecretSlot.legacy);
  @override
  Future<void> deleteDeepSeekApiKey() => _delete(SettingsSecretSlot.deepSeek);
  @override
  Future<void> deleteCustomApiKey() => _delete(SettingsSecretSlot.custom);
  @override
  Future<void> deleteProxyAuthentication() =>
      _delete(SettingsSecretSlot.proxy);
}

void main() {
  group('#5 legacy migration', () {
    test(
      'failed migration does not stamp schema 2 on plain saves; '
      'legacy key survives restart',
      () async {
        final dir = await Directory.systemTemp.createTemp('c7_migration_');
        addTearDown(() => dir.delete(recursive: true));
        final file = File(p.join(dir.path, 'settings.json'));
        await file.writeAsString(
          jsonEncode(<String, dynamic>{
            ...TranslationConfig.defaults()
                .copyWith(apiKey: 'sk-legacy')
                .toJson(),
            'apiKey': 'sk-legacy',
          }),
        );
        final secrets = _FakeSecrets()..failWrites = true;
        final store = SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );

        final loaded = await store.load();
        expect(loaded.apiKey, 'sk-legacy');
        // A plain non-credential save while the migration is still pending.
        await store.save(loaded.copyWith(themeMode: AppThemeMode.light));

        final raw = jsonDecode(await file.readAsString());
        expect(raw['credentialSchemaVersion'], isNull);
        // Restart: the legacy fallback is still alive, the key is usable.
        final restarted = SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        );
        expect((await restarted.load()).apiKey, 'sk-legacy');
      },
    );

    test('successful migration still stamps schema 2', () async {
      final dir = await Directory.systemTemp.createTemp('c7_migration_ok_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          ...TranslationConfig.defaults()
              .copyWith(apiKey: 'sk-legacy')
              .toJson(),
          'apiKey': 'sk-legacy',
        }),
      );
      final secrets = _FakeSecrets();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await store.load();
      final raw = jsonDecode(await file.readAsString());
      expect(raw['credentialSchemaVersion'], 2);
      expect(secrets.values[SettingsSecretSlot.deepSeek], 'sk-legacy');
    });
  });

  group('#6 write conflict recovery', () {
    late Directory dir;
    late File file;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('c7_conflict_');
      file = File(p.join(dir.path, 'settings.json'));
    });
    tearDown(() => dir.delete(recursive: true));

    SettingsStore newStore() => SettingsStore(
      settingsFileProvider: () async => file,
      secretStore: _FakeSecrets(),
    );

    test('conflict is recorded as a load error; reload clears it', () async {
      final storeA = newStore();
      final storeB = newStore();
      await storeA.load();
      final configB = await storeB.load();
      await storeA.save(configB.copyWith(themeMode: AppThemeMode.light));

      await expectLater(
        storeB.save(configB.copyWith(themeMode: AppThemeMode.dark)),
        throwsA(isA<SettingsWriteConflict>()),
      );
      expect(storeB.configLoadError, isA<SettingsWriteConflict>());

      // Recovery: reload clears the error and the next save goes through.
      await storeB.load();
      expect(storeB.configLoadError, isNull);
      await storeB.save(
        (await storeB.load()).copyWith(themeMode: AppThemeMode.dark),
      );
      expect(
        jsonDecode(await file.readAsString())['themeMode'],
        AppThemeMode.dark.name,
      );
    });

    test('controller surfaces conflict and reloadSettings recovers', () async {
      final store = newStore();
      int conflicts = 0;
      final controller = SettingsController(
        store,
        onSaveError: (_) {},
        onWriteConflict: () => conflicts++,
      );
      addTearDown(controller.dispose);
      await controller.ready;

      final other = newStore();
      await other.load();
      await other.save(
        (await other.load()).copyWith(themeMode: AppThemeMode.light),
      );

      // The controller's snapshot is now stale: the save conflicts.
      expect(await controller.setOutputSuffix('_x'), isFalse);
      expect(conflicts, 1);

      await controller.reloadSettings();
      expect(await controller.setOutputSuffix('_x'), isTrue);
      expect(controller.state.outputSuffix, '_x');
    });
  });

  group('#7 endpoint/model rollback', () {
    test('model rolls back together with the endpoint on secret failure',
        () async {
      final dir = await Directory.systemTemp.createTemp('c7_rollback_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final secrets = _FakeSecrets()
        ..values[SettingsSecretSlot.custom] = 'old-key';
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          ...TranslationConfig.defaults()
              .copyWith(
                apiProviderSelection: ApiProviderSelection.custom,
                apiBaseUrl: 'https://old.example',
                customApiBaseUrl: 'https://old.example',
                model: 'old-model',
                customModel: 'old-model',
              )
              .toJson(),
          'credentialSchemaVersion': 2,
        }),
      );
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final loaded = await store.load();
      secrets.failCustomWrite = true;

      await expectLater(
        store.save(
          loaded.copyWith(
            apiBaseUrl: 'https://new.example',
            customApiBaseUrl: 'https://new.example',
            model: 'new-model',
            customModel: 'new-model',
            customApiKey: 'new-key',
          ),
        ),
        throwsA(isA<SettingsSecretSaveException>()),
      );
      final raw =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw['apiBaseUrl'], 'https://old.example');
      expect(raw['customApiBaseUrl'], 'https://old.example');
      expect(raw['model'], 'old-model');
      expect(raw['customModel'], 'old-model');
    });
  });

  group('#8 secret read failure status', () {
    test('read failure is recorded as readFailure, not missing', () async {
      final dir = await Directory.systemTemp.createTemp('c7_readfail_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final secrets = _FakeSecrets()..failReads = true;
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await store.load();
      // The UI's "credential read failed" hint and _saveSecret's
      // no-blind-delete guard both key off this status.
      expect(store.secretReadFailed(SettingsSecretSlot.custom), isTrue);
      expect(store.secretReadFailed(SettingsSecretSlot.deepSeek), isTrue);
    });
  });

  group('#9 damaged envelope prefix', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('c7_envelope_');
    });
    tearDown(() => root.delete(recursive: true));

    File blockFile(String key) => File(
      p.join(root.path, 'blocks', key.substring(0, 2), '$key.html'),
    );

    test('corrupted prefix region is a miss, not trusted legacy', () async {
      final store = TranslationCacheStore(cacheRoot: root);
      await store.putBlockTranslation('abkey', '<p>hello</p>');
      await store.waitForMaintenanceForTest();
      final file = blockFile('abkey');
      final raw = await file.readAsString();
      // Damage only the envelope prefix region.
      await file.writeAsString('X${raw.substring(1, 12)}${raw.substring(12)}');
      expect(await store.getBlockTranslation('abkey'), isNull);
    });

    test('sha256 marker with damaged prefix is a miss', () async {
      final store = TranslationCacheStore(cacheRoot: root);
      await store.putBlockTranslation('abkey', '<p>hello</p>');
      await store.waitForMaintenanceForTest();
      final file = blockFile('abkey');
      final raw = await file.readAsString();
      final newline = raw.indexOf('\n');
      // Keep the sha256 marker but garble the leading run.
      await file.writeAsString(
        'garbled-header:sha256:${raw.substring(raw.indexOf('sha256:') + 7, newline)}\n<p>hello</p>',
      );
      expect(await store.getBlockTranslation('abkey'), isNull);
    });

    test('genuine legacy entry without any prefix is still trusted', () async {
      final store = TranslationCacheStore(cacheRoot: root);
      await blockFile('abkey').parent.create(recursive: true);
      await blockFile('abkey').writeAsString('<p>legacy paid work</p>');
      expect(
        await store.getBlockTranslation('abkey'),
        '<p>legacy paid work</p>',
      );
    });

    test('intact envelope verifies normally', () async {
      final store = TranslationCacheStore(cacheRoot: root);
      await store.putBlockTranslation('abkey', '<p>hello</p>');
      await store.waitForMaintenanceForTest();
      expect(await store.getBlockTranslation('abkey'), '<p>hello</p>');
    });
  });

  group('#11/#12 throughput accounting', () {
    TranslationJob job({
      TranslationJobPhase phase = TranslationJobPhase.translation,
      int completed = 0,
      int cached = 0,
      int degraded = 0,
      int scanned = 0,
      int scanTotal = 0,
    }) => TranslationJob(
      id: 'j',
      inputPath: '',
      outputPath: '',
      status: TranslationJobStatus.running,
      progress: 0,
      phase: phase,
      completedBlocks: completed,
      totalBlocks: 100,
      cachedBlocks: cached,
      apiDegradedBlocks: degraded,
      cacheScanScannedBlocks: scanned,
      cacheScanTotalBlocks: scanTotal,
    );

    test('#11 unverified checkpoint during scan feeds zero throughput', () {
      final scanning = job(
        phase: TranslationJobPhase.cacheRestoration,
        completed: 60,
        cached: 10,
        scanned: 20,
        scanTotal: 100,
      );
      expect(
        TranslationRunEstimate.apiTranslatedBlocksForThroughput(scanning),
        0,
      );
    });

    test('#11 completed scan falls back to verified counts', () {
      final done = job(
        phase: TranslationJobPhase.cacheRestoration,
        completed: 60,
        cached: 60,
        scanned: 100,
        scanTotal: 100,
      );
      expect(
        TranslationRunEstimate.apiTranslatedBlocksForThroughput(done),
        0,
      );
      final partial = job(
        phase: TranslationJobPhase.translation,
        completed: 80,
        cached: 60,
        scanned: 100,
        scanTotal: 100,
      );
      expect(
        TranslationRunEstimate.apiTranslatedBlocksForThroughput(partial),
        20,
      );
    });

    test('#12 degraded blocks are excluded from throughput', () {
      final running = job(completed: 100, cached: 30, degraded: 12);
      expect(
        TranslationRunEstimate.apiTranslatedBlocksForThroughput(running),
        58,
      );
    });

    test('null job yields zero', () {
      expect(TranslationRunEstimate.apiTranslatedBlocksForThroughput(null), 0);
    });

    test('#12 apiDegradedBlocks round-trips through json and copyWith', () {
      final original = job(completed: 10, degraded: 3);
      final revived = TranslationJob.fromJson(original.toJson());
      expect(revived.apiDegradedBlocks, 3);
      expect(original.copyWith().apiDegradedBlocks, 3);
      expect(original.copyWith(apiDegradedBlocks: 5).apiDegradedBlocks, 5);
      // Legacy payloads without the key default to zero.
      final legacyJson = original.toJson()..remove('apiDegradedBlocks');
      expect(
        TranslationJob.fromJson(legacyJson).apiDegradedBlocks,
        0,
      );
    });
  });

  group('#13 footnote-aware batch estimate', () {
    InspectedChapter chapter(String path, int blocks) => InspectedChapter(
      path: path,
      title: path,
      body: '',
      originalHtml: '<html></html>',
      blocks: <ExtractedBlock>[
        for (int i = 0; i < blocks; i++)
          ExtractedBlock(
            id: 'p-$i',
            tagName: 'p',
            sourceHtml: '<p>n$i</p>',
            sourceText: 'n$i',
          ),
      ],
      category: ChapterCategory.backMatter,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );

    test('standalone footnote chapters use the footnote planner', () {
      final chapters = <InspectedChapter>[
        chapter('OEBPS/notes-fn.xhtml', 20),
        chapter('OEBPS/notes2-fn.xhtml', 20),
        chapter('OEBPS/endnotes-fn.xhtml', 20),
      ];
      for (final c in chapters) {
        expect(FootnoteBatchPlanner.isStandaloneFootnoteChapter(c), isTrue);
      }
      final estimate = TranslationRunEstimate.staticPart(
        chapters,
        chunkSize: 3000,
      );
      // 60 footnote blocks, at most 12 references per batch, packed across
      // the contiguous footnote files: 5 batches, matching the real
      // pipeline's FootnoteBatchPlanner instead of per-chapter planning.
      expect(estimate.estimatedApiBatches, 5);
    });

    test('mixed book sums normal and footnote planning', () {
      final normal = chapter('OEBPS/ch1.xhtml', 20);
      expect(
        FootnoteBatchPlanner.isStandaloneFootnoteChapter(normal),
        isFalse,
      );
      final chapters = <InspectedChapter>[
        normal,
        chapter('OEBPS/notes-fn.xhtml', 24),
      ];
      final normalBatches = const TranslationBatchPlanner()
          .plan(
            pendingBlocks: normal.blocks,
            chunkSize: 3000,
            chapterBlocks: normal.blocks,
            chapterTitle: normal.title,
          )
          .length;
      // 24 footnote blocks -> 2 footnote batches.
      final estimate = TranslationRunEstimate.staticPart(
        chapters,
        chunkSize: 3000,
      );
      expect(estimate.estimatedApiBatches, normalBatches + 2);
    });
  });

  group('#15 checkpoint prune race', () {
    test('a just-saved checkpoint survives concurrent pruning', () async {
      final root = await Directory.systemTemp.createTemp('c7_prunerace_');
      addTearDown(() => root.delete(recursive: true));
      final store = TranslationCacheStore(cacheRoot: root);
      final jobsDir = Directory(p.join(root.path, 'jobs'));
      await jobsDir.create(recursive: true);
      final old = DateTime.now().subtract(const Duration(hours: 1));
      for (int i = 0; i < 40; i++) {
        final f = File(p.join(jobsDir.path, 'stale-$i.json'));
        await f.writeAsString('{}');
        await f.setLastModified(old);
      }
      JobResumeState state(String key) => JobResumeState(
        jobKey: key,
        inputFingerprint: 'fp',
        inputPath: '/in.epub',
        outputPath: '/out.epub',
        status: 'running',
        completedFiles: 0,
        totalFiles: 1,
        completedBlocks: 1,
        totalBlocks: 10,
        cachedBlocks: 0,
        resumedBlocks: 0,
        currentChapter: 'c',
        updatedAtIso8601: DateTime.now().toIso8601String(),
      );
      for (int i = 0; i < 30; i++) {
        const key = 'target';
        final file = File(p.join(jobsDir.path, '$key.json'));
        // Make the target a prune candidate, then refresh it concurrently
        // with the prune: without the shared file gate the prune's
        // stat-then-delete could land after the save's rename and delete
        // the fresh checkpoint.
        await file.writeAsString('{}');
        await file.setLastModified(old);
        await Future.wait(<Future<void>>[
          store.saveJobState(state(key)),
          store.pruneJobCheckpointsForTest(jobsDir),
        ]);
        expect(await file.exists(), isTrue, reason: 'iteration $i');
        expect((await store.loadJobState(key))?.jobKey, key);
      }
    });
  });

  group('#16 cache root retry', () {
    test('failed root initialization is not cached forever', () async {
      final root = await Directory.systemTemp.createTemp('c7_rootretry_');
      addTearDown(() => root.delete(recursive: true));
      int calls = 0;
      final store = TranslationCacheStore(
        resolveCacheRoot: () async {
          calls++;
          if (calls == 1) throw StateError('transient platform failure');
          return root;
        },
      );
      await expectLater(
        store.getBlockTranslation('abmissing'),
        throwsStateError,
      );
      expect(calls, 1);
      // The failed future was dropped: the next call retries instead of
      // replaying the same error.
      await store.putBlockTranslation('abkey', 'hello');
      expect(calls, 2);
      await store.waitForMaintenanceForTest();
      expect(await store.getBlockTranslation('abkey'), 'hello');
    });
  });

  group('#17 api url validation', () {
    test('allows non-credential query params and @ in path', () {
      TranslationConfig.validateApiUrl('https://example.com/v1?tenant=books');
      TranslationConfig.validateApiUrl('https://example.com/@team/v1');
      TranslationConfig.validateApiUrl('  ');
      TranslationConfig.validateApiUrl('');
    });

    test('rejects any fragment (C-1: one-size-fits-all)', () {
      // A fragment is never sent to the server: zero legitimate use, while
      // the OAuth implicit-flow shape would silently drop the key.
      for (final url in <String>[
        'https://api.example.com/v1#api_key=sk-xxx',
        'https://example.com/v1#section',
        'example.com/v1#frag',
      ]) {
        expect(
          () => TranslationConfig.validateApiUrl(url),
          throwsFormatException,
          reason: url,
        );
      }
      // An empty fragment carries nothing and stays allowed.
      TranslationConfig.validateApiUrl('https://example.com/v1#');
    });

    test('rejects userinfo and credential-like query params', () {
      expect(
        () => TranslationConfig.validateApiUrl(
          'https://user:pass@example.com/v1',
        ),
        throwsFormatException,
      );
      for (final param in <String>[
        'key',
        'api_key',
        'apikey',
        'token',
        'access_token',
        'secret',
        'client_secret',
        'password',
        'pwd',
      ]) {
        expect(
          () => TranslationConfig.validateApiUrl(
            'https://example.com/v1?$param=xxx',
          ),
          throwsFormatException,
          reason: param,
        );
      }
    });

    test('toJson rejects credential-bearing components in both url slots', () {
      // P1-9: a credential-bearing custom URL must never reach JSON, even
      // when DeepSeek is currently selected.
      final bad = TranslationConfig.defaults().copyWith(
        apiProviderSelection: ApiProviderSelection.deepseek,
        customApiBaseUrl: 'https://example.com/v1?api_key=xxx',
      );
      expect(() => bad.toJson(), throwsFormatException);
      final badSelected = bad.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
      );
      expect(() => badSelected.toJson(), throwsFormatException);
      // #17: a stale legitimate custom URL (non-credential query) must not
      // block saving unrelated settings when DeepSeek is selected.
      final legit = TranslationConfig.defaults().copyWith(
        apiProviderSelection: ApiProviderSelection.deepseek,
        customApiBaseUrl: 'https://gateway.example.com/v1?tenant=books',
      );
      legit.toJson(); // Does not throw.
    });
  });

  group('#37 unsupported backend', () {
    test('missing secret backend is classified unsupported', () async {
      final dir = await Directory.systemTemp.createTemp('c7_unsupported_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final secrets = _FakeSecrets()..unsupportedBackend = true;
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await store.load();
      // Reads degrade to readFailure (never blind-delete)...
      expect(store.secretReadFailed(SettingsSecretSlot.custom), isTrue);
      // ...and an explicit key edit against the missing backend surfaces
      // as unsupported instead of being retried like a transient failure.
      await expectLater(
        store.save(
          (await store.load()).copyWith(customApiKey: 'k'),
          explicitSecretMutations: {SettingsSecretSlot.custom},
        ),
        throwsA(
          isA<SettingsSecretSaveException>().having(
            (e) => e.isUnsupported,
            'isUnsupported',
            isTrue,
          ),
        ),
      );
      // Without an explicit edit there is no blind write: the save goes
      // through and the unreadable slot is left untouched.
      await store.save((await store.load()).copyWith(themeMode: AppThemeMode.light));
      expect(secrets.values, isNot(contains(SettingsSecretSlot.custom)));
    });
  });
}
