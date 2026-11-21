import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/book_budget_strings.dart';
import '../../../../shared/localization/review_strings.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_token_usage.dart';
import '../pages/translation_review_page.dart';

class TranslationRunDetails extends StatelessWidget {
  const TranslationRunDetails({
    super.key,
    required this.apiUsage,
    required this.outputPath,
    required this.isChinese,
    this.reportPath,
    this.elapsedMilliseconds = 0,
    this.enabled = true,
    this.showReviewLink = true,
  });

  final Map<String, Object> apiUsage;
  final String outputPath;
  final String? reportPath;
  final bool isChinese, enabled, showReviewLink;
  final int elapsedMilliseconds;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(
      isChinese ? UiLanguage.chinese : UiLanguage.english,
    );
    final usage = TranslationTokenUsage(apiUsage);
    final cumulative = usage.cumulative;
    final kinds = usage.countsByKind('byKind');
    final times = usage.countsByKind('elapsedMsByKind');
    final inputs = usage.countsByKind('promptTokensByKind');
    final outputs = usage.countsByKind('completionTokensByKind');
    final reviewPath = reportPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (apiUsage.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              strings.runApiUsage(
                usage.requests,
                usage.promptTokens,
                usage.completionTokens,
              ),
            ),
            subtitle: Text(
              [
                if (usage.maxBookTokens > 0) ...[
                  strings.bookAccountedTokens(usage.accountedTokens),
                  strings.bookBudgetThreshold(usage.maxBookTokens),
                ],
                if (elapsedMilliseconds > 0 || usage.maxBookTokens == 0)
                  strings.runElapsed(
                    (elapsedMilliseconds / 1000).toStringAsFixed(1),
                  ),
              ].join(' · '),
            ),
            children: [
              for (final entry in kinds.entries)
                ListTile(
                  dense: true,
                  title: Text(strings.runRequestKind(entry.key)),
                  subtitle: Text(
                    strings.runRequestUsage(
                      entry.value,
                      inputs[entry.key] ?? 0,
                      outputs[entry.key] ?? 0,
                      ((times[entry.key] ?? 0) / 1000).toStringAsFixed(1),
                    ),
                  ),
                ),
              Text(strings.runUsageHelp),
              Text(
                strings.runUsageReported(
                  usage.reportedRequests,
                  usage.requests,
                ),
              ),
              if (usage.priorAccountedTokens > 0)
                Text(strings.bookEarlierTokens(usage.priorAccountedTokens)),
              if (cumulative.totalReportedRequests > 0)
                Text(
                  strings.bookProviderTotal(
                    cumulative.count('reportedTotalTokens'),
                    cumulative.totalReportedRequests,
                  ),
                ),
              if (cumulative.incompleteUsageRequests > 0)
                Text(
                  cumulative.estimatedUnreportedTokens > 0
                      ? strings.bookUsageUnreported(
                          cumulative.incompleteUsageRequests,
                          cumulative.estimatedUnreportedTokens,
                        )
                      : strings.bookUsageUnknown(
                          cumulative.incompleteUsageRequests,
                        ),
                ),
              if (cumulative.hasReasoningUsage)
                Text(
                  strings.bookReasoningTokens(
                    cumulative.count('reasoningTokens'),
                  ),
                ),
              if (cumulative.hasCachedPromptUsage)
                Text(
                  strings.bookPromptCacheTokens(
                    cumulative.count('cachedPromptTokens'),
                  ),
                ),
            ],
          ),
        if (showReviewLink && reviewPath != null)
          TextButton.icon(
            onPressed: enabled
                ? () => TranslationReviewPage.open(
                    context,
                    reportPath: reviewPath,
                    outputPath: outputPath,
                    isChinese: isChinese,
                  )
                : null,
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(strings.openReview),
          ),
      ],
    );
  }
}
