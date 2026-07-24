import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../domain/models/translation_style_profile.dart';

class TranslationStyleProfileCard extends StatefulWidget {
  const TranslationStyleProfileCard({
    super.key,
    required this.strings,
    required this.profile,
    required this.confirmed,
    required this.enabled,
    required this.editable,
    required this.isGenerating,
    required this.canGenerate,
    required this.onGenerate,
    required this.onConfirm,
    required this.onChanged,
  });

  final AppStrings strings;
  final TranslationStyleProfile profile;
  final bool confirmed;
  final bool enabled;
  final bool editable;
  final bool isGenerating;
  final bool canGenerate;
  final VoidCallback onGenerate;
  final VoidCallback onConfirm;
  final void Function({
    String? primaryGenre,
    String? secondaryGenresCsv,
    String? tone,
    String? sentenceStyle,
    String? constraintsText,
    String? avoidText,
    TranslationStyleConfidence? confidence,
  })
  onChanged;

  @override
  State<TranslationStyleProfileCard> createState() =>
      _TranslationStyleProfileCardState();
}

class _TranslationStyleProfileCardState
    extends State<TranslationStyleProfileCard> {
  late final TextEditingController _genreController;
  late final TextEditingController _secondaryController;
  late final TextEditingController _toneController;
  late final TextEditingController _sentenceController;
  late final TextEditingController _constraintsController;
  late final TextEditingController _avoidController;

  static String _lines(List<String> values) =>
      values.join(String.fromCharCode(10));

  @override
  void initState() {
    super.initState();
    _genreController = TextEditingController(text: widget.profile.primaryGenre);
    _secondaryController = TextEditingController(
      text: widget.profile.secondaryGenres.join(', '),
    );
    _toneController = TextEditingController(text: widget.profile.tone);
    _sentenceController = TextEditingController(
      text: widget.profile.sentenceStyle,
    );
    _constraintsController = TextEditingController(
      text: _lines(widget.profile.translationConstraints),
    );
    _avoidController = TextEditingController(
      text: _lines(widget.profile.avoid),
    );
  }

  @override
  void didUpdateWidget(covariant TranslationStyleProfileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.profile.sameContentAs(widget.profile)) {
      _syncController(_genreController, widget.profile.primaryGenre);
      _syncController(
        _secondaryController,
        widget.profile.secondaryGenres.join(', '),
      );
      _syncController(_toneController, widget.profile.tone);
      _syncController(_sentenceController, widget.profile.sentenceStyle);
      _syncController(
        _constraintsController,
        _lines(widget.profile.translationConstraints),
      );
      _syncController(_avoidController, _lines(widget.profile.avoid));
    }
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) {
      return;
    }
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    _genreController.dispose();
    _secondaryController.dispose();
    _toneController.dispose();
    _sentenceController.dispose();
    _constraintsController.dispose();
    _avoidController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasProfile = !widget.profile.isEmpty;
    final String badge = widget.confirmed
        ? widget.strings.styleProfileConfirmedBadge
        : widget.strings.styleProfilePendingBadge;

    return SectionCard(
      title: widget.strings.styleProfileSectionTitle,
      icon: Icons.auto_stories_rounded,
      variant: SectionCardVariant.standard,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: (widget.confirmed ? scheme.tertiary : scheme.secondary)
              .withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          badge,
          style: theme.textTheme.labelMedium?.copyWith(
            color: widget.confirmed ? scheme.tertiary : scheme.secondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            widget.strings.styleProfileSectionBody,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (!hasProfile) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              widget.strings.styleProfileEmptyHint,
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: widget.isGenerating || !widget.canGenerate
                    ? null
                    : widget.onGenerate,
                icon: widget.isGenerating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(
                  hasProfile
                      ? widget.strings.regenerateStyleProfile
                      : widget.strings.generateStyleProfile,
                ),
              ),
              FilledButton.icon(
                onPressed: widget.isGenerating || !widget.editable
                    ? null
                    : widget.onConfirm,
                icon: const Icon(Icons.verified_rounded, size: 18),
                label: Text(widget.strings.confirmStyleProfile),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _field(
            controller: _genreController,
            label: widget.strings.styleProfilePrimaryGenre,
            onChanged: (String value) => widget.onChanged(primaryGenre: value),
          ),
          _field(
            controller: _secondaryController,
            label: widget.strings.styleProfileSecondaryGenres,
            onChanged: (String value) =>
                widget.onChanged(secondaryGenresCsv: value),
          ),
          _field(
            controller: _toneController,
            label: widget.strings.styleProfileTone,
            onChanged: (String value) => widget.onChanged(tone: value),
          ),
          _field(
            controller: _sentenceController,
            label: widget.strings.styleProfileSentenceStyle,
            onChanged: (String value) => widget.onChanged(sentenceStyle: value),
          ),
          _field(
            controller: _constraintsController,
            label: widget.strings.styleProfileConstraints,
            maxLines: 3,
            onChanged: (String value) =>
                widget.onChanged(constraintsText: value),
          ),
          _field(
            controller: _avoidController,
            label: widget.strings.styleProfileAvoid,
            maxLines: 3,
            onChanged: (String value) => widget.onChanged(avoidText: value),
          ),
          const SizedBox(height: 4),
          Text(
            widget.strings.styleProfileConfidence,
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          SegmentedButton<TranslationStyleConfidence>(
            segments: const <ButtonSegment<TranslationStyleConfidence>>[
              ButtonSegment<TranslationStyleConfidence>(
                value: TranslationStyleConfidence.high,
                label: Text('high'),
              ),
              ButtonSegment<TranslationStyleConfidence>(
                value: TranslationStyleConfidence.medium,
                label: Text('medium'),
              ),
              ButtonSegment<TranslationStyleConfidence>(
                value: TranslationStyleConfidence.low,
                label: Text('low'),
              ),
            ],
            selected: <TranslationStyleConfidence>{widget.profile.confidence},
            onSelectionChanged: widget.isGenerating || !widget.editable
                ? null
                : (Set<TranslationStyleConfidence> next) {
                    if (next.isEmpty) {
                      return;
                    }
                    widget.onChanged(confidence: next.first);
                  },
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        enabled: !widget.isGenerating && widget.editable,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }
}
