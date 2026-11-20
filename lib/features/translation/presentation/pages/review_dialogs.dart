import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/review_strings.dart';
import '../../infrastructure/translation_review_store.dart';

class ReviewTextDialog extends StatefulWidget {
  const ReviewTextDialog({
    super.key,
    required this.initialText,
    required this.strings,
    required this.title,
    required this.saveLabel,
    required this.maxLines,
  });

  final String initialText, title, saveLabel;
  final AppStrings strings;
  final int maxLines;

  @override
  State<ReviewTextDialog> createState() => _ReviewTextDialogState();
}

class _ReviewTextDialogState extends State<ReviewTextDialog> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 600,
      child: TextField(
        controller: _controller,
        minLines: 4,
        maxLines: widget.maxLines,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.strings.dialogCancel),
      ),
      TextButton(
        onPressed: () {
          if (_controller.text.trim().isNotEmpty) {
            Navigator.pop(context, _controller.text);
          }
        },
        child: Text(widget.saveLabel),
      ),
    ],
  );
}

class ReviewReplaceDialog extends StatefulWidget {
  const ReviewReplaceDialog({
    super.key,
    required this.markup,
    required this.strings,
  });

  final String markup;
  final AppStrings strings;

  @override
  State<ReviewReplaceDialog> createState() => _ReviewReplaceDialogState();
}

class _ReviewReplaceDialogState extends State<ReviewReplaceDialog> {
  final _before = TextEditingController();
  final _after = TextEditingController();
  bool _replacementRejected = false;

  @override
  void dispose() {
    _before.dispose();
    _after.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final changed = TranslationReviewStore.replaceText(
        widget.markup,
        _before.text,
        _after.text,
      );
      Navigator.pop(context, changed);
    } on FormatException {
      setState(() => _replacementRejected = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      scrollable: true,
      title: Text(strings.manualReviewReplaceTitle),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.manualReviewReplaceHelp),
            TextField(
              controller: _before,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: strings.manualReviewFindText,
              ),
            ),
            TextField(
              controller: _after,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: strings.manualReviewReplaceWith,
              ),
            ),
            if (_replacementRejected)
              Text(
                strings.manualReviewReplaceFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.dialogCancel),
        ),
        TextButton(onPressed: _save, child: Text(strings.manualReviewSave)),
      ],
    );
  }
}
