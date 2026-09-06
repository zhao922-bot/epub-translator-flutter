import 'package:epub_translator_flutter/app/app.dart';
import 'package:epub_translator_flutter/app/theme/app_theme.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/shared/widgets/app_shell.dart';
import 'package:epub_translator_flutter/shared/widgets/page_scaffold.dart';
import 'package:epub_translator_flutter/shared/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySettingsStore extends SettingsStore {
  @override
  Future<TranslationConfig> load() async =>
      TranslationConfig.defaults().copyWith(textScale: 1.3);

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

class _MemoryJobHistoryStore extends JobHistoryStore {
  @override
  Future<List<TranslationJob>> load() async => const <TranslationJob>[];

  @override
  Future<void> save(List<TranslationJob> jobs) async {}
}

Widget _app() => ProviderScope(
  overrides: <Override>[
    settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
    jobHistoryStoreProvider.overrideWithValue(_MemoryJobHistoryStore()),
  ],
  child: const EpubTranslatorApp(),
);

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('themes use compact monochrome surfaces and controls', () {
    final ThemeData light = AppTheme.light(UiLanguage.english);
    final ThemeData dark = AppTheme.dark(UiLanguage.chinese);
    expect(light.scaffoldBackgroundColor, Colors.white);
    expect(light.colorScheme.primary, const Color(0xFF303038));
    expect(light.colorScheme.onPrimary, Colors.white);
    expect(light.colorScheme.outlineVariant, const Color(0xFFE7E7EB));
    expect(light.colorScheme.onSurface, const Color(0xFF27272D));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF151517));
    expect(dark.colorScheme.surfaceContainerHigh, const Color(0xFF1B1B1F));
    expect(dark.colorScheme.surfaceContainerHighest, const Color(0xFF232328));
    expect(dark.colorScheme.primary, const Color(0xFFE7E7EB));
    expect(dark.colorScheme.onPrimary, const Color(0xFF202024));
    for (final ThemeData theme in <ThemeData>[light, dark]) {
      final RoundedRectangleBorder button =
          theme.filledButtonTheme.style!.shape!.resolve(<WidgetState>{})!
              as RoundedRectangleBorder;
      expect(
        button.borderRadius.resolve(TextDirection.ltr).topLeft.x,
        inInclusiveRange(6, 8),
      );
      expect(theme.textTheme.bodyLarge!.fontSize, inInclusiveRange(13, 14));
      expect(theme.textTheme.bodySmall!.fontSize, 12);
    }
  });

  testWidgets(
    '800px shell has a narrow accessible icon rail with bottom settings',
    (tester) async {
      _viewport(tester, const Size(800, 600));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(AppShell.brandKey), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(PageScaffold.scaffoldKey)).dx, 72);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(tester.getCenter(find.byTooltip('Settings')).dy, greaterThan(500));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Translate' &&
              widget.properties.selected == true,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Theme'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('390px shell keeps bottom navigation at saved 1.3 text scale', (
    tester,
  ) async {
    _viewport(tester, const Size(390, 900));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(AppShell.brandKey), findsNothing);
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(AppShell))).scale(10),
      13,
    );
    expect(tester.takeException(), isNull);
  });

  for (final double width in <double>[390, 800, 1440]) {
    testWidgets('page frame and actions fit $width at 1.3 text scale', (
      tester,
    ) async {
      _viewport(tester, Size(width, 600));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(UiLanguage.english),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 600),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: PageScaffold(
                title: 'Translation workspace',
                subtitle: 'Choose a book and review translation settings.',
                actions: <Widget>[
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('View jobs'),
                  ),
                  FilledButton(
                    onPressed: () {},
                    child: const Text('Choose EPUB'),
                  ),
                ],
                child: const SectionCard(
                  title: 'Import a book',
                  icon: Icons.book_outlined,
                  variant: SectionCardVariant.emphasis,
                  child: Text('Your book appears here.'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(PageScaffold.headerKey), findsOneWidget);
      expect(find.byKey(PageScaffold.bodyKey), findsOneWidget);
      expect(find.text('Choose EPUB').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      final Material card = tester.widget(
        find.byKey(const ValueKey<String>('section-card-emphasis')),
      );
      expect(card.elevation, 0);
      expect(
        (card.shape! as RoundedRectangleBorder).borderRadius
            .resolve(TextDirection.ltr)
            .topLeft
            .x,
        lessThanOrEqualTo(10),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null,
        ),
        findsNothing,
      );
    });
  }
}
