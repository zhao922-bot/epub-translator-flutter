import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/review_strings.dart';
import '../../domain/models/translation_config.dart';
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
    final kinds = apiUsage['byKind'] as Map? ?? {};
    final times = apiUsage['elapsedMsByKind'] as Map? ?? {};
    final inputs = apiUsage['promptTokensByKind'] as Map? ?? {};
    final outputs = apiUsage['completionTokensByKind'] as Map? ?? {};
    final reviewPath = reportPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (apiUsage.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              strings.runApiUsage(
                apiUsage['requests'] ?? 0,
                apiUsage['promptTokens'] ?? 0,
                apiUsage['completionTokens'] ?? 0,
              ),
            ),
            subtitle: Text(
              strings.runElapsed(
                (elapsedMilliseconds / 1000).toStringAsFixed(1),
              ),
            ),
            children: [
              for (final entry in kinds.entries)
                ListTile(
                  dense: true,
                  title: Text(strings.runRequestKind(entry.key)),
                  subtitle: Text(
                    strings.runRequestUsage(
                      entry.value ?? 0,
                      inputs[entry.key] ?? 0,
                      outputs[entry.key] ?? 0,
                      ((times[entry.key] as num? ?? 0) / 1000).toStringAsFixed(
                        1,
                      ),
                    ),
                  ),
                ),
              Text(strings.runUsageHelp),
              Text(
                strings.runUsageReported(
                  apiUsage['usageReportedRequests'] ?? 0,
                  apiUsage['requests'] ?? 0,
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
