import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../../translation/domain/models/api_provider_preset.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../../translation/infrastructure/epub/translation_api_client.dart';
import '../../application/custom_endpoint_template.dart';
import '../../application/settings_controller.dart';
import '../../infrastructure/settings_store.dart';
import 'settings_copy.dart';
import 'settings_fields.dart';
import 'settings_sections.dart';

class SettingsApiSection extends ConsumerStatefulWidget {
  const SettingsApiSection({super.key});

  @override
  ConsumerState<SettingsApiSection> createState() => SettingsApiSectionState();
}

class SettingsApiSectionState extends ConsumerState<SettingsApiSection> {
  final _connectionFields = List.generate(
    4,
    (_) => GlobalKey<SettingsTextFieldState>(),
  );
  bool _committingConnectionFields = false;

  Future<bool> commitPendingFields() async {
    // Capture every field before settings notifications rebuild the page.
    // Commit the key first so it still belongs to the displayed provider.
    final results = await Future.wait([
      for (final index in [1, 0, 2, 3])
        if (_connectionFields[index].currentState case final field?)
          field.commitPending(),
    ]);
    return results.every((succeeded) => succeeded);
  }

  Future<void> _selectProvider(ApiProviderPreset preset) async {
    if (_committingConnectionFields) return;
    setState(() => _committingConnectionFields = true);
    try {
      if (!await commitPendingFields()) return;
      if (!mounted || ref.read(translationDashboardProvider).isRunActive) {
        return;
      }
      await ref.read(settingsProvider.notifier).applyApiProviderPreset(preset);
    } finally {
      if (mounted) setState(() => _committingConnectionFields = false);
    }
  }

