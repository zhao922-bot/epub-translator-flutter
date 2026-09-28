import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/translation/application/translation_dashboard_controller.dart';
import '../../features/settings/application/settings_controller.dart';
import '../localization/app_strings.dart';
import '../models/nav_item.dart';

class AppShell extends ConsumerStatefulWidget {
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
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const MethodChannel _windowDropChannel = MethodChannel(
    'epub_translator/window_drop',
  );

  @override
  void initState() {
    super.initState();
    // Global handler so drop works on any shell route (Translate/Jobs/Preview/Settings).
    _windowDropChannel.setMethodCallHandler(_handleWindowDrop);
    // The corrupt-settings reset can fire during provider initialization,
    // before the first build subscribes the ref.listen below (which only
    // fires on *changes*). Check post-frame so an already-posted notice is
    // not silently lost. Consume-once: the notice is cleared after showing
    // so it can never pop twice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final notice = ref.read(settingsResetNoticeProvider);
      if (notice != null) {
        ref.read(settingsResetNoticeProvider.notifier).state = null;
        _showResetNotice(notice.backupPath);
      }
    });
  }

  @override
  void dispose() {
    _windowDropChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleWindowDrop(MethodCall call) async {
    if (call.method != 'fileDropped') {
      return;
    }
    // Since 1.4.1 the native side sends a map {path, fileCount}; the legacy
    // bare-string payload is still accepted.
    final Object? args = call.arguments;
    final String? droppedPath;
    int fileCount = 1;
    if (args is String) {
      droppedPath = args;
    } else if (args is Map) {
      droppedPath = args['path'] as String?;
      fileCount = (args['fileCount'] as num?)?.toInt() ?? 1;
    } else {
      return;
    }
    if (droppedPath == null || droppedPath.isEmpty) {
      return;
    }
    final bool accepted = await ref
        .read(translationDashboardProvider.notifier)
        .importDroppedEpubPath(droppedPath);
    if (!mounted || !accepted) {
      return;
    }
    // Always land on Translate so the user sees the imported book + logs.
    if (widget.currentLocation != '/') {
      context.go('/');
    }
    final AppStrings strings = ref.read(appStringsProvider);
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (fileCount > 1) {
      // Only the first file was imported; say so instead of silently
      // ignoring the rest.
      messenger?.showSnackBar(
        SnackBar(
          content: Text(strings.dropMultipleFilesNotice(fileCount)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    final String name = droppedPath
        .replaceAll('\\', '/')
        .split('/')
        .where((String part) => part.isNotEmpty)
        .last;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(strings.logDroppedEpub(name)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Shows the corrupt-settings reset notice once and consumes the event so
  /// it can never pop twice (e.g. on rebuilds or hot reload).
  void _showResetNotice(String? backupPath) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          ref.read(appStringsProvider).settingsCorruptResetNotice(backupPath),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final strings = ref.watch(appStringsProvider);

    // A corrupt/unreadable settings.json resets to defaults at startup with
    // only a log line otherwise: warn on every page, not just Settings.
    // Consume-once (clear after showing): the id check alone cannot cover
    // the case where the event fired before this listener subscribed — that
    // is handled by the post-frame check in initState.
    ref.listen(settingsResetNoticeProvider, (previous, next) {
      if (next != null) {
        ref.read(settingsResetNoticeProvider.notifier).state = null;
        _showResetNotice(next.backupPath);
      }
    });
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
      (item) => item.location == widget.currentLocation,
    );
    Widget destination(int index) => _SidebarDestination(
      item: items[index],
      selected: index == selectedIndex,
      onTap: () => context.go(items[index].location),
    );

    return Scaffold(
      key: AppShell.shellKey,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (constraints.maxWidth < 760) {
              return Column(
                children: <Widget>[
                  Expanded(child: widget.child),
                  NavigationBar(
                    selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                    onDestinationSelected: (index) =>
                        context.go(items[index].location),
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
                  width: 72,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    border: Border(
                      right: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      Padding(
                        key: AppShell.brandKey,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Tooltip(
                          message: strings.appTitle,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset(
                              'assets/icons/app_icon.png',
                              width: 32,
                              height: 32,
                              semanticLabel: strings.appTitle,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: <Widget>[
                              for (
                                int index = 0;
                                index < items.length - 1;
                                index++
                              )
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: destination(index),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: destination(items.length - 1),
                      ),
                    ],
                  ),
                ),
                Expanded(child: widget.child),
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      child: Tooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                item.icon,
                size: 21,
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
