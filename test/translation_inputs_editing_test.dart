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

    final updated = tester.widget<EditableText>(editable);
    expect(inputPath, 'AXBC.epub');
    expect(updated.focusNode.hasFocus, isTrue);
    expect(updated.controller.selection.baseOffset, 2);
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

    final updated = tester.widget<EditableText>(editable);
    expect(outputDirectory, 'C:/XOutput');
    expect(updated.focusNode.hasFocus, isTrue);
    expect(updated.controller.selection.baseOffset, 4);
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
}
