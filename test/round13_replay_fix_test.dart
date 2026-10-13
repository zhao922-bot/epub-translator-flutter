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

  /// Error thrown for [failAttemptNumber]; defaults to StateError.
  Object Function()? failAttemptErrorFactory;

  /// When true, a save throwing [SettingsWriteConflict] also records a
  /// load error (like the real store), so the next replay iteration
  /// auto-recovers via a fresh load — which bumps the state generation and
  /// makes the P2-#22 applied-generation check stale. Off by default to
  /// keep the queueing phase of tests free of auto-recovery noise.
  bool conflictSetsLoadError = false;
  Object? _loadError;

  /// When set, save() waits on this gate (for orchestrating races).
  Completer<void>? saveGate;
  Completer<void>? saveStarted;

  @override
  Future<TranslationConfig> load() async {
    _loadError = null;
    return persisted;
  }

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
      final Object error =
          failAttemptErrorFactory?.call() ?? StateError('injected disk failure');
      _recordConflictLoadError(error);
      throw error;
    }
    final error = saveError;
    if (error != null) {
      _recordConflictLoadError(error);
      throw error;
    }
    persisted = config;
  }

  void _recordConflictLoadError(Object error) {
    if (conflictSetsLoadError && error is SettingsWriteConflict) {
      _loadError = StateError('stale snapshot after write conflict');
    }
  }

  @override
  Object? get configLoadError => _loadError;
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

  group('P2-#28 changedFields includes swallowed slider fields', () {
    test(
        'non-replay swallow: B supersedes the stale slider entry A it '
        'swallowed', () async {
      // ① Slider 4->8, flush hits a write conflict -> queued as A with
      // changedFields={chunkSize}.
      store.saveError = SettingsWriteConflict();
      final s1 = controller.setChunkSize(8);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await s1;

      // ② Slider 8->10, then a bilingual toggle within 400ms swallows the
      // pending slider; the save conflicts -> queued as B. B's changedFields
      // must contain chunkSize (the swallowed slider field), not just
      // bilingual: prevState already holds the slider's optimistic value,
      // so diffing against the post-swallow state alone misses it.
      final s2 = controller.setChunkSize(10);
      await controller.setBilingual(true);
      await s2;

      // Replay pass 1: A's save conflicts again. The conflict triggers a
      // mid-pass recovery load, bumping the state generation so the P2-#22
      // applied-generation check goes stale — only the P2-#28 field-overlap
      // check can drop A. Then B succeeds, persisting chunkSize=10.
      store.saveError = null;
      store.conflictSetsLoadError = true;
      store.attemptCount = 0;
      store.failAttemptNumber = 1;
      store.failAttemptErrorFactory = () => SettingsWriteConflict();
      await controller.reloadSettings();
      expect(store.persisted.chunkSize, 10);
      expect(store.persisted.bilingual, isTrue);

      // Replay pass 2: with the bug, stale A survived (its {chunkSize} did
      // not overlap B's {bilingual}) and now replays chunkSize=8, silently
      // rolling back the user's 10.
      store.failAttemptNumber = null;
      store.attempts.clear();
      await controller.reloadSettings();
      expect(
        store.persisted.chunkSize,
        10,
        reason: 'Stale slider entry A must have been dropped when B succeeded',
      );
      expect(
        store.attempts,
        isEmpty,
        reason: 'No queued edits should remain after B superseded A',
      );
    });

    test(
        'replay swallow: justChanged merges slider fields swallowed '
        'mid-replay', () async {
      // Queue A (slider 4->8) and C (bilingual toggle) via conflicts.
      store.saveError = SettingsWriteConflict();
      final s1 = controller.setChunkSize(8);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await s1;
      await controller.setBilingual(true);

      // Replay pass 1: stall A's save; while stalled, drag the slider to 10
      // so it is still pending when C's replay swallows it. A's save then
      // conflicts (mid-pass load bumps the generation, staling the P2-#22
      // check); C's replay succeeds and persists chunkSize=10 — and must
      // drop stale A via field overlap on the swallowed slider field.
      store.saveError = null;
      store.conflictSetsLoadError = true;
      store.attemptCount = 0;
      store.failAttemptNumber = 1;
      store.failAttemptErrorFactory = () => SettingsWriteConflict();
      final gate = Completer<void>();
      store.saveGate = gate;
      store.saveStarted = Completer<void>();
      final reload = controller.reloadSettings();
      await store.saveStarted!.future;
      // A's replay save is stalled. Move the slider now.
      final slider = controller.setChunkSize(10);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // Release the stalled save; it now fails with a write conflict.
      gate.complete();
      await reload;
      await slider;
      expect(store.persisted.chunkSize, 10);
      expect(store.persisted.bilingual, isTrue);

      // Replay pass 2: with the bug, C's justChanged was only {bilingual},
      // so stale A survived and now rolls chunkSize 10->8.
      store.failAttemptNumber = null;
      store.attempts.clear();
      await controller.reloadSettings();
      expect(
        store.persisted.chunkSize,
        10,
        reason: 'Stale slider entry A must have been dropped when C\'s replay '
            'persisted the swallowed slider value',
      );
      expect(
        store.attempts,
        isEmpty,
        reason: 'No queued edits should remain after C superseded A',
      );
    });
  });
}
