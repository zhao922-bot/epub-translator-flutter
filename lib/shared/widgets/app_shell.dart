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

  static const Key brandKey = ValueKey<String>('app-shell-brand');
  static const Key shellKey = ValueKey<String>('app-shell');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
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
      key: shellKey,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool useBottomNavigation = constraints.maxWidth < 900;
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
                            selectedIcon: Icon(item.icon),
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
                  width: 244,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Color(0xFF152842), Color(0xFF0D1728)],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        key: brandKey,
                        padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.asset(
                                    'assets/icons/app_icon.png',
                                    fit: BoxFit.cover,
                                    semanticLabel: strings.appTitle,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    strings.appTitle,
                                    style: textTheme.titleMedium?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.25,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    strings.appSubtitle,
                                    style: textTheme.bodySmall?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.64,
                                      ),
                                      fontSize: 11.5,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (BuildContext context, int index) {
                            return _SidebarDestination(
                              item: items[index],
                              selected: index == selectedIndex,
                              onTap: () => context.go(items[index].location),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              Icons.auto_stories_outlined,
                              size: 16,
                              color: Colors.white.withValues(alpha: 0.48),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                strings.appSubtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelMedium?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.48),
                                ),
                              ),
                            ),
                          ],
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

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color foreground = selected
        ? const Color(0xFF162B49)
        : Colors.white.withValues(alpha: 0.72);

    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      child: Material(
        color: selected
            ? const Color(0xFFEAF1FF)
            : Colors.white.withValues(alpha: 0.001),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: <Widget>[
                Icon(item.icon, size: 21, color: foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    style: textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4E78B2),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
