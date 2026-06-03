import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/jobs/presentation/pages/jobs_page.dart';
import '../features/preview/presentation/pages/preview_page.dart';
import '../features/settings/presentation/pages/settings_page.dart';
import '../features/translation/presentation/pages/translation_dashboard_page.dart';
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
