import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/shared/io/settings_file_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Minimal in-memory [SettingsSecretStore]: external keychain deletions are
/// simulated by removing entries from [values].
class _FakeSecrets implements SettingsSecretStore {
  final values = <SettingsSecretSlot, String>{};

  Future<String?> _read(SettingsSecretSlot slot) async => values[slot];

  Future<void> _write(SettingsSecretSlot slot, String value) async {
    values[slot] = value;
  }

  Future<void> _delete(SettingsSecretSlot slot) async {
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

/// Same as [_FakeSecrets] but secret reads wait on [releaseReads]: lets a
/// test slip a concurrent settings.json modification into the legacy
/// migration window.
class _GatedSecrets extends _FakeSecrets {
  Completer<void>? releaseReads;
  bool readsStarted = false;

  @override
  Future<String?> _read(SettingsSecretSlot slot) async {
    readsStarted = true;
    final gate = releaseReads;
    if (gate != null) await gate.future;
    return values[slot];
  }
}

void main() {
  group('C-1 fragment 一刀切拒绝', () {
    test('OAuth implicit 形态与普通 fragment 一律拒绝', () {
      for (final url in <String>[
        'https://api.example.com/v1#api_key=sk-xxx',
        'https://example.com/v1#section',
        // 无 scheme 输入：Uri.tryParse 同样能解析出 fragment。
        'example.com/v1#frag',
      ]) {
        expect(
          () => TranslationConfig.validateApiUrl(url),
          throwsFormatException,
          reason: url,
        );
      }
    });

    test('无 fragment 的正常 URL 放行', () {
      TranslationConfig.validateApiUrl('https://api.example.com/v1');
      TranslationConfig.validateApiUrl('https://example.com/v1?tenant=books');
      TranslationConfig.validateApiUrl('https://example.com/v1#');
      TranslationConfig.validateApiUrl('');
      TranslationConfig.validateApiUrl('  ');
    });
  });

  group('C-2 外部删除密钥后不误报读取失败', () {
    test('binding 存在但 keychain 缺失时状态保持 missing', () async {
      final dir = await Directory.systemTemp.createTemp('c8_c2_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final secrets = _FakeSecrets();
      SettingsStore newStore() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );

      // 正常保存：binding 落盘。
      final store = newStore();
      await store.save(
        TranslationConfig.defaults().copyWith(
          apiProviderSelection: ApiProviderSelection.custom,
          apiBaseUrl: 'https://api.example.com',
          customApiBaseUrl: 'https://api.example.com',
          customApiKey: 'sk-real-key',
        ),
      );
      expect(secrets.values[SettingsSecretSlot.custom], 'sk-real-key');

      // 外部删除 keychain 中的密钥（模拟用户在系统钥匙串中删除）。
      secrets.values.remove(SettingsSecretSlot.custom);

      // 重启后重新加载：must not 误报 readFailure。
      final reloaded = newStore();
      final config = await reloaded.load();
      expect(config.customApiKey, isEmpty);
      expect(config.apiKey, isEmpty);
      expect(
        reloaded.secretReadFailed(SettingsSecretSlot.custom),
        isFalse,
        reason: '外部删除应保持 missing（UI 显示"无密钥"），而非"读取失败"',
      );

      // 后续 save（改无关设置）+ load：不把明文当密钥复活。
      await reloaded.save(config.copyWith(themeMode: AppThemeMode.light));
      expect(secrets.values[SettingsSecretSlot.custom], isNull);
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw['customApiKey'], isNull);
      final reread = await newStore().load();
      expect(reread.customApiKey, isEmpty);
      expect(reread.apiKey, isEmpty);
    });

    test('读到值但指纹不匹配仍判 readFailure（fail-closed 不变）', () async {
      final dir = await Directory.systemTemp.createTemp('c8_c2_closed_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final secrets = _FakeSecrets();
      SettingsStore newStore() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );

      final store = newStore();
      await store.save(
        TranslationConfig.defaults().copyWith(
          apiProviderSelection: ApiProviderSelection.custom,
          apiBaseUrl: 'https://api.example.com',
          customApiBaseUrl: 'https://api.example.com',
          customApiKey: 'sk-real-key',
        ),
      );
      // 模拟"secure 写完、JSON 没写就崩溃"：keychain 里是未提交的新 key。
      secrets.values[SettingsSecretSlot.custom] = 'sk-uncommitted';

      final reloaded = newStore();
      final config = await reloaded.load();
      expect(config.customApiKey, isEmpty);
      expect(reloaded.secretReadFailed(SettingsSecretSlot.custom), isTrue);
    });
  });

  group('C-3 重新加载重放冲突编辑', () {
    test('reloadSettings 重放编辑，不覆盖对方实例的更改', () async {
      final dir = await Directory.systemTemp.createTemp('c8_c3_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final secrets = _FakeSecrets();
      SettingsStore newStore() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );

      int conflicts = 0;
      final controller = SettingsController(
        newStore(),
        onSaveError: (_) {},
        onWriteConflict: () => conflicts++,
      );
      addTearDown(controller.dispose);
      await controller.ready;

      // 另一实例改了一个无关字段并保存 → 控制器的快照过期。
      final other = newStore();
      await other.save(
        (await other.load()).copyWith(themeMode: AppThemeMode.light),
      );

      // 控制器的编辑因快照过期而冲突（保存失败，编辑留在内存）。
      await controller.setTargetLanguage('English');
      expect(conflicts, 1);

      // "重新加载"：编辑被重放到新快照上，而不是丢弃。
      await controller.reloadSettings();
      expect(controller.state.targetLanguage, 'English');
      // 对方实例的无关更改未被覆盖（重放是 transformation，不是整包恢复）。
      expect(controller.state.themeMode, AppThemeMode.light);
      // 快照已恢复，后续保存不再冲突。
      expect(await controller.setOutputSuffix('_c8'), isTrue);
      expect(controller.state.outputSuffix, '_c8');
    });
  });

  group('C-6 lock 文件不残留', () {
    test('加锁解锁后 lock 文件被删除', () async {
      final dir = await Directory.systemTemp.createTemp('c8_c6_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final lockFile = File('${file.absolute.path}.lock');

      final result = await withSettingsFileLock(file, () async {
        expect(lockFile.existsSync(), isTrue);
        return 'ok';
      });
      expect(result, 'ok');
      expect(lockFile.existsSync(), isFalse);
    });

    test('action 抛错时 lock 文件同样被清理', () async {
      final dir = await Directory.systemTemp.createTemp('c8_c6_err_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      final lockFile = File('${file.absolute.path}.lock');

      await expectLater(
        withSettingsFileLock(file, () async {
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(lockFile.existsSync(), isFalse);
    });
  });

  group('C-7 migration 窗口内写冲突分类', () {
    test('migration 中发生写冲突时记为冲突而非迁移失败', () async {
      final dir = await Directory.systemTemp.createTemp('c8_c7_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'settings.json'));
      // 遗留明文 key：触发 migration。
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          ...TranslationConfig.defaults().copyWith(apiKey: 'sk-legacy').toJson(),
          'apiKey': 'sk-legacy',
        }),
      );
      final secrets = _GatedSecrets();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );

      secrets.releaseReads = Completer<void>();
      final loading = store.load();
      // 等待 load 进入 secret 读取阶段（此时 settings 快照已建立）。
      for (int i = 0; i < 100 && !secrets.readsStarted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(secrets.readsStarted, isTrue);
      // 在 migration 窗口内改文件（不走文件锁，模拟外部/hand-edit 写入）。
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      raw['themeMode'] = AppThemeMode.light.name;
      await file.writeAsString(jsonEncode(raw));
      secrets.releaseReads!.complete();

      // load 照常成功：冲突不该打断启动。
      final config = await loading;
      expect(config.apiKey, 'sk-legacy');
      // 分类为冲突：记为 load error 走恢复路径，而非吞掉记 migration failed。
      expect(store.configLoadError, isA<SettingsWriteConflict>());
    });
  });
}
