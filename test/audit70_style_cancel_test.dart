import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';

class _SlowFile implements File {
  _SlowFile(this.path, this.bytes);
  @override
  final String path;
  final Stream<List<int>> bytes;
  @override
  Stream<List<int>> openRead([int? start, int? end]) => bytes;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected file operation');
}

void main() {
  test('cancelling style analysis closes a stalled source fingerprint read', () async {
    final temp = await Directory.systemTemp.createTemp('audit-r15-style-hash-');
    final file = File('${temp.path}/book.epub');
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfile full-path="OPS/book.opf"/></container>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'OPS/book.opf',
          '<package><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'OPS/c.xhtml',
          '<html><body><p>The morning was cold, and the wind blew across the quiet fields.</p></body></html>',
        ),
      );
    final bytes = ZipEncoder().encodeBytes(archive);
    await file.writeAsBytes(bytes);
    final inspected = await EpubInspector().inspect(
      inputPath: file.path,
      outputDirectory: temp.path,
      cancelToken: CancelToken(),
    );
    final subscribed = Completer<void>();
    final stopped = Completer<void>();
    final stream = StreamController<List<int>>(
      onListen: subscribed.complete,
      onCancel: stopped.complete,
    );
    final token = CancelToken();
    var settled = false;
    Object? failure;
    final operation =
        IOOverrides.runZoned(
          () => EpubChapterTranslator().generateStyleProfile(
            config: TranslationConfig.defaults(),
            chapters: inspected.chapters,
            cancelToken: token,
          ),
          createFile: (name) => _SlowFile(name, stream.stream),
        ).then<void>(
          (_) {
            settled = true;
          },
          onError: (Object error) {
            failure = error;
            settled = true;
          },
        );
    await subscribed.future;
    token.cancel('audit cancellation during a stalled file read');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final settledBeforeRelease = settled;
    final closedBeforeRelease = stopped.isCompleted;
    stream.add(bytes);
    await stream.close();
    await operation;
    await temp.delete(recursive: true);
    debugPrint(
      'AUDIT style fingerprint: settledBeforeReadReleased=$settledBeforeRelease closedBeforeReadReleased=$closedBeforeRelease eventualError=${failure.runtimeType}',
    );
    expect(failure, isA<TranslationCancelledException>());
    expect(
      settledBeforeRelease,
      isTrue,
      reason:
          'Cancellation must not wait for an indefinitely stalled source stream to complete',
    );
    expect(closedBeforeRelease, isTrue);
  });
}
