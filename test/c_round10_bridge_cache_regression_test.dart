import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('P1-#3: blocked stdin close times out and kills the helper', () async {
    final root = await Directory.systemTemp.createTemp('round10_helper_');
    addTearDown(() => root.delete(recursive: true));
    final pidFile = File(p.join(root.path, 'pid'));
    final script = File(p.join(root.path, 'helper'));
    // exec keeps sleep in the helper's PID and leaves no shell child behind.
    await script.writeAsString('''#!/bin/sh
printf '%s' "\$\$" > "\$1"
exec sleep 60
''');
    expect((await Process.run('chmod', ['+x', script.path])).exitCode, 0);
    final stopwatch = Stopwatch()..start();
    final operation = NativePlatformBridge.runDesktopSecretHelperForTest(
      script.path,
      [script.path, pidFile.path],
      stdinInput: 's' * (4 * 1024 * 1024),
      timeout: const Duration(seconds: 1),
    );
    final assertion = expectLater(
      operation.timeout(const Duration(seconds: 5)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Secret helper "${script.path}" timed out.',
        ),
      ),
    );
    while (!await pidFile.exists()) {
      if (stopwatch.elapsed > const Duration(seconds: 4)) {
        fail('Helper did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final pid = int.parse(await pidFile.readAsString());
    addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));
    await assertion;
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    // Killing is asynchronous: wait briefly for the OS to reap the helper.
    while (Process.killPid(pid, ProcessSignal.sigcont) &&
        stopwatch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(Process.killPid(pid, ProcessSignal.sigcont), isFalse);
  }, skip: Platform.isWindows ? 'Needs a POSIX shell.' : null);

  test(
    'P2-#8: full scan rebases a shared rollback, then light eviction works',
    () async {
      final fixture = await _CacheFixture.create();
      addTearDown(() => fixture.root.delete(recursive: true));
      await fixture.rollBack(['kA', 'kB']);
      expect(await fixture.store.enforceQuotaLightlyForTest(), 0);
      await fixture.store.pruneCacheDirectoryForTest(fixture.root);
      expect(await fixture.store.enforceQuotaLightlyForTest(), greaterThan(0));
      expect(await fixture.file('kA').exists(), isFalse);
      expect(await fixture.file('kB').exists(), isFalse);
      expect(fixture.store.estimatedCacheBytesForTest, 0);
    },
  );

  test(
    'P2-#11: isolated same-size rewrite with earlier mtime stays protected',
    () async {
      final fixture = await _CacheFixture.create();
      addTearDown(() => fixture.root.delete(recursive: true));
      final file = fixture.file('kA');
      final raw = await file.readAsString();
      final replacement = _envelope('z' * 300);
      expect(utf8.encode(replacement).length, utf8.encode(raw).length);
      await file.writeAsString(replacement);
      await fixture.rollBack(['kA']);
      await fixture.store.pruneCacheDirectoryForTest(fixture.root);
      expect(await fixture.store.enforceQuotaLightlyForTest(), greaterThan(0));
      expect(await file.readAsString(), replacement);
      expect(await fixture.file('kB').exists(), isFalse);
    },
  );

  test(
    'P2-#11: valid same-size rewrite within a rollback cohort stays protected',
    () async {
      final fixture = await _CacheFixture.create(keys: ['kA', 'kB', 'kC']);
      addTearDown(() => fixture.root.delete(recursive: true));
      final replacement = _envelope('z' * 300);
      await fixture.file('kA').writeAsString(replacement);
      await fixture.rollBack(['kA', 'kB', 'kC']);
      await fixture.store.pruneCacheDirectoryForTest(fixture.root);
      expect(await fixture.store.enforceQuotaLightlyForTest(), greaterThan(0));
      expect(await fixture.file('kA').readAsString(), replacement);
      expect(await fixture.file('kB').exists(), isFalse);
      expect(await fixture.file('kC').exists(), isFalse);
    },
  );

  test('P2-#11: an isolated unchanged rollback remains fail-closed', () async {
    final fixture = await _CacheFixture.create();
    addTearDown(() => fixture.root.delete(recursive: true));
    await fixture.rollBack(['kA']);
    await fixture.store.pruneCacheDirectoryForTest(fixture.root);
    await fixture.store.enforceQuotaLightlyForTest();
    expect(await fixture.file('kA').exists(), isTrue);
    expect(await fixture.file('kB').exists(), isFalse);
  });
}

String _envelope(String payload) =>
    'epub-translation-cache-v1:sha256:${sha256.convert(utf8.encode(payload))}\n$payload';

class _CacheFixture {
  _CacheFixture(this.root, this.store, this.modified);

  final Directory root;
  final TranslationCacheStore store;
  final Map<String, DateTime> modified;

  static Future<_CacheFixture> create({
    List<String> keys = const ['kA', 'kB'],
  }) async {
    final root = await Directory.systemTemp.createTemp('round10_cache_');
    final store = TranslationCacheStore(
      cacheRoot: root,
      maxCacheBytes: 300,
      // Arm maintenance backoff without allowing automatic eviction.
      onMaintenanceScan: () async => throw StateError('scan paused'),
    );
    for (final key in keys) {
      await store.putBlockTranslation(key, 'x' * 300);
      await store.waitForMaintenanceForTest();
    }
    // Use the normal full scanner below, with its default large scan cap;
    // the light pass still uses the instance's small capacity.
    final scanner = TranslationCacheStore(cacheRoot: root, maxCacheBytes: 300);
    await scanner.pruneCacheDirectoryForTest(root);
    final modified = <String, DateTime>{};
    for (final key in keys) {
      modified[key] = await File(
        p.join(root.path, 'blocks', key, '$key.html'),
      ).lastModified();
    }
    return _CacheFixture(root, scanner, modified);
  }

  File file(String key) => File(p.join(root.path, 'blocks', key, '$key.html'));

  Future<void> rollBack(List<String> keys) async {
    for (final key in keys) {
      await file(
        key,
      ).setLastModified(modified[key]!.subtract(const Duration(hours: 2)));
    }
  }
}
