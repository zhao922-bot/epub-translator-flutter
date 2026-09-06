import 'package:flutter/material.dart';

/// Flat settings group with an optional action, not a nested card.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
  });
  final String title;
  final Widget child;
  final IconData? icon;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
        ],
        Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) {
              if (trailing == null) return heading;
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [heading, const SizedBox(height: 10), trailing!],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  Flexible(child: trailing!),
                ],
              );
            },
          ),
          const SizedBox(height: 22),
          child,
        ],
      ),
    );
  }
}
