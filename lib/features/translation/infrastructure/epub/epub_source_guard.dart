import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../domain/models/inspected_chapter.dart';

class EpubSourceChangedException implements Exception {
  const EpubSourceChangedException();

  @override
  String toString() =>
      'Source EPUB has changed since inspection. Inspect it again before translating. / '
      'EPUB 源文件在检查后发生变化，请重新检查后再翻译。';
}

EpubSourceIdentity? sourceIdentityForChapters(
  Iterable<InspectedChapter> chapters,
) {
  EpubSourceIdentity? identity;
  for (final chapter in chapters) {
    final candidate = chapter.sourceIdentity;
    if (candidate == null) continue;
    if (identity != null && identity.sha256 != candidate.sha256) {
      throw const EpubSourceChangedException();
    }
    identity = candidate;
  }
  return identity;
}

void checkEpubSourceHash(String actual, String? expected) {
  if (expected != null && actual != expected) {
    throw const EpubSourceChangedException();
  }
}

Future<void> validateInspectedSource(
  Iterable<InspectedChapter> chapters, {
  String? inputPath,
}) async {
  final identity = sourceIdentityForChapters(chapters);
  if (identity == null) return;
  final digest = await sha256
      .bind(File(inputPath ?? identity.inputPath).openRead())
      .first;
  checkEpubSourceHash(digest.toString(), identity.sha256);
}
