import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../application/settings_controller.dart';
import 'settings_fields.dart';
import 'settings_sections.dart';
import 'settings_slider.dart';

class SettingsTranslationSection extends ConsumerWidget {
  const SettingsTranslationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final config = ref.watch(
      settingsProvider.select(
        (c) => (
          residualQualityCheck: c.residualQualityCheck,
          styleProfileEnabled: c.styleProfileEnabled,
        ),
      ),
    );
    final isRunActive = ref.watch(
      translationDashboardProvider.select((state) => state.isRunActive),
    );
    return SettingsSection(
      title: strings.translationSection,
      icon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _TuningPresetSelector(enabled: !isRunActive),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(strings.residualQualityCheck),
            subtitle: Text(strings.residualQualityCheckBody),
            value: config.residualQualityCheck,
            onChanged: isRunActive ? null : controller.setResidualQualityCheck,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(strings.styleProfileEnabled),
            subtitle: Text(strings.styleProfileEnabledBody),
            value: config.styleProfileEnabled,
            onChanged: isRunActive ? null : controller.setStyleProfileEnabled,
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(strings.advancedTuning),
            children: [_AdvancedTuning(isRunActive: isRunActive)],
          ),
          const SizedBox(height: 4),
          Text(
            strings.supportedPlatformsNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _TuningPresetSelector extends ConsumerWidget {
  const _TuningPresetSelector({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      settingsProvider.select(
        (c) => (
          c.chunkSize,
          c.maxConcurrent,
          c.timeoutSeconds,
          c.maxRetries,
          c.retryDelaySeconds,
        ),
      ),
    );
    return TuningPresetSelector(
      config: ref.read(settingsProvider),
      controller: ref.read(settingsProvider.notifier),
      strings: ref.watch(appStringsProvider),
      enabled: enabled,
    );
  }
}

class _AdvancedTuning extends ConsumerWidget {
  const _AdvancedTuning({required this.isRunActive});

  final bool isRunActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final config = ref.watch(
      settingsProvider.select(
        (c) => (
          reasoningEffort: c.reasoningEffort,
          semanticQualityCheck: c.semanticQualityCheck,
          autoApplyVerifiedCorrections: c.autoApplyVerifiedCorrections,
          retryIncompleteReviews: c.retryIncompleteReviews,
          semanticReviewScope: c.semanticReviewScope,
          outputSuffix: c.outputSuffix,
          lockedGlossary: c.lockedGlossary,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<ModelReasoningEffort>(
          key: ValueKey('reasoning-${config.reasoningEffort.name}'),
          initialValue: config.reasoningEffort,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: strings.isChinese ? '模型推理强度' : 'Model reasoning effort',
          ),
          items: [
            for (final value in ModelReasoningEffort.values)
              DropdownMenuItem(
                value: value,
                child: Text(switch (value) {
                  ModelReasoningEffort.automatic =>
                    strings.isChinese ? '自动（按模型适配）' : 'Automatic (model-aware)',
                  ModelReasoningEffort.low => strings.isChinese ? '较低' : 'Low',
                  ModelReasoningEffort.high =>
                    strings.isChinese ? '较高' : 'High',
                  ModelReasoningEffort.max =>
                    strings.isChinese ? '最高' : 'Maximum',
                }),
              ),
          ],
          onChanged: isRunActive
              ? null
              : (value) {
                  if (value != null) {
                    controller.setReasoningEffort(value);
                  }
                },
        ),
        Text(
          strings.isChinese
              ? '自动为已验证接口选择较低强度或关闭推理；手动选项需要接口支持。'
              : 'Automatic uses low effort or disables thinking for verified APIs; manual options require API support.',
        ),
        SettingsSlider(
          inputKey: const ValueKey('settings-maxOutputTokens'),
          select: (c) => c.maxOutputTokens.toDouble(),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '单次输出上限 ${v.round()} tokens'
              : 'Output limit ${v.round()} tokens',
          label: (v) => strings.isChinese
              ? '单次输出上限：${v.round()} tokens'
              : 'Output limit: ${v.round()} tokens',
          min: 512,
          max: 32768,
          divisions: 63,
          onChanged: isRunActive ? null : controller.setMaxOutputTokens,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            strings.isChinese ? '译文语义复核' : 'Semantic translation review',
          ),
          subtitle: Text(
            strings.isChinese
                ? '检查事实、数字、币种与术语，再请求模型复核。默认仅提出建议；可在下方开启自动修正。额外请求会产生 API 费用。'
                : 'Check facts, numbers, currencies and terms, then request model review. Suggestions only by default; automatic correction can be enabled below. Additional API calls incur costs.',
          ),
          value: config.semanticQualityCheck,
          onChanged: isRunActive ? null : controller.setSemanticQualityCheck,
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            strings.isChinese
                ? '自动应用已验证的修正'
                : 'Automatically apply verified corrections',
          ),
          subtitle: Text(
            strings.isChinese
                ? '仅应用有原文证据、通过结构检查且经另一独立请求复核确认的修正；保留修改记录，其余留为建议。需要开启语义复核，会增加 API 请求。'
                : 'Apply only source-supported, structurally valid corrections approved by a separate model review. Retain an audit trail and leave other proposals as suggestions. Requires semantic review and additional API calls.',
          ),
          value: config.autoApplyVerifiedCorrections,
          onChanged: isRunActive || !config.semanticQualityCheck
              ? null
              : controller.setAutoApplyVerifiedCorrections,
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            strings.isChinese
                ? '重试上次未通过的复核'
                : 'Retry previously rejected reviews',
          ),
          subtitle: Text(
            strings.isChinese
                ? '默认保留结果和原因，不重复请求。开启后下次翻译会补审，可能增加 API 费用；仅导出已有译文请使用结果页的本地导出。'
                : 'Normally retain rejected results and reasons. Enable to retry on the next run; additional API costs may apply. Use local export to reuse existing text.',
          ),
          value: config.retryIncompleteReviews,
          onChanged: isRunActive ? null : controller.setRetryIncompleteReviews,
        ),
        DropdownButtonFormField<SemanticReviewScope>(
          key: ValueKey('review-scope-${config.semanticReviewScope.name}'),
          initialValue: config.semanticReviewScope,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: strings.isChinese ? '复核范围' : 'Review scope',
          ),
          items: [
            DropdownMenuItem(
              value: SemanticReviewScope.risksOnly,
              child: Text(
                strings.isChinese
                    ? '风险段落与少量抽查（推荐）'
                    : 'Risks and spot checks (recommended)',
              ),
            ),
            DropdownMenuItem(
              value: SemanticReviewScope.all,
              child: Text(
                strings.isChinese
                    ? '全部段落（受预算限制）'
                    : 'All paragraphs (within budget)',
              ),
            ),
          ],
          onChanged: isRunActive
              ? null
              : (v) {
                  if (v != null) {
                    controller.setSemanticReviewScope(v);
                  }
                },
        ),
        SettingsSlider(
          inputKey: const ValueKey('settings-maxSemanticReviewTokens'),
          select: (c) => c.maxSemanticReviewTokens.toDouble(),
          label: (v) => strings.isChinese
              ? '复核预估 token 预算：${v.round()}'
              : 'Estimated review token budget: ${v.round()}',
          min: 4000,
          max: 1024000,
          divisions: 255,
          onChanged: isRunActive ? null : controller.setMaxSemanticReviewTokens,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
        ),
        Text(
          strings.isChinese
              ? '按输入字节和最大输出保守预留预算；达到任一上限即停止新增复核，保留原译文。实际账单由服务商计费。'
              : 'Conservatively reserves input bytes and maximum output. Either limit stops new reviews and keeps drafts. Provider billing may differ.',
        ),
        SettingsSlider(
          select: (c) => c.maxSemanticReviewRequests.toDouble(),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '语义复核最多 ${v.round()} 次请求'
              : 'Maximum semantic review requests ${v.round()}',
          label: (v) => strings.isChinese
              ? '语义复核最多额外请求：${v.round()} 次'
              : 'Maximum extra review requests: ${v.round()}',
          min: 1,
          max: 64,
          divisions: 63,
          onChanged: isRunActive
              ? null
              : controller.setMaxSemanticReviewRequests,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
        ),
        SettingsSlider(
          inputKey: const ValueKey('settings-chunkSize'),
          select: (c) => c.chunkSize.toDouble(),
          label: (v) => strings.chunkSizeLabel(v.round()),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '分块大小 ${v.round()} 字符'
              : 'Chunk size ${v.round()} characters',
          min: 1000,
          max: 12000,
          divisions: 11,
          onChanged: isRunActive ? null : controller.setChunkSize,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
        ),
        SettingsSlider(
          select: (c) => c.maxConcurrent.toDouble(),
          label: (v) => strings.maxConcurrentLabel(v.round()),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '并发数 ${v.round()}'
              : 'Concurrency ${v.round()}',
          min: 1,
          max: 8,
          divisions: 7,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
          onChanged: isRunActive ? null : controller.setMaxConcurrent,
        ),
        SettingsSlider(
          inputKey: const ValueKey('settings-timeoutSeconds'),
          select: (c) => c.timeoutSeconds.toDouble(),
          label: (v) => strings.timeoutLabel(v.round()),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '超时 ${v.round()} 秒'
              : 'Timeout ${v.round()} seconds',
          min: 30,
          max: 300,
          divisions: 9,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
          onChanged: isRunActive ? null : controller.setTimeoutSeconds,
        ),
        SettingsSlider(
          select: (c) => c.maxRetries.toDouble(),
          label: (v) => strings.maxRetriesLabel(v.round()),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '最多重试 ${v.round()} 次'
              : 'Maximum retries ${v.round()}',
          min: 1,
          max: 6,
          divisions: 5,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
          onChanged: isRunActive ? null : controller.setMaxRetries,
        ),
        SettingsSlider(
          select: (c) => c.retryDelaySeconds.toDouble(),
          label: (v) => strings.retryDelayLabel(v.round()),
          semanticFormatterCallback: (v) => strings.isChinese
              ? '重试间隔 ${v.round()} 秒'
              : 'Retry delay ${v.round()} seconds',
          min: 1,
          max: 15,
          divisions: 14,
          onChangeEnd: isRunActive
              ? null
              : (_) => controller.flushSliderChanges(),
          onChanged: isRunActive ? null : controller.setRetryDelaySeconds,
        ),
        SettingsTextField(
          strings: strings,
          fieldKey: const ValueKey<String>('settings-output-suffix'),
          value: config.outputSuffix,
          onChanged: controller.setOutputSuffix,
          onCommit: controller.setOutputSuffix,
          enabled: !isRunActive,
          decoration: InputDecoration(
            labelText: strings.outputSuffix,
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        SettingsTextField(
          strings: strings,
          fieldKey: const ValueKey<String>('settings-locked-glossary'),
          value: config.lockedGlossary,
          onChanged: controller.setLockedGlossary,
          onCommit: controller.setLockedGlossary,
          enabled: !isRunActive,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: strings.lockedGlossary,
            hintText: strings.lockedGlossaryHint,
            alignLabelWithHint: true,
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
