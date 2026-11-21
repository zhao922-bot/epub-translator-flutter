import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/book_budget_strings.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_token_usage.dart';
import 'book_token_budget_field.dart';

Future<int?> askBookBudgetForResume({
  required BuildContext context,
  required AppStrings strings,
  required int currentBudget,
  required TranslationTokenUsage usage,
}) {
  return showDialog<int>(
    context: context,
    builder: (context) => _BookBudgetDialog(
      strings: strings,
      currentBudget: currentBudget,
      usage: usage,
    ),
  );
}

class _BookBudgetDialog extends StatefulWidget {
  const _BookBudgetDialog({
    required this.strings,
    required this.currentBudget,
    required this.usage,
  });

  final AppStrings strings;
  final int currentBudget;
  final TranslationTokenUsage usage;

  @override
  State<_BookBudgetDialog> createState() => _BookBudgetDialogState();
}

class _BookBudgetDialogState extends State<_BookBudgetDialog> {
  final _form = GlobalKey<FormState>();
  late final _tokens = TextEditingController(text: '${widget.currentBudget}');

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(BookTokenBudgetField.parse(_tokens.text));
    }
  }

  @override
  void dispose() {
    _tokens.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final suggestion = widget.usage.minimumSuggestedBudget;
    return AlertDialog(
      title: Text(strings.adjustBookBudget),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.bookBudgetHelp),
                if (widget.usage.nextRequestTokens > 0) ...[
                  const SizedBox(height: 8),
                  Text(strings.suggestedBookBudget(suggestion)),
                  if (suggestion <= TranslationConfig.maxBookTokenBudget)
                    TextButton(
                      onPressed: () => _tokens.text = '$suggestion',
                      child: Text(strings.useSuggestedBookBudget),
                    ),
                ],
                const SizedBox(height: 12),
                BookTokenBudgetField(
                  strings: strings,
                  controller: _tokens,
                  onSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.dialogCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(strings.resumeBookWithBudget),
        ),
      ],
    );
  }
}
