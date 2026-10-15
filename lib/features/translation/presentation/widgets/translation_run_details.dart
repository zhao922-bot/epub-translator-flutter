import 'package:flutter/material.dart';
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
  });
  final Map<String, Object> apiUsage;
  final String outputPath;
  final String? reportPath;
  final bool isChinese, enabled;
  final int elapsedMilliseconds;
  String t(String zh, String en) => isChinese ? zh : en;
  @override
  Widget build(BuildContext context) {
    final kinds = apiUsage['byKind'] as Map? ?? {};
    final times = apiUsage['elapsedMsByKind'] as Map? ?? {};
    final inputs = apiUsage['promptTokensByKind'] as Map? ?? {};
    final outputs = apiUsage['completionTokensByKind'] as Map? ?? {};
    final names = {
      'translation': t('正文／脚注', 'Body / notes'),
      'semanticReview': t('语义复核', 'Review'),
      'styleProfile': t('风格', 'Style'),
      'initialBookMemory': t('书籍记忆', 'Book memory'),
      'chapterMemory': t('章节记忆', 'Chapter memory'),
      'bookTitle': t('书名', 'Title'),
      'probe': t('连接测试', 'Connection probe'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (apiUsage.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              t(
                '本次 API：${apiUsage['requests'] ?? 0} 次 · 输入 ${apiUsage['promptTokens'] ?? 0} / 输出 ${apiUsage['completionTokens'] ?? 0} tokens',
                'API: ${apiUsage['requests'] ?? 0} calls · ${apiUsage['promptTokens'] ?? 0} input / ${apiUsage['completionTokens'] ?? 0} output tokens',
              ),
            ),
            subtitle: Text(
              t(
                '任务耗时 ${(elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒',
                'Run time ${(elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
              ),
            ),
            children: [
              for (final e in kinds.entries)
                ListTile(
                  dense: true,
                  title: Text(names[e.key] ?? e.key.toString()),
                  subtitle: Text(
                    t(
                      '${e.value} 次；输入 ${inputs[e.key] ?? 0} / 输出 ${outputs[e.key] ?? 0}；累计请求耗时 ${((times[e.key] as num? ?? 0) / 1000).toStringAsFixed(1)} 秒',
                      '${e.value} calls; ${inputs[e.key] ?? 0} in / ${outputs[e.key] ?? 0} out; cumulative request time ${((times[e.key] as num? ?? 0) / 1000).toStringAsFixed(1)} s',
                    ),
                  ),
                ),
              Text(
                t(
                  '并发请求耗时会重叠。token 来自接口返回，不等于账单；未返回用量的请求不会计作已知用量。',
                  'Concurrent request times overlap. Tokens are provider-reported, not a bill; requests without usage have unknown consumption.',
                ),
              ),
              Text(
                t(
                  '返回完整用量的请求：${apiUsage['usageReportedRequests'] ?? 0} / ${apiUsage['requests'] ?? 0}',
                  'Requests reporting full usage: ${apiUsage['usageReportedRequests'] ?? 0} / ${apiUsage['requests'] ?? 0}',
                ),
              ),
            ],
          ),
        if (reportPath != null)
          TextButton.icon(
            onPressed: enabled
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TranslationReviewPage(
                        reportPath: reportPath!,
                        outputPath: outputPath,
                        isChinese: isChinese,
                      ),
                    ),
                  )
                : null,
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(t('查看检查结果与修改建议', 'View checks and suggestions')),
          ),
      ],
    );
  }
}
