import 'package:epub_translator_flutter/features/settings/presentation/widgets/settings_fields.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fieldKey = ValueKey<String>('debounce-field');
const _otherKey = ValueKey<String>('debounce-other');

Future<void> _pumpField(
  WidgetTester tester, {
  required ValueChanged<String> onChanged,
  String value = '',
  bool withOtherField = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            SettingsTextField(
              strings: const AppStrings(UiLanguage.english),
              fieldKey: _fieldKey,
              value: value,
              onChanged: onChanged,
              decoration: const InputDecoration(),
            ),
            if (withOtherField) const TextField(key: _otherKey),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('SettingsTextField commit debounce', () {
    testWidgets('does not commit per keystroke, commits once after pause', (
      tester,
    ) async {
      final List<String> committed = <String>[];
      await _pumpField(tester, onChanged: committed.add);

      await tester.enterText(find.byKey(_fieldKey), 'a');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byKey(_fieldKey), 'ab');
      await tester.pump(const Duration(milliseconds: 500));
      // Still inside the debounce window of the last keystroke.
      expect(committed, isEmpty);

      await tester.pump(const Duration(milliseconds: 400));
      expect(committed, <String>['ab']);
    });

    testWidgets('commits immediately on submit', (tester) async {
      final List<String> committed = <String>[];
      await _pumpField(tester, onChanged: committed.add);

      await tester.enterText(find.byKey(_fieldKey), 'key-123');
      await tester.pump(const Duration(milliseconds: 100));
      expect(committed, isEmpty);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(committed, <String>['key-123']);
    });

    testWidgets('commits on focus loss', (tester) async {
      final List<String> committed = <String>[];
      await _pumpField(tester, onChanged: committed.add, withOtherField: true);

      await tester.enterText(find.byKey(_fieldKey), 'typed');
      await tester.pump(const Duration(milliseconds: 100));
      expect(committed, isEmpty);

      await tester.tap(find.byKey(_otherKey));
      await tester.pump();
      expect(committed, <String>['typed']);
    });

    testWidgets('does not commit unchanged text', (tester) async {
      final List<String> committed = <String>[];
      await _pumpField(tester, onChanged: committed.add, value: 'same');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(committed, isEmpty);
    });

    testWidgets('flushes the pending commit when disposed mid-debounce', (
      tester,
    ) async {
      final List<String> committed = <String>[];
      await _pumpField(tester, onChanged: committed.add);

      await tester.enterText(find.byKey(_fieldKey), 'half-typed');
      await tester.pump(const Duration(milliseconds: 100));
      expect(committed, isEmpty);

      // Navigate away within the debounce window: the pending commit must
      // be flushed, not silently dropped.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      expect(committed, <String>['half-typed']);
    });

    testWidgets('disabling the field discards the pending commit', (
      tester,
    ) async {
      final List<String> committed = <String>[];
      Future<void> pump({required bool enabled}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTextField(
              strings: const AppStrings(UiLanguage.english),
              fieldKey: _fieldKey,
              value: '',
              enabled: enabled,
              onChanged: committed.add,
              decoration: const InputDecoration(),
            ),
          ),
        ),
      );

      await pump(enabled: true);
      await tester.enterText(find.byKey(_fieldKey), 'half-typed');
      await tester.pump(const Duration(milliseconds: 100));
      expect(committed, isEmpty);

      // The run started and disabled the field: the half-typed input must
      // not be persisted mid-run.
      await pump(enabled: false);
      await tester.pump(const Duration(milliseconds: 900));
      expect(committed, isEmpty);
    });
  });
}
