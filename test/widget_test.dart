import 'package:epub_translator_flutter/app/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots into translation workspace shell', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: EpubTranslatorApp()));
    await tester.pumpAndSettle();

    expect(find.text('Inspect EPUB'), findsWidgets);
    expect(find.text('Book Setup'), findsOneWidget);
  });
}
