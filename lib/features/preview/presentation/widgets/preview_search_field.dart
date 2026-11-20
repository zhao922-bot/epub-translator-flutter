import 'package:flutter/material.dart';

class PreviewSearchField extends StatelessWidget {
  const PreviewSearchField({
    super.key,
    required this.controller,
    required this.label,
    required this.clearLabel,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String clearLabel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Icons.search_rounded),
      suffixIcon: controller.text.isEmpty
          ? null
          : IconButton(
              tooltip: clearLabel,
              onPressed: () {
                controller.clear();
                onChanged('');
              },
              icon: const Icon(Icons.clear),
            ),
    ),
  );
}
