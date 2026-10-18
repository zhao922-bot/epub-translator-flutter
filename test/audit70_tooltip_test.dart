import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/app/theme/app_theme.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('${dark ? "dark" : "light"} actual tooltip text is readable', (
      tester,
    ) async {
      final theme = dark
          ? AppTheme.dark(UiLanguage.english)
          : AppTheme.light(UiLanguage.english);
      final key = GlobalKey<TooltipState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: Tooltip(
                key: key,
                message: 'Audit tooltip probe',
                child: const Icon(Icons.help_outline),
              ),
            ),
          ),
        ),
      );
      key.currentState!.ensureTooltipVisible();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == 'Audit tooltip probe',
        ),
      );
      final foreground = rich.text.style!.color!;
      final background =
          (theme.tooltipTheme.decoration! as BoxDecoration).color!;
      final a = foreground.computeLuminance(),
          b = background.computeLuminance();
      final contrast = (math.max(a, b) + .05) / (math.min(a, b) + .05);
      debugPrint(
        'AUDIT tooltip dark=$dark foreground=$foreground background=$background contrast=$contrast',
      );
      expect(
        contrast,
        greaterThanOrEqualTo(4.5),
        reason:
            'Tooltip text must remain readable against the application-provided background',
      );
    });
  }
}
