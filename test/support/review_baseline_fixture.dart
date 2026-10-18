import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// A partial version-2 report still owns hashes for its available chapters.
Map<String, dynamic> writeReviewBaselineFixture(String output) {
  const source = '<html><body><p>Alas, she cried.</p></body></html>';
  const draft = '<p>她喜极而泣。</p>';
  const baseline = '<html><body>$draft</body></html>';
  final archive = Archive()
    ..add(
      ArchiveFile.string('mimetype', 'application/epub+zip')
        ..compression = CompressionType.none,
    )
    ..add(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfile full-path="book.opf"/></container>',
      ),
    )
    ..add(
      ArchiveFile.string(
        'book.opf',
        '<package><manifest><item id="s" href="story.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="s"/></spine></package>',
      ),
    )
    ..add(ArchiveFile.string('story.xhtml', baseline));
  File(output).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  return {
    'completeSnapshot': false,
    'bilingual': false,
    'targetLanguage': 'Chinese',
    'lockedGlossary': '',
    'chapters': {
      'story.xhtml': {
        'originalHtml': source,
        'translations': {'p-1': draft},
        'baseHtmlSha256': sha256.convert(utf8.encode(baseline)).toString(),
        'countedNames': [],
        'degraded': [],
      },
    },
  };
}
