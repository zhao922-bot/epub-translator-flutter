import 'package:epub_translator_flutter/app/theme/app_theme.dart';
import 'package:epub_translator_flutter/features/jobs/application/jobs_provider.dart';
import 'package:epub_translator_flutter/features/jobs/domain/models/job_summary.dart';
import 'package:epub_translator_flutter/features/jobs/presentation/pages/jobs_page.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_logs.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryJobHistoryStore extends JobHistoryStore {
  @override
  Future<List<TranslationJob>> load() async => const <TranslationJob>[];

  @override
  Future<void> save(List<TranslationJob> jobs) async {}
}

void main() {
  group('TranslationLogs typography', () {
    testWidgets('expanded logs use bodySmall without hardcoded Consolas', (
      tester,
    ) async {
      final ThemeData theme = AppTheme.light(UiLanguage.english);

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: TranslationLogs(
              strings: const AppStrings(UiLanguage.english),
              logs: const <String>['first line', 'second line'],
              initiallyExpanded: true,
            ),
          ),
        ),
      );

      final SelectableText logText = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      final TextStyle? style = logText.style;

      expect(style?.fontFamily, isNot('Consolas'));
      expect(style?.fontFamily, theme.textTheme.bodySmall?.fontFamily);
      expect(style?.fontSize, theme.textTheme.bodySmall?.fontSize);
      expect(style?.height, 1.45);
      expect(style?.color, const Color(0xFFCBD5E1));
    });

    testWidgets('collapsed preview uses bodySmall without hardcoded Consolas', (
      tester,
    ) async {
      final ThemeData theme = AppTheme.dark(UiLanguage.chinese);

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: TranslationLogs(
              strings: const AppStrings(UiLanguage.chinese),
              logs: const <String>['latest log entry'],
            ),
          ),
        ),
      );

      final Text preview = tester.widget<Text>(find.text('latest log entry'));
      final TextStyle? style = preview.style;

      expect(style?.fontFamily, isNot('Consolas'));
      expect(style?.fontFamily, theme.textTheme.bodySmall?.fontFamily);
      expect(style?.fontSize, theme.textTheme.bodySmall?.fontSize);
      expect(style?.color, theme.colorScheme.onSurfaceVariant);
    });
  });

  group('JobsPage typography', () {
    testWidgets('job titles use theme titleMedium hierarchy', (tester) async {
      final ThemeData theme = AppTheme.light(UiLanguage.english);
      const String jobTitle = 'demo-book.epub';

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            jobsProvider.overrideWith(
              (Ref ref) => const <JobSummary>[
                JobSummary(
                  id: 'job-1',
                  title: jobTitle,
                  status: 'Completed',
                  progressLabel: '10 / 10 blocks',
                  outputPath: '',
                  errorMessage: null,
                  isActive: false,
                  canOpenOutput: false,
                  canRetry: false,
                ),
              ],
            ),
            jobHistoryStoreProvider.overrideWithValue(_MemoryJobHistoryStore()),
          ],
          child: MaterialApp(theme: theme, home: const JobsPage()),
        ),
      );
      await tester.pumpAndSettle();

      final Text title = tester.widget<Text>(find.text(jobTitle));
      final TextStyle? expected = theme.textTheme.titleMedium;
      final TextStyle? style = title.style;

      expect(style?.fontSize, expected?.fontSize);
      expect(style?.fontWeight, expected?.fontWeight);
      expect(style?.height, expected?.height);
      expect(style?.fontFamily, expected?.fontFamily);
      expect(style?.fontFamily, isNot('Consolas'));
    });
  });

  group('AppTheme font inheritance', () {
    test('navigation and button text styles inherit app fontFamily', () {
      final ThemeData theme = AppTheme.light(UiLanguage.english);
      final String? appFont = theme.textTheme.bodyMedium?.fontFamily;

      expect(
        theme.navigationRailTheme.selectedLabelTextStyle?.fontFamily,
        appFont,
      );
      expect(
        theme.navigationRailTheme.unselectedLabelTextStyle?.fontFamily,
        appFont,
      );
      expect(
        theme.navigationBarTheme.labelTextStyle
            ?.resolve(const <WidgetState>{})
            ?.fontFamily,
        appFont,
      );
      expect(
        theme.filledButtonTheme.style?.textStyle
            ?.resolve(const <WidgetState>{})
            ?.fontFamily,
        appFont,
      );
      expect(theme.inputDecorationTheme.labelStyle?.fontFamily, appFont);
      expect(theme.chipTheme.labelStyle?.fontFamily, appFont);
    });
  });
}