  Future<void> _applyTemplate(CustomEndpointTemplate template) async {
    if (_committingConnectionFields) return;
    setState(() => _committingConnectionFields = true);
    try {
      if (!await commitPendingFields() || !mounted) return;
      if (ref.read(translationDashboardProvider).isRunActive) return;
      final config = ref.read(settingsProvider);
      if (config.apiProviderSelection != ApiProviderSelection.custom) return;
      TranslationConfig? approvedCredentialConfig;
      if (config.apiKey.isNotEmpty &&
          template.changesOrigin(config.apiBaseUrl)) {
        final strings = ref.read(appStringsProvider);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(strings.confirmEndpointChange),
            content: Text(strings.savedKeyEndpointChange(template.baseUrl)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(strings.cancelRun),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(strings.useEndpoint),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        if (ref.read(translationDashboardProvider).isRunActive) return;
        approvedCredentialConfig = config;
      }
      await ref
          .read(settingsProvider.notifier)
          .applyCustomEndpointTemplate(
            template,
            approvedCredentialConfig: approvedCredentialConfig,
          );
    } finally {
      if (mounted) setState(() => _committingConnectionFields = false);
    }
  }

  Future<void> _testConnection() async {
    if (_committingConnectionFields ||
        !ref.read(settingsProvider.notifier).canTestConnection) {
      return;
    }
    setState(() => _committingConnectionFields = true);
    try {
      if (!await commitPendingFields()) return;
    } finally {
      if (mounted) setState(() => _committingConnectionFields = false);
    }
    if (!mounted || ref.read(translationDashboardProvider).isRunActive) return;
    await ref
        .read(connectionTestProvider.notifier)
        .run(ref.read(settingsProvider));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(settingsProvider.notifier);
    final config = ref.watch(
      settingsProvider.select(
        (c) => (
          apiBaseUrl: c.apiBaseUrl,
          apiKey: c.apiKey,
          model: c.model,
          selection: c.apiProviderSelection,
          httpProxy: c.httpProxy,
          useStreamingApi: c.useStreamingApi,
          providerRevision: controller.providerSelectionRevision,
          credentialRevision: controller.credentialDiscardRevision,
          apiKeyReadFailed: controller.secretReadFailed(
            c.apiProviderSelection == ApiProviderSelection.deepseek
                ? SettingsSecretSlot.deepSeek
                : SettingsSecretSlot.custom,
          ),
          proxyReadFailed: controller.secretReadFailed(
            SettingsSecretSlot.proxy,
          ),
          canTestConnection: controller.canTestConnection,
        ),
      ),
    );
    final isRunActive = ref.watch(
      translationDashboardProvider.select((state) => state.isRunActive),
    );
    final settingsLoaded =
        ref.watch(settingsLoadedProvider.select((value) => value.hasValue)) &&
        config.canTestConnection;
    final connectionTestState = ref.watch(connectionTestProvider);
    final strings = ref.watch(appStringsProvider);
    final selectedPreset = switch (config.selection) {
      ApiProviderSelection.deepseek => ApiProviderPreset.deepseek,
      ApiProviderSelection.custom => ApiProviderPreset.custom,
    };
    final endpointEditingEnabled = !isRunActive && !_committingConnectionFields;
    return SettingsSection(
      title: strings.apiSection,
      icon: Icons.cloud_outlined,
      trailing: FilledButton.tonalIcon(
        onPressed:
            connectionTestState.isLoading ||
                !settingsLoaded ||
                isRunActive ||
                _committingConnectionFields
            ? null
            : _testConnection,
        icon: connectionTestState.isLoading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_tethering_rounded, size: 18),
        label: Text(
          connectionTestState.isLoading
              ? strings.testingConnection
              : strings.testConnection,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final preset in ApiProviderPreset.values)
                ChoiceChip(
                  key: ValueKey<String>('api-provider-${preset.name}'),
                  label: Text(preset.label),
                  selected: preset == selectedPreset,
                  onSelected: endpointEditingEnabled
                      ? (_) => _selectProvider(preset)
                      : null,
                ),
              if (selectedPreset == ApiProviderPreset.custom)
                PopupMenuButton<CustomEndpointTemplate>(
                  key: const ValueKey('settings-endpoint-templates'),
                  tooltip: strings.endpointTemplates,
                  enabled: settingsLoaded && endpointEditingEnabled,
                  onSelected: _applyTemplate,
                  itemBuilder: (context) => [
                    for (final template in CustomEndpointTemplate.values)
                      PopupMenuItem(
                        value: template,
                        child: Text(template.label),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(strings.endpointTemplates),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsTextField(
            key: _connectionFields[0],
            strings: strings,
            fieldKey: const ValueKey<String>('settings-api-base-url'),
            readOnly: _committingConnectionFields,
            value: config.apiBaseUrl,
            onChanged: controller.setApiBaseUrl,
            onCommit: controller.setApiBaseUrl,
            resetKey: config.providerRevision,
            enabled: !isRunActive,
            decoration: InputDecoration(
              labelText: strings.baseUrl,
              prefixIcon: const Icon(Icons.cloud_outlined),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SettingsTextField(
            key: _connectionFields[1],
            strings: strings,
            fieldKey: const ValueKey<String>('settings-api-key'),
            readOnly: _committingConnectionFields,
            value: config.apiKey,
            onChanged: controller.setApiKey,
            onCommit: controller.setApiKey,
            resetKey: (config.providerRevision, config.credentialRevision),
            obscureText: true,
            canToggleObscureText: true,
            enabled: !isRunActive,
            decoration: InputDecoration(
              labelText: strings.apiKey,
              helperText: config.apiKeyReadFailed
                  ? strings.credentialReadFailed
                  : config.apiBaseUrl ==
                            CustomEndpointTemplate.ollama.baseUrl &&
                        config.apiKey.isEmpty
                  ? strings.ollamaKeyHint
                  : null,
              prefixIcon: const Icon(Icons.key_outlined),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SettingsTextField(
            key: _connectionFields[2],
            strings: strings,
            fieldKey: const ValueKey<String>('settings-model'),
            readOnly: _committingConnectionFields,
            value: config.model,
            onChanged: controller.setModel,
            onCommit: controller.setModel,
            resetKey: config.providerRevision,
            enabled: !isRunActive,
            decoration: InputDecoration(
              labelText: strings.model,
              prefixIcon: const Icon(Icons.memory_rounded),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SettingsTextField(
            key: _connectionFields[3],
            strings: strings,
            fieldKey: const ValueKey<String>('settings-http-proxy'),
            readOnly: _committingConnectionFields,
            value: config.httpProxy,
            onChanged: controller.setHttpProxy,
            onCommit: controller.setHttpProxy,
            showSecretTooltip: strings.showProxyCredentials,
            hideSecretTooltip: strings.hideProxyCredentials,
            obscureText: true,
            canToggleObscureText: true,
            visibilityToggleKey: const ValueKey<String>(
              'toggleProxyVisibility',
            ),
            enabled: !isRunActive,
            decoration: InputDecoration(
              labelText: strings.httpProxy,
              helperText: config.proxyReadFailed
                  ? strings.credentialReadFailed
                  : null,
              hintText: strings.httpProxyHint,
              prefixIcon: const Icon(Icons.vpn_lock_outlined),
              isDense: true,
              // Invalid values are treated as "no proxy" by the HTTP
              // client; surface that here instead of letting the user
              // discover it through a mysterious connection failure.
              errorText: switch (TranslationApiClient.validateProxySetting(
                config.httpProxy,
              )) {
                null => null,
                ProxySettingError.unsupportedScheme =>
                  strings.httpProxyUnsupportedScheme,
                ProxySettingError.invalidFormat =>
                  strings.httpProxyInvalidFormat,
              },
            ),
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('settings-use-streaming-api'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(strings.streamingApi),
            subtitle: Text(strings.streamingApiBody),
            value: config.useStreamingApi,
            onChanged: endpointEditingEnabled
                ? controller.setUseStreamingApi
                : null,
          ),
          const SizedBox(height: 10),
          switch (connectionTestState) {
            AsyncData<String?>(:final value)
                when value != null && value.isNotEmpty =>
              ConnectionBanner(
                title: strings.connectionOk,
                body: value,
                isError: false,
              ),
            AsyncError(:final error) => ConnectionBanner(
              title: strings.connectionFailed,
              body: '$error',
              isError: true,
            ),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}
