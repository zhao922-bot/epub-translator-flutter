import 'package:flutter/material.dart';

class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool stackActions = constraints.maxWidth < 720;
              final Widget titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
              final Widget actionBlock = Wrap(
                spacing: 12,
                runSpacing: 12,
                children: actions,
              );

              if (stackActions) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    titleBlock,
                    if (actions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      actionBlock,
                    ],
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: titleBlock),
                  if (actions.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 16),
                    Flexible(child: actionBlock),
                  ],
                ],
              );
            },
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: child,
          ),
        ),
      ],
    );
  }
}
