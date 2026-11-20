import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';

import 'quality/quality_document_residual.dart';
import 'quality/quality_residual_detector.dart';
import 'quality/quality_residual_models.dart';

export 'quality/quality_residual_models.dart'
    show TranslationResidualFinding, TranslationResidualKind;

/// Residual and quality checks for translated blocks across target languages.
class TranslationQuality {
  const TranslationQuality._();

  @visibleForTesting
  static String stripLockedTermsForTest(String text, String glossary) =>
      QualityResidualDetector.stripLockedTermsForTest(text, glossary);

  @visibleForTesting
  static List<RegExp> lockedTermRulesForTest(String glossary) =>
      QualityResidualDetector.lockedTermRulesForTest(glossary);

  static bool shouldCheckResidual(String targetLanguage) =>
      QualityResidualDetector.shouldCheckResidual(targetLanguage);

  static bool hasSuspiciousSourceResidual({
    required String sourceText,
    required String translatedText,
    required String targetLanguage,
    Set<String> sourceWorkTitles = const <String>{},
    String lockedGlossary = '',
  }) => QualityResidualDetector.hasSuspiciousSourceResidual(
    sourceText: sourceText,
    translatedText: translatedText,
    targetLanguage: targetLanguage,
    sourceWorkTitles: sourceWorkTitles,
    lockedGlossary: lockedGlossary,
  );

  static TranslationResidualFinding? findSuspiciousHtmlResidual({
    required String sourceHtml,
    required String translatedHtml,
    required String targetLanguage,
    bool allowRetainedAuthorSignature = false,
    bool allowBibliographicRetention = false,
    String lockedGlossary = '',
  }) => QualityDocumentResidual.findSuspiciousHtmlResidual(
    sourceHtml: sourceHtml,
    translatedHtml: translatedHtml,
    targetLanguage: targetLanguage,
    allowRetainedAuthorSignature: allowRetainedAuthorSignature,
    allowBibliographicRetention: allowBibliographicRetention,
    lockedGlossary: lockedGlossary,
  );

  static TranslationResidualFinding? findSuspiciousFragmentResidual({
    required DocumentFragment sourceFragment,
    required DocumentFragment translatedFragment,
    required String targetLanguage,
    bool allowRetainedAuthorSignature = false,
    bool allowBibliographicRetention = false,
    String lockedGlossary = '',
  }) => QualityDocumentResidual.findSuspiciousFragmentResidual(
    sourceFragment: sourceFragment,
    translatedFragment: translatedFragment,
    targetLanguage: targetLanguage,
    allowRetainedAuthorSignature: allowRetainedAuthorSignature,
    allowBibliographicRetention: allowBibliographicRetention,
    lockedGlossary: lockedGlossary,
  );

  static bool isPureCitationMetadata(String text) =>
      QualityDocumentResidual.isPureCitationMetadata(text);

  @visibleForTesting
  static Set<int> glossedTermTokenStartsForTest(String text) =>
      QualityScriptUtils.glossedTermTokenStartsForTest(text);

  @visibleForTesting
  static bool isParenthesizedTermGlossForTest(String text, String token) =>
      QualityScriptUtils.isParenthesizedTermGlossForTest(text, token);

  static const Map<String, Set<String>> auditedForeignTermNodes =
      QualityDocumentResidual.auditedForeignTermNodes;

  static bool isAuditedForeignTermNodeText(String nodeText) =>
      QualityDocumentResidual.isAuditedForeignTermNodeText(nodeText);

  @visibleForTesting
  static bool isCommonInstructionPhraseForTest(String text) =>
      QualityDocumentResidual.isCommonInstructionPhraseForTest(text);

  @visibleForTesting
  static bool debugLooksLikeEnglishTitleOrName(String text) =>
      QualityResidualDetector.debugLooksLikeEnglishTitleOrName(text);
}
