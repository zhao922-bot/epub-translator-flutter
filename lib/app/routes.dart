import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/jobs/presentation/pages/jobs_page.dart';
import '../features/preview/presentation/pages/preview_page.dart';
import '../features/settings/presentation/pages/settings_page.dart';
import '../features/translation/domain/models/translation_config.dart';
import '../features/translation/presentation/pages/translation_dashboard_page.dart';
import '../features/translation/presentation/pages/translation_manual_review_page.dart';
import '../features/translation/presentation/pages/translation_review_page.dart';
import '../shared/localization/app_strings.dart';
import '../shared/localization/review_strings.dart';
import '../shared/widgets/app_shell.dart';

enum AppRoute {
  translation('/'),
  jobs('/jobs'),
  preview('/preview'),
  settings('/settings');

  const AppRoute(this.path);

  final String path;
}

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoute.translation.path,
  routes: <RouteBase>[
    GoRoute(
      path: TranslationReviewRouteData.location,
      builder: (context, state) {
        final data = state.extra;
        if (data is! TranslationReviewRouteData) {
          return const _MissingReviewData();
        }
        return TranslationReviewPage(
          reportPath: data.reportPath,
          outputPath: data.outputPath,
          isChinese: data.isChinese,
        );
      },
    ),
    GoRoute(
      path: ManualReviewRouteData.location,
      pageBuilder: (context, state) {
        final data = state.extra;
        return MaterialPage<ManualReviewSelection>(
          key: state.pageKey,
          child: data is ManualReviewRouteData
              ? TranslationManualReviewPage.fromRoute(data)
              : const _MissingReviewData(manual: true),
        );
      },
    ),
    ShellRoute(
      builder: (BuildContext context, GoRouterState state, Widget child) {
        return AppShell(currentLocation: state.matchedLocation, child: child);
      },
      routes: <RouteBase>[
        GoRoute(
          path: AppRoute.translation.path,
          pageBuilder: (context, state) =>
              const NoTransitionPage<void>(child: TranslationDashboardPage()),
        ),
        GoRoute(
          path: AppRoute.jobs.path,
          pageBuilder: (context, state) =>
              const NoTransitionPage<void>(child: JobsPage()),
        ),
        GoRoute(
          path: AppRoute.preview.path,
          pageBuilder: (context, state) =>
              const NoTransitionPage<void>(child: PreviewPage()),
        ),
        GoRoute(
          path: AppRoute.settings.path,
          pageBuilder: (context, state) =>
              const NoTransitionPage<void>(child: SettingsPage()),
        ),
      ],
    ),
  ],
);

class _MissingReviewData extends StatelessWidget {
  const _MissingReviewData({this.manual = false});

  final bool manual;

  @override
  Widget build(BuildContext context) {
    if (context
            .getElementForInheritedWidgetOfExactType<
              UncontrolledProviderScope
            >() !=
        null) {
      return Consumer(
        builder: (context, ref, _) =>
            _page(context, ref.watch(appStringsProvider)),
      );
    }
    final language = Localizations.localeOf(context).languageCode == 'zh'
        ? UiLanguage.chinese
        : UiLanguage.english;
    return _page(context, AppStrings(language));
  }

  Widget _page(BuildContext context, AppStrings strings) => Scaffold(
    appBar: AppBar(
      title: Text(
        manual ? strings.manualReviewTitle : strings.translationReviewTitle,
      ),
    ),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.missingReviewData, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go(AppRoute.translation.path),
              child: Text(strings.navTranslate),
            ),
          ],
        ),
      ),
    ),
  );
}
