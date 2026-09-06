import 'package:flutter/material.dart';

enum SectionCardVariant { emphasis, standard, subtle }

/// Low-weight surface with a shared heading, never nested visual chrome.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.trailing,
    this.icon,
    this.variant = SectionCardVariant.standard,
  });
  final String? title;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;
  final SectionCardVariant variant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasTitle = title?.trim().isNotEmpty ?? false;
    final heading = Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 9),
        ],
        if (hasTitle)
          Flexible(child: Text(title!, style: theme.textTheme.titleMedium)),
      ],
    );
    return Semantics(
      container: true,
      child: Material(
        key: ValueKey<String>('section-card-${variant.name}'),
        color: variant == SectionCardVariant.subtle
            ? scheme.surfaceContainerHigh
            : scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasTitle || trailing != null) ...[
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth < 560 && trailing != null) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (hasTitle) heading,
                          if (hasTitle) const SizedBox(height: 8),
                          trailing!,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(
                          child: hasTitle ? heading : const SizedBox.shrink(),
                        ),
                        if (trailing != null) Flexible(child: trailing!),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }
}
