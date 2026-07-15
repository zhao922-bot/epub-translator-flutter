import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/section_card.dart';

class TranslationLogs extends StatefulWidget {
  const TranslationLogs({
    super.key,
    required this.strings,
    required this.logs,
    this.initiallyExpanded = false,
  });

  final AppStrings strings;
  final List<String> logs;
  final bool initiallyExpanded;

  @override
  State<TranslationLogs> createState() => _TranslationLogsState();
}

class _TranslationLogsState extends State<TranslationLogs> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant TranslationLogs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_expanded &&
        widget.logs.isNotEmpty &&
        widget.logs.last.toLowerCase().contains('fail')) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final String latest = widget.logs.isEmpty ? '—' : widget.logs.last;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;
    final String countLabel = widget.logs.isEmpty
        ? widget.strings.logsTitle
        : '${widget.strings.logsTitle} · ${widget.logs.length}';

    return SectionCard(
      title: countLabel,
      icon: Icons.terminal_rounded,
      variant: SectionCardVariant.subtle,
      trailing: TextButton(
        onPressed: () => setState(() => _expanded = !_expanded),
        child: Text(
          _expanded ? widget.strings.collapseLogs : widget.strings.expandLogs,
        ),
      ),
      child: _expanded
          ? Container(
              constraints: const BoxConstraints(maxHeight: 220, minHeight: 100),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0A0E16)
                    : const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SelectableText(
                    widget.logs.join('\n'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.45,
                      color: const Color(0xFFCBD5E1),
                    ),
                  ),
                ),
              ),
            )
          : Text(
              latest,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
    );
  }
}
