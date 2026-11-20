import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../application/settings_controller.dart';
import '../widgets/settings_api_section.dart';
import '../widgets/settings_appearance_section.dart';
import '../widgets/settings_notices.dart';
import '../widgets/settings_translation_section.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with WidgetsBindingObserver {
  final _apiSection = GlobalKey<SettingsApiSectionState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(settingsProvider.notifier).flushSliderChanges());
      final apiSection = _apiSection.currentState;
      if (apiSection != null) unawaited(apiSection.commitPendingFields());
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    return PageScaffold(
      title: strings.settingsTitle,
      subtitle: strings.settingsSubtitle,
      child: Column(
        children: [
          const SettingsNotices(),
          SettingsApiSection(key: _apiSection),
          const SizedBox(height: 14),
          const SettingsTranslationSection(),
          const SizedBox(height: 28),
          const SettingsAppearanceSection(),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
