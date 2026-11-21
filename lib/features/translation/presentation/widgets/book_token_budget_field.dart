import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/book_budget_strings.dart';
import '../../domain/models/translation_config.dart';

class BookTokenBudgetField extends StatelessWidget {
  const BookTokenBudgetField({
    super.key,
    required this.strings,
    this.enabled = true,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.onSubmitted,
  });

  final AppStrings strings;
  final bool enabled;
  final TextEditingController? controller;
  final int? initialValue;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  static int? parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    final tokens = int.tryParse(trimmed, radix: 10);
    if (tokens == null ||
        tokens < 0 ||
        tokens > TranslationConfig.maxBookTokenBudget) {
      return null;
    }
    return tokens;
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: const ValueKey('book-token-budget-field'),
      controller: controller,
      initialValue: controller == null ? initialValue?.toString() : null,
      enabled: enabled,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      validator: (value) =>
          parse(value ?? '') == null ? strings.invalidBookBudget : null,
      decoration: InputDecoration(
        labelText: strings.bookTokenBudget,
        helperText: strings.bookBudgetUnlimitedHint,
        helperMaxLines: 2,
      ),
    );
  }
}
