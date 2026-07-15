import 'package:flutter/material.dart';

/// Shared page frame: header + scrollable content with readable max width.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const <Widget>[],
    this.contentMaxWidth = 1080,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  /// Caps content width on wide desktops for scanning comfort.
  final double contentMaxWidth;

  static const Key scaffoldKey = ValueKey<String>('page-scaffold');
  static const Key headerKey = ValueKey<String>('page-scaffold-header');
  static const Key bodyKey = ValueKey<String>('page-scaffold-body');

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool hasSubtitle = subtitle.trim().isNotEmpty;
    final bool hasHeader =
        title.trim().isNotEmpty || hasSubtitle || actions.isNotEmpty;

    return KeyedSubtree(
      key: scaffoldKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hasHeader)
            Material(
              key: headerKey,
              color: scheme.surface,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      scheme.surface,
                      scheme.primaryContainer.withValues(
                        alpha: scheme.brightness == Brightness.dark
                            ? 0.08
                            : 0.28,
                      ),
                    ],
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: contentMaxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 26, 28, 20),
                        child: LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final bool stackActions =
                                    constraints.maxWidth < 720;
                                final Widget titleBlock = Semantics(
                                  header: true,
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      if (title.trim().isNotEmpty) ...<Widget>[
                                        Container(
                                          width: 3,
                                          height: hasSubtitle ? 42 : 26,
                                          margin: const EdgeInsets.only(
                                            top: 2,
                                            right: 12,
                                          ),
                                          decoration: BoxDecoration(
                                            color: scheme.primary,
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                      ],
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            if (title.trim().isNotEmpty)
                                              Text(
                                                title,
                                                style: textTheme.headlineSmall,
                                              ),
                                            if (hasSubtitle) ...<Widget>[
                                              if (title.trim().isNotEmpty)
                                                const SizedBox(height: 4),
                                              ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      maxWidth: 640,
                                                    ),
                                                child: Text(
                                                  subtitle,
                                                  style: textTheme.bodyMedium
                                                      ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                final Widget actionBlock = Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  alignment: WrapAlignment.end,
                                  children: actions,
                                );

                                if (!title.trim().isNotEmpty && !hasSubtitle) {
                                  return Align(
                                    alignment: Alignment.centerRight,
                                    child: actionBlock,
                                  );
                                }

                                if (stackActions) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      titleBlock,
                                      if (actions.isNotEmpty) ...<Widget>[
                                        const SizedBox(height: 12),
                                        actionBlock,
                                      ],
                                    ],
                                  );
                                }

                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
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
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentMaxWidth),
                child: SingleChildScrollView(
                  key: bodyKey,
                  padding: const EdgeInsets.fromLTRB(28, 26, 28, 40),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
