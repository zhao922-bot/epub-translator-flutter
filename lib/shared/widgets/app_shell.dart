import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../localization/app_strings.dart';
import '../models/nav_item.dart';

class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.currentLocation,
    required this.child,
  });

  final String currentLocation;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final strings = ref.watch(appStringsProvider);
    final List<NavItem> items = <NavItem>[
      NavItem(
        label: strings.navTranslate,
        icon: Icons.translate_rounded,
        location: '/',
      ),
      NavItem(
        label: strings.navJobs,
        icon: Icons.list_alt_rounded,
        location: '/jobs',
      ),
      NavItem(
        label: strings.navPreview,
        icon: Icons.chrome_reader_mode_rounded,
        location: '/preview',
      ),
      NavItem(
        label: strings.navSettings,
        icon: Icons.settings_rounded,
        location: '/settings',
      ),
    ];

    final int selectedIndex = items.indexWhere(
      (item) => item.location == currentLocation,
    );

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool useBottomNavigation = constraints.maxWidth < 900;
            final bool compactSidebar = constraints.maxHeight < 720;
            if (useBottomNavigation) {
              return Column(
                children: <Widget>[
                  Expanded(child: child),
                  NavigationBar(
                    selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                    onDestinationSelected: (index) {
                      context.go(items[index].location);
                    },
                    destinations: items
                        .map(
                          (item) => NavigationDestination(
                            icon: Icon(item.icon),
                            label: item.label,
                          ),
                        )
                        .toList(),
                  ),
                ],
              );
            }

            return Row(
              children: <Widget>[
                Container(
                  width: 220,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          compactSidebar ? 16 : 20,
                          20,
                          compactSidebar ? 12 : 16,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/icons/app_icon.png',
                                width: compactSidebar ? 36 : 48,
                                height: compactSidebar ? 36 : 48,
                                fit: BoxFit.cover,
                              ),
                            ),
                            SizedBox(height: compactSidebar ? 10 : 14),
                            Text(
                              strings.appTitle,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              strings.appSubtitle,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: NavigationRail(
                          selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                          extended: true,
                          groupAlignment: -1,
                          destinations: items
                              .map(
                                (item) => NavigationRailDestination(
                                  icon: Icon(item.icon),
                                  label: Text(item.label),
                                ),
                              )
                              .toList(),
                          onDestinationSelected: (index) {
                            context.go(items[index].location);
                          },
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          compactSidebar ? 12 : 20,
                          20,
                          compactSidebar ? 12 : 20,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(compactSidebar ? 10 : 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  strings.shellStatus,
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  strings.shellStatusBody,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            );
          },
        ),
      ),
    );
  }
}
