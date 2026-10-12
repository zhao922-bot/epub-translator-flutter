import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/localization/app_strings.dart';
import '../../translation/application/translation_dashboard_controller.dart';
import '../domain/models/preview_chapter.dart';
import 'preview_recovery.dart';

export 'preview_recovery.dart' show previewChapterFromInspected;

final previewRecoveryCacheProvider = Provider((ref) => PreviewRecoveryCache());

final previewRecoveryProvider = FutureProvider<void>((ref) async {
  final chapters = ref.watch(
    translationDashboardProvider.select((s) => s.inspectedChapters),
  );
  await ref.read(previewRecoveryCacheProvider).prepare(chapters);
});

final previewSelectedIndexProvider = StateProvider<int>((ref) => 0);

final previewChaptersProvider = Provider<List<PreviewChapter>>((ref) {
  // Only the inspected chapters matter here; a plain watch of the whole
  // dashboard state would rebuild the preview on every log tick.
  final chapters = ref.watch(
    translationDashboardProvider.select((s) => s.inspectedChapters),
  );
  // Recovery runs off the UI isolate. Completion invalidates this projection;
  // lookup checks the exact content version, including during an in-flight load.
  ref.watch(previewRecoveryProvider);
  final cache = ref.watch(previewRecoveryCacheProvider);
  if (chapters.isEmpty) {
    // Currently unreachable (the preview page renders strings.noPreviewYet
    // for the empty state), but keep it localized in case the fallback is
    // ever surfaced.
    final AppStrings strings = ref.watch(appStringsProvider);
    return <PreviewChapter>[
      PreviewChapter(
        title: strings.previewFallbackTitle,
        body: strings.noPreviewYet,
        path: '',
        category: strings.previewFallbackCategory,
        recommendedForTranslation: false,
        includeInTranslation: false,
        blockCount: 0,
        translatedBlockCount: 0,
      ),
    ];
  }

  return chapters.map((chapter) {
    final recovered = cache.lookup(chapter);
    return projectPreviewChapter(
      chapter,
      source:
          recovered?.body ??
          (needsPreviewRecovery(chapter) ? '' : chapter.body),
      translated: recovered?.translatedBody ?? chapter.translatedBody,
    );
  }).toList();
});
