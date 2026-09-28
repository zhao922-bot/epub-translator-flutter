import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_inputs.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('manual input path keeps focus and caret after parent updates', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.english);
    String inputPath = 'ABC.epub';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TranslationInputs(
                strings: strings,
                inputPath: inputPath,
                outputDirectory: 'C:/Output',
                targetLanguage: 'Chinese',
                bilingual: false,
                enabled: true,
                onInputChanged: (value) => setState(() => inputPath = value),
                onOutputChanged: (_) {},
                onTargetLanguageChanged: (_) {},
                onBilingualChanged: (_) {},
                onPickInputPressed: () {},
                onPickOutputPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();

    final inputField = find.byType(TextFormField).first;
    await tester.ensureVisible(inputField);
    await tester.tap(inputField);
    await tester.pump();
    final editable = find.descendant(
      of: inputField,
      matching: find.byType(EditableText),
    );
    tester.widget<EditableText>(editable).controller.selection =
        const TextSelection.collapsed(offset: 1);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'AXBC.epub',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    // Typing alone must not commit: the controller callback clears the
    // current job and inspection state, which must not happen per keystroke.
    expect(inputPath, 'ABC.epub');

    // ... but focus and caret are preserved while typing.
    final typing = tester.widget<EditableText>(editable);
    expect(typing.focusNode.hasFocus, isTrue);
    expect(typing.controller.selection.baseOffset, 2);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(inputPath, 'AXBC.epub');
  });

  testWidgets('manual output path keeps focus and caret after parent updates', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.english);
    String outputDirectory = 'C:/Output';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TranslationInputs(
                strings: strings,
                inputPath: 'C:/Book.epub',
                outputDirectory: outputDirectory,
                targetLanguage: 'Chinese',
                bilingual: false,
                enabled: true,
                onInputChanged: (_) {},
                onOutputChanged: (value) =>
                    setState(() => outputDirectory = value),
                onTargetLanguageChanged: (_) {},
                onBilingualChanged: (_) {},
                onPickInputPressed: () {},
                onPickOutputPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();

    final outputField = find.byType(TextFormField).last;
    await tester.ensureVisible(outputField);
    await tester.tap(outputField);
    await tester.pump();
    final editable = find.descendant(
      of: outputField,
      matching: find.byType(EditableText),
    );
    tester.widget<EditableText>(editable).controller.selection =
        const TextSelection.collapsed(offset: 3);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'C:/XOutput',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();

    // Typing alone must not commit: the controller callback writes to disk
    // and re-arms path watchers, which must not happen per keystroke.
    expect(outputDirectory, 'C:/Output');

    // ... but focus and caret are preserved while typing.
    final typing = tester.widget<EditableText>(editable);
    expect(typing.focusNode.hasFocus, isTrue);
    expect(typing.controller.selection.baseOffset, 4);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(outputDirectory, 'C:/XOutput');
  });

  testWidgets('manual input path commits when focus leaves the field', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.english);
    String inputPath = 'ABC.epub';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TranslationInputs(
                strings: strings,
                inputPath: inputPath,
                outputDirectory: 'C:/Output',
                targetLanguage: 'Chinese',
                bilingual: false,
                enabled: true,
                onInputChanged: (value) => setState(() => inputPath = value),
                onOutputChanged: (_) {},
                onTargetLanguageChanged: (_) {},
                onBilingualChanged: (_) {},
                onPickInputPressed: () {},
                onPickOutputPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();

    final inputField = find.byType(TextFormField).first;
    await tester.ensureVisible(inputField);
    await tester.tap(inputField);
    await tester.pump();
    tester.testTextInput.enterText('Typed.epub');
    await tester.pump();
    expect(inputPath, 'ABC.epub');

    // Tapping another focusable moves focus away, committing the text.
    await tester.tap(find.byType(TextFormField).last);
    await tester.pump();
    expect(inputPath, 'Typed.epub');
  });

  testWidgets('manual paths reflect external file and directory selections', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.english);
    String inputPath = 'C:/Old.epub';
    String outputDirectory = 'C:/Output';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      inputPath = 'D:/Books/New.epub';
                      outputDirectory = 'D:/Translated';
                    }),
                    child: const Text('Choose a different file'),
                  ),
                  TranslationInputs(
                    strings: strings,
                    inputPath: inputPath,
                    outputDirectory: outputDirectory,
                    targetLanguage: 'Chinese',
                    bilingual: false,
                    enabled: true,
                    onInputChanged: (value) =>
                        setState(() => inputPath = value),
                    onOutputChanged: (value) =>
                        setState(() => outputDirectory = value),
                    onTargetLanguageChanged: (_) {},
                    onBilingualChanged: (_) {},
                    onPickInputPressed: () {},
                    onPickOutputPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();
    await tester.ensureVisible(find.text('Choose a different file'));
    await tester.tap(find.text('Choose a different file'));
    await tester.pump();

    final inputField = find.byType(TextFormField).first;
    final editable = find.descendant(
      of: inputField,
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(editable).controller.text,
      'D:/Books/New.epub',
    );
    final outputField = find.byType(TextFormField).last;
    final outputEditable = find.descendant(
      of: outputField,
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(outputEditable).controller.text,
      'D:/Translated',
    );
  });

  testWidgets('unfocus commits the pending path edit (start-button flow)', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.english);
    String outputDirectory = 'C:/Output';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranslationInputs(
              strings: strings,
              inputPath: 'ABC.epub',
              outputDirectory: outputDirectory,
              targetLanguage: 'Chinese',
              bilingual: false,
              enabled: true,
              onInputChanged: (_) {},
              onOutputChanged: (value) => outputDirectory = value,
              onTargetLanguageChanged: (_) {},
              onBilingualChanged: (_) {},
              onPickInputPressed: () {},
              onPickOutputPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();

    final outputField = find.byType(TextFormField).last;
    await tester.ensureVisible(outputField);
    await tester.tap(outputField);
    await tester.pump();
    await tester.enterText(outputField, 'D:/NewOutput');
    await tester.pump();
    // Typing alone must not commit.
    expect(outputDirectory, 'C:/Output');

    // This is what the start-translation button does before starting the
    // run: tapping it does not move focus on its own.
    final BuildContext context = tester.element(find.byType(TranslationInputs));
    FocusScope.of(context).unfocus();
    await tester.pump();
    expect(outputDirectory, 'D:/NewOutput');
  });

  testWidgets('disposing the inputs flushes uncommitted path edits', (
    tester,
  ) async {
    const strings = AppStrings(UiLanguage.english);
    String outputDirectory = 'C:/Output';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranslationInputs(
              strings: strings,
              inputPath: 'ABC.epub',
              outputDirectory: outputDirectory,
              targetLanguage: 'Chinese',
              bilingual: false,
              enabled: true,
              onInputChanged: (_) {},
              onOutputChanged: (value) => outputDirectory = value,
              onTargetLanguageChanged: (_) {},
              onBilingualChanged: (_) {},
              onPickInputPressed: () {},
              onPickOutputPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text(strings.advancedPaths));
    await tester.tap(find.text(strings.advancedPaths));
    await tester.pump();

    final outputField = find.byType(TextFormField).last;
    await tester.ensureVisible(outputField);
    await tester.tap(outputField);
    await tester.pump();
    await tester.enterText(outputField, 'D:/NewOutput');
    await tester.pump();
    expect(outputDirectory, 'C:/Output');

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(outputDirectory, 'D:/NewOutput');
  });
}
