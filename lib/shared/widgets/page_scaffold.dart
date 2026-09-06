import 'package:flutter/material.dart';

/// Common page frame. Lists can opt out of the default content scroller.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const <Widget>[],
    this.contentMaxWidth = 1200,
    this.scrollBody = true,
  });
  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;
  final double contentMaxWidth;
  final bool scrollBody;
  static const Key scaffoldKey = ValueKey<String>('page-scaffold');
  static const Key headerKey = ValueKey<String>('page-scaffold-header');
  static const Key bodyKey = ValueKey<String>('page-scaffold-body');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final double padding = constraints.maxWidth < 600 ? 16 : 32;
        final hasHeader =
            title.isNotEmpty || subtitle.isNotEmpty || actions.isNotEmpty;
        final titleBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty)
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.headlineSmall),
              ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
        final actionBlock = Wrap(spacing: 8, runSpacing: 8, children: actions);
        return KeyedSubtree(
          key: scaffoldKey,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasHeader)
                    Padding(
                      key: headerKey,
                      padding: EdgeInsets.fromLTRB(padding, 26, padding, 22),
                      child: LayoutBuilder(
                        builder: (context, headerConstraints) {
                          if (headerConstraints.maxWidth < 720) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                titleBlock,
                                if (actions.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  actionBlock,
                                ],
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: titleBlock),
                              if (actions.isNotEmpty) ...[
                                const SizedBox(width: 20),
                                Flexible(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: actionBlock,
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  Expanded(
                    child: scrollBody
                        ? SingleChildScrollView(
                            key: bodyKey,
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              28,
                            ),
                            child: child,
                          )
                        : Padding(
                            key: bodyKey,
                            padding: EdgeInsets.symmetric(horizontal: padding),
                            child: child,
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
