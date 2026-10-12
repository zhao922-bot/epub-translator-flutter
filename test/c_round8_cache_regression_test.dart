import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每个 block entry 约 120B（22B 正文 + 98B integrity envelope）。
const int _entryBytes = 22 + 98;

JobResumeState _jobState(String jobKey, {int completedBlocks = 10}) =>
    JobResumeState(
      jobKey: jobKey,
      inputFingerprint: 'fp',
      inputPath: '/in.epub',
      outputPath: '/out.epub',
      status: 'running',
      completedFiles: 1,
      totalFiles: 3,
      completedBlocks: completedBlocks,
      totalBlocks: 30,
      cachedBlocks: 5,
      resumedBlocks: 2,
      currentChapter: 'ch2',
      updatedAtIso8601: '2026-10-12T00:00:00Z',
    );

void main() {
  group('C-4 超限时 backoff 不被 interval 架空', () {
    test('backoff 激活时跳过全盘扫描但仍做轻量配额强制；解除后恢复扫描', () async {
      final root = await Directory.systemTemp.createTemp('c8_c4_');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime(2026);
      int scans = 0;
      bool perturb = true;
      final store = TranslationCacheStore(
        cacheRoot: root,
        maxCacheBytes: 1000,
        now: () => now,
        onMaintenanceScan: () async {
          scans++;
          if (perturb) {
            // 模拟"不可回收"：全盘扫描直接失败 → ineffective → backoff
            // 被 arm。抛异常不碰文件 mtime，轻量配额强制的 mtime 校验
            // 不受影响（P2-#11 后，旧的改 mtime 模拟会误伤轻量删除）。
            throw StateError('simulated unscannable cache');
          }
        },
      );

      String key(int i) => 'aa${i.toString().padLeft(2, '0')}';
      for (int i = 1; i <= 9; i++) {
        await store.putBlockTranslation(key(i), 'x' * 22);
      }
      await store.waitForMaintenanceForTest();
      // baseline 扫描 + 第一次超限触发的全盘扫描（ineffective → backoff armed）。
      expect(scans, 2);
      expect(store.estimatedCacheBytesForTest, greaterThan(1000));

      // 时间推进超过 pruneInterval：旧代码会在这里再做一次全盘扫描。
      now = now.add(const Duration(minutes: 6));
      await store.putBlockTranslation('bb01', 'y' * 22);
      await store.waitForMaintenanceForTest();

      // backoff 激活：全盘扫描被跳过（旧代码 scans 会变成 3）。
      expect(scans, 2);
      // 但轻量配额强制仍执行：删到 90% cap 以下（恰好删掉 3 个 entry）。
      // 注：perturb 把 mtime 都抬到同一秒内，rebuild 后的"最老优先"顺序
      // 依赖文件系统枚举顺序，故只断言删够 3 个、最新的 bb01 必定保留。
      expect(store.estimatedCacheBytesForTest, lessThanOrEqualTo(900));
      expect(store.estimatedCacheBytesForTest, 7 * _entryBytes);
      int gone = 0;
      for (int i = 1; i <= 9; i++) {
        if (await store.getBlockTranslation(key(i)) == null) gone++;
      }
      expect(gone, 3);
      expect(await store.getBlockTranslation('bb01'), isNotNull);

      // 轻量清理把用量带回 cap 以下 → backoff 重置（与过期走同一条
      // _backoffActive() == false 分支）；再超限时恢复全盘扫描。
      perturb = false;
      now = now.add(const Duration(minutes: 6));
      await store.putBlockTranslation('cc01', 'z' * 500);
      await store.waitForMaintenanceForTest();
      expect(scans, 3);
    });
  });

  group('C-5 clearJobState 走 per-file gate', () {
    test('并发 clear + save 不丢刚写入的 checkpoint', () async {
      final root = await Directory.systemTemp.createTemp('c8_c5_');
      addTearDown(() => root.delete(recursive: true));
      final store = TranslationCacheStore(cacheRoot: root);

      // 新 key：clear 先发，gate 保证串行、save 后至 → checkpoint 存活。
      for (int i = 0; i < 5; i++) {
        final jobKey = 'fresh-job-$i';
        await Future.wait([
          store.clearJobState(jobKey),
          store.saveJobState(_jobState(jobKey)),
        ]);
        final loaded = await store.loadJobState(jobKey);
        expect(loaded, isNotNull, reason: jobKey);
        expect(loaded!.jobKey, jobKey);
        expect(loaded.completedBlocks, 10);
      }

      // 已有 checkpoint：clear 先发删掉旧的，save 后至写入新的。
      const jobKey = 'existing-job';
      await store.saveJobState(_jobState(jobKey, completedBlocks: 10));
      await Future.wait([
        store.clearJobState(jobKey),
        store.saveJobState(_jobState(jobKey, completedBlocks: 20)),
      ]);
      final loaded = await store.loadJobState(jobKey);
      expect(loaded, isNotNull);
      expect(loaded!.completedBlocks, 20);
    });
  });
}
