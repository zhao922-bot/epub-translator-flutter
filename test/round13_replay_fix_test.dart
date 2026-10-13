import 'dart:async';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReplayStore extends SettingsStore {
  TranslationConfig persisted = TranslationConfig.defaults();
  Object? saveError;

  /// When non-null, fail the save with this 1-based attempt number.
  int? failAttemptNumber;
  int attemptCount = 0;
  final attempts = <String>[];

  /// When set, save() waits on this gate (for orchestrating races).
  Completer<void>? saveGate;
  Completer<void>? saveStarted;

  @override
  Future<TranslationConfig> load() async => persisted;

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attemptCount++;
    attempts.add(config.outputSuffix);
    final gate = saveGate;
    if (gate != null) {
      saveGate = null;
      saveStarted?.complete();
      await gate.future;
    }
    if (failAttemptNumber == attemptCount) {
      throw StateError('injected disk failure');
    }
    final error = saveError;
    if (error != null) throw error;
    persisted = config;
  }

  @override
  Object? get configLoadError => null;
}

void main() {
  late _ReplayStore store;
  late SettingsController controller;
  late List<Object?> notices;

  setUp(() async {
    store = _ReplayStore();
    notices = <Object?>[];
    controller = SettingsController(store, onSaveError: notices.add);
    addTearDown(controller.dispose);
    await controller.ready;
  });

  group('P2-#28 superseded queue entries are dropped', () {
    test('B is dropped when C changes the same field after B failed',
        () async {
      store.saveError = SettingsWriteConflict();
      expect(await controller.setOutputSuffix('_a'), isFalse);
      expect(await controller.setOutputSuffix('_b'), isFalse);
      expect(await controller.setOutputSuffix('_c'), isFalse);
      store.saveError = null;

      // Replay: fail the 2nd save (B), let A and C succeed.
      store.failAttemptNumber = 2;
      await controller.reloadSettings();
      expect(store.persisted.outputSuffix, '_c',
          reason: 'C (newest) must win');
      store.failAttemptNumber = null;

      // Next reload must NOT re-apply stale B.
      store.attempts.clear();
      await controller.reloadSettings();
      expect(store.persisted.outputSuffix, '_c',
          reason: 'Stale B must not revert C\'s newer value');
      expect(store.attempts, isEmpty,
          reason: 'B must have been dropped when C succeeded');
    });

    test('edits to different fields are retained', () async {
      store.saveError = SettingsWriteConflict();
      expect(await controller.setOutputSuffix('_x'), isFalse);
      store.saveError = null;
      await controller.reloadSettings();
      expect(store.persisted.outputSuffix, '_x');
      store.attempts.clear();
      await controller.reloadSettings();
      expect(store.attempts, isEmpty);
    });
  });

  group('P2-#29 slider wins during replay', () {
    test('swallowed slider (newer) beats queued replay (older) on same field',
        () async {
      // Queue TWO chunkSize edits via conflicted debounced flushes.
      store.saveError = SettingsWriteConflict();
      final s1 = controller.setChunkSize(60);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await s1;
      final s2 = controller.setChunkSize(70);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await s2;
      store.saveError = null;
      // Queue now: [chunkSize=60, chunkSize=70]. Persisted is still default.

      // Replay with a stalled first save. During the stall, move the slider
      // to 100. The second replay item will swallow the pending slider.
      // The slider (100, newer) must beat the queued edit (70, older).
      final gate = Completer<void>();
      store.saveGate = gate;
      store.saveStarted = Completer<void>();
      final reload = controller.reloadSettings();
      await store.saveStarted!.future;
      // First replay item's save is stalled. Move the slider now.
      final slider = controller.setChunkSize(100);
      // Let the slider's _update run (it waits for load phase, which is done).
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // Release the stalled save.
      gate.complete();
      await reload;
      try {
        await slider.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Swallowed by the second replay item; its save completed the future.
      }

      expect(controller.state.chunkSize, 100,
          reason: 'Slider (newer) must win over queued replay (older)');
      expect(store.persisted.chunkSize, 100,
          reason: 'Persisted value must be the slider value');
    });
  });
}
