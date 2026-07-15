import 'package:flutter/material.dart';

/// Visual weight for workspace hierarchy.
///
/// Use [emphasis] for the primary action surface, [standard] for normal
/// content blocks, and [subtle] for secondary/supporting regions.
enum SectionCardVariant { emphasis, standard, subtle }

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.trailing,
    this.icon,
    this.variant = SectionCardVariant.standard,
  });

  /// Optional section title. When null/empty, only [child] (and optional trailing) is shown.
  final String? title;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;
  final SectionCardVariant variant;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;
    final bool hasTitle = title != null && title!.trim().isNotEmpty;

    final Color surfaceColor = switch (variant) {
      SectionCardVariant.emphasis => scheme.surfaceContainerHighest,
      SectionCardVariant.standard => scheme.surfaceContainerHighest,
      SectionCardVariant.subtle =>
        isDark
            ? scheme.surfaceContainerHigh.withValues(alpha: 0.72)
            : scheme.surfaceContainerHigh,
    };

    final BorderSide borderSide = switch (variant) {
      SectionCardVariant.emphasis => BorderSide(
        color: scheme.primary.withValues(alpha: isDark ? 0.38 : 0.28),
        width: 1.2,
      ),
      SectionCardVariant.standard => BorderSide(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.9),
      ),
      SectionCardVariant.subtle => BorderSide(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.55),
      ),
    };

    final double elevation = switch (variant) {
      SectionCardVariant.emphasis => isDark ? 0 : 1.6,
      SectionCardVariant.standard => isDark ? 0 : 0.5,
      SectionCardVariant.subtle => 0,
    };

    final EdgeInsets padding = switch (variant) {
      SectionCardVariant.emphasis => const EdgeInsets.fromLTRB(20, 18, 20, 20),
      SectionCardVariant.standard => const EdgeInsets.fromLTRB(18, 16, 18, 18),
      SectionCardVariant.subtle => const EdgeInsets.fromLTRB(14, 12, 14, 14),
    };

    final Widget? titleBlock = hasTitle
        ? Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 17, color: scheme.primary),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  title!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          )
        : null;

    return Semantics(
      container: true,
      child: Material(
        key: ValueKey<String>('section-card-${variant.name}'),
        color: surfaceColor,
        elevation: elevation,
        shadowColor: scheme.shadow.withValues(alpha: isDark ? 0.35 : 0.07),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            variant == SectionCardVariant.emphasis ? 22 : 18,
          ),
          side: borderSide,
        ),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: variant == SectionCardVariant.emphasis
              ? BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      scheme.surfaceContainerHighest,
                      scheme.primaryContainer.withValues(
                        alpha: isDark ? 0.1 : 0.28,
                      ),
                    ],
                  ),
                )
              : const BoxDecoration(),
          child: Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (titleBlock != null || trailing != null)
                  LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          final Widget leading =
                              titleBlock ?? const SizedBox.shrink();
                          if (trailing == null) {
                            return leading;
                          }
                          if (constraints.maxWidth < 560) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                ?titleBlock,
                                const SizedBox(height: 8),
                                trailing!,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              if (titleBlock != null)
                                Expanded(child: titleBlock),
                              if (titleBlock == null) const Spacer(),
                              Flexible(child: trailing!),
                            ],
                          );
                        },
                  ),
                if (titleBlock != null || trailing != null)
                  const SizedBox(height: 14),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
