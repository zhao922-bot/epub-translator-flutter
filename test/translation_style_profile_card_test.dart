import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_style_profile_card.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('typing in a focused field is not rewritten by profile sync', (
    WidgetTester tester,
  ) async {
    // Regression: every keystroke in the "secondary genres" field used to
    // trigger onChanged -> parent rebuild -> didUpdateWidget rewriting the
    // controller with the normalized join ('history, philosophy'), yanking
    // the cursor to the end each time.
    TranslationStyleProfile profile = const TranslationStyleProfile(
      secondaryGenres: <String>['history'],
    );
    const AppStrings strings = AppStrings(UiLanguage.chinese);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return TranslationStyleProfileCard(
                  strings: strings,
                  profile: profile,
                  confirmed: false,
                  enabled: true,
                  editable: true,
                  isGenerating: false,
                  canGenerate: false,
                  onGenerate: () {},
                  onConfirm: () {},
                  onChanged:
                      ({
                        String? primaryGenre,
                        String? secondaryGenresCsv,
                        String? tone,
                        String? sentenceStyle,
                        String? constraintsText,
                        String? avoidText,
                        TranslationStyleConfidence? confidence,
                      }) {
                        if (secondaryGenresCsv != null) {
                          setState(() {
                            profile = profile.copyWith(
                              secondaryGenres: secondaryGenresCsv
                                  .split(',')
                                  .map((String s) => s.trim())
                                  .where((String s) => s.isNotEmpty)
                                  .toList(),
                            );
                          });
                        }
                      },
                );
              },
            ),
          ),
        ),
      ),
    );

    final Finder field = find.byWidgetPredicate(
      (Widget widget) =>
          widget is TextField &&
          widget.decoration?.labelText == strings.styleProfileSecondaryGenres,
    );
    expect(field, findsOneWidget);

    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'history,philosophy');
    await tester.pump();

    // The focused field keeps the user's raw input; the model already holds
    // the parsed list. (Before the fix this became 'history, philosophy'
    // with the cursor yanked to the end.)
    final TextField textField = tester.widget<TextField>(field);
    expect(textField.controller?.text, 'history,philosophy');
    expect(profile.secondaryGenres, <String>['history', 'philosophy']);
  });
}
