import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_review_page.dart';

class _ReportWriteFailure implements File {
  _ReportWriteFailure(this.file);
  final File file;
  @override
  String get path => file.path;
  @override
  Future<File> writeAsString(
    String contents, {
    Encoding encoding = utf8,
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async =>
      throw FileSystemException('Audit: report temp write failed', path);
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected report operation ${invocation.memberName}');
}

class _ReviewApi extends TranslationApiClient {
  int generation = 1;
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final system = (messages.first as Map)['content'] as String;
    Object reply;
    if (system.startsWith('Translate the book title')) {
      reply = '审查书籍';
    } else {
      final p = jsonDecode((messages.last as Map)['content'] as String) as Map;
      if (p['kind'] == 'initialBookMemory' || p['kind'] == 'chapterMemory') {
        reply = {
          'bookSummary': 'A sad person.',
          'summary': 'A sad person.',
          'glossary': [],
          'styleGuide': [],
          'recentChapters': [],
        };
      } else if (p['kind'] == 'semanticReview') {
        reply = {
          'blocks': [
            for (final b in p['blocks'] as List)
              generation == 1
                  ? {
                      'id': (b as Map)['id'],
                      'html': '<p>第一轮建议。</p>',
                      'issues': ['The source says sad.'],
                      'confidence': 'high',
                      'category': 'accuracy',
                      'sourceQuotes': ['She was sad'],
                    }
                  : {'id': (b as Map)['id'], 'unchanged': true},
          ],
        };
      } else {
        reply = {
          'blocks': [
            for (final b in p['blocks'] as List)
              {
                'id': (b as Map)['id'],
                'html': generation == 1 ? '<p>第一轮译文。</p>' : '<p>第二轮译文。</p>',
              },
          ],
        };
      }
    }
    return Response(
      requestOptions: RequestOptions(path: ''),
      data: {
        'choices': [
          {
            'message': {'content': reply is String ? reply : jsonEncode(reply)},
          },
        ],
      },
    );
  }
}

void main() {
  testWidgets('a failed new report write cannot present previous-run suggestions', (
    tester,
  ) async {
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('audit-r28-stale-'),
    );
    final dir = temp!;
    final cache = TranslationCacheStore(
      cacheRoot: Directory('${dir.path}/cache'),
    );
    addTearDown(() async {
      await cache.waitForMaintenanceForTest();
      await dir.delete(recursive: true);
    });
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
          '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'OPS/c.xhtml',
          '<html><head><title>Chapter</title></head><body><p>She was sad but continued walking.</p></body></html>',
        ),
      );
    final api = _ReviewApi(),
        translator = EpubChapterTranslator(cacheStore: cache, apiClient: api);
    final config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'https://offline.invalid',
      apiKey: 'offline',
      model: 'audit-1',
      styleProfileEnabled: false,
      residualQualityCheck: false,
      semanticQualityCheck: true,
      semanticReviewScope: SemanticReviewScope.all,
    );
    final artifacts = await tester.runAsync(() async {
      final input = await File(
        '${dir.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      final inspected = await EpubInspector().inspect(
        inputPath: input.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      final first = await translator.translateChapters(
        inputPath: input.path,
        outputDirectory: dir.path,
        config: config,
        chapters: inspected.chapters,
        cancelToken: CancelToken(),
      );
      expect(first.job.reviewSuggestionCount, 1);
      final originalReport = await File(
        first.qualityReportPath!,
      ).readAsString();
      api.generation = 2;
      final fileZone = Zone.current;
      final second = await IOOverrides.runZoned(
        () => translator.translateChapters(
          inputPath: input.path,
          outputDirectory: dir.path,
          config: config.copyWith(model: 'audit-2'),
          chapters: inspected.chapters,
          cancelToken: CancelToken(),
        ),
        createFile: (name) {
          final real = fileZone.run(() => File(name));
          return name.contains('.quality.json.tmp.')
              ? _ReportWriteFailure(real)
              : real;
        },
        fseGetType: (name, followLinks) => fileZone.run(
          () => FileSystemEntity.type(name, followLinks: followLinks),
        ),
        fseGetTypeSync: (name, followLinks) => fileZone.run(
          () => FileSystemEntity.typeSync(name, followLinks: followLinks),
        ),
      );
      expect(second.job.outputPath, first.job.outputPath);
      expect(second.job.reviewSuggestionCount, 0);
      expect(second.qualityReportPath, isNull);
      expect(second.job.qualityReportPath, isNull);
      final report = await const TranslationReviewStore().load(
        first.qualityReportPath!,
      );
      final zip = ZipDecoder().decodeBytes(
        await File(second.job.outputPath).readAsBytes(),
      );
      final bytes = zip.findFile('OPS/c.xhtml')!.content as List<int>;
      final currentDigest = sha256.convert(bytes).toString();
      final oldDigest =
          (((report['rendering'] as Map)['chapters'] as Map)['OPS/c.xhtml']
              as Map)['baseHtmlSha256'];
      final reportUnchanged =
          await File(first.qualityReportPath!).readAsString() == originalReport;
      expect(utf8.decode(bytes), contains('第二轮译文'));
      expect(currentDigest, isNot(oldDigest));
      // The export path has a later identity guard; verify it still blocks.
      await expectLater(
        const TranslationReviewStore().export(
          reportPath: first.qualityReportPath!,
          baseOutputPath: second.job.outputPath,
          accepted: {},
        ),
        throwsA(isA<FormatException>()),
      );
      debugPrint(
        'AUDIT stale report currentSuggestions=${second.job.reviewSuggestionCount} loadedSuggestions=${(report['corrections'] as List).length} reportUnchanged=$reportUnchanged baselineHashMismatch=${currentDigest != oldDigest} exportBlocked=true',
      );
      return (report: first.qualityReportPath!, output: second.job.outputPath);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationReviewPage(
          reportPath: artifacts!.report,
          outputPath: artifacts.output,
          isChinese: false,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not read the review report'),
      findsOneWidget,
    );
    final staleVisible = find.text('第一轮建议。').evaluate().length;
    debugPrint(
      'AUDIT stale report UI oldSuggestionVisible=$staleVisible frameworkError=${tester.takeException()}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    // A partial/legacy rendering snapshot must not bypass the view-time guard.
    await tester.runAsync(() async {
      final file = File(artifacts.report);
      final legacy =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      (legacy['rendering'] as Map)['completeSnapshot'] = false;
      await file.writeAsString(jsonEncode(legacy));
      await expectLater(
        const TranslationReviewStore().load(
          artifacts.report,
          expectedOutputPath: artifacts.output,
        ),
        throwsA(isA<FormatException>()),
      );
    });
    expect(
      staleVisible,
      0,
      reason:
          'Opening the current run review must reject or warn about a report bound to the overwritten previous EPUB.',
    );
  });
}
