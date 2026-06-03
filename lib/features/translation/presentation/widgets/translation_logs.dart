import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/section_card.dart';

class TranslationLogs extends StatelessWidget {
  const TranslationLogs({super.key, required this.strings, required this.logs});

  final AppStrings strings;
  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: strings.logsTitle,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 220),
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            logs.join('\n'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontFamily: 'Consolas',
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
