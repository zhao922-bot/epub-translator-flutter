import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

const ns = 'http://www.w3.org/1999/xhtml';
const svg =
    '<s:svg xmlns:s="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><s:defs><s:linearGradient id="g"><s:stop offset="0" stop-color="red"/></s:linearGradient></s:defs><s:rect width="100" height="100" fill="url(#g)"/></s:svg>';
Future<File> makeBook(
  Directory dir,
  String name,
  String markup, {
  bool withSvg = false,
}) async {
  final archive = Archive()
    ..add(
      ArchiveFile.noCompress(
        'mimetype',
        20,
        utf8.encode('application/epub+zip'),
      ),
    )
    ..add(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
    )
    ..add(
      ArchiveFile.string(
        'OPS/book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:83901b30-2a2e-4c0a-bc98-4d814775da30</dc:identifier><dc:title>Audit Book</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-14T00:00:00Z</meta></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"${withSvg ? ' properties="svg"' : ''}/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="c"/></spine></package>',
      ),
    )
    ..add(
      ArchiveFile.string(
        'OPS/nav.xhtml',
        '<html xmlns="$ns" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol><li><a href="c.xhtml">Chapter</a></li></ol></nav></body></html>',
      ),
    )
    ..add(ArchiveFile.string('OPS/c.xhtml', markup));
  final file = File('${dir.path}/$name.epub');
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return file;
}
