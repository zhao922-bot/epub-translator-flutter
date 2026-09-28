import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'bug_audit_regression_test.dart' as fixture;

const content =
    '<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Chapter</title></head>'
    '<body><h1 id="intro">Introduction</h1><h2 id="ending">Conclusion</h2></body></html>';
const translations = ['<h1 id="intro">引言</h1>', '<h2 id="ending">结论</h2>'];

Future<File> book(Directory directory, {bool nav = false}) async {
  final file = File('${directory.path}/input.epub');
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/content.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
            '<metadata><dc:language xmlns:dc="http://purl.org/dc/elements/1.1/">en</dc:language></metadata>'
            '<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
            '${nav ? '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' : ''}'
            '</manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>',
      ),
    )
    ..addFile(ArchiveFile.string('OPS/chapter.xhtml', content))
    ..addFile(
      ArchiveFile.string(
        'OPS/toc.ncx',
        '<ncx><navMap><navPoint id="n1"><navLabel><text>Introduction</text></navLabel><content src="chapter.xhtml#intro"/></navPoint>'
            '<navPoint id="n2"><navLabel><text>Conclusion</text></navLabel><content src="chapter.xhtml#ending"/></navPoint></navMap></ncx>',
      ),
    );
  if (nav) {
    archive.addFile(
      ArchiveFile.string(
        'OPS/nav.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav></body></html>',
      ),
    );
  }
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return file;
}

List<String> labels(String ncx) => XmlDocument.parse(ncx).descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == 'text')
    .map((e) => e.innerText)
    .toList();

Future<String> entry(String epub, String path) async {
  final archive = ZipDecoder().decodeBytes(await File(epub).readAsBytes());
  return utf8.decode(archive.findFile(path)!.content as List<int>);
}

void main() {
  test(
    'control: section labels translate when source blocks reach repacker',
    () async {
      final temp = await Directory.systemTemp.createTemp('audit3-control-');
      addTearDown(() => temp.delete(recursive: true));
      final source = await book(temp);
      final output = '${temp.path}/result.epub';
      await EpubRepacker().writeTranslatedEpub(
        inputPath: source.path,
        outputFilePath: output,
        config: TranslationConfig.defaults(),
        chapters: [fixture.translatedChapter(content, translations)],
      );
      expect(labels(await entry(output, 'OPS/toc.ncx')), ['引言', '结论']);
    },
  );

  test(
    'real translation pipeline retains translated NCX section labels',
    () async {
      final temp = await Directory.systemTemp.createTemp('audit3-pipeline-');
      addTearDown(() => temp.delete(recursive: true));
      final source = await book(temp);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var blockRequests = 0;
      server.listen((request) async {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final payload =
            jsonDecode(
                  ((data['messages'] as List).last as Map)['content'] as String,
                )
                as Map;
        final Object response;
        if (payload['kind'] == 'initialBookMemory') {
          response = {
            'bookSummary': 'A chapter.',
            'styleGuide': [],
            'glossary': [],
            'recentChapters': [],
          };
        } else if (payload['kind'] == 'chapterMemory') {
          response = {
            'title': 'Chapter',
            'summary': 'A chapter.',
            'continuityNotes': [],
            'glossary': [],
          };
        } else {
          blockRequests++;
          response = {
            'blocks': [
              for (final block in payload['blocks'] as List)
                {
                  'id': (block as Map)['id'],
                  'html': block['id'] == 'h1-1'
                      ? translations[0]
                      : translations[1],
                },
            ],
          };
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(response)},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final repository = EpubTranslationRepository(
        cacheStore: fixture.MemoryCache(),
      );
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'audit-placeholder',
        model: 'audit-model',
        styleProfileEnabled: false,
        residualQualityCheck: false,
        maxConcurrent: 1,
        maxRetries: 1,
      );
      final inspected = await repository.startJob(
        inputPath: source.path,
        outputDirectory: temp.path,
        config: config,
      );
      final result = await repository.translateChapters(
        inputPath: source.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspected.chapters,
      );
      expect(result.job.status, TranslationJobStatus.completed);
      expect(blockRequests, greaterThan(0));
      expect(
        result.chapters.single.blocks.every((b) => b.sourceHtml.isEmpty),
        isTrue,
      );
      expect(
        await entry(result.job.outputPath, 'OPS/chapter.xhtml'),
        contains('引言'),
      );
      expect(labels(await entry(result.job.outputPath, 'OPS/toc.ncx')), [
        '引言',
        '结论',
      ]);
      final requestsBeforeResume = blockRequests;
      final resumed = await repository.translateChapters(
        inputPath: source.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspected.chapters,
      );
      expect(blockRequests, requestsBeforeResume);
      expect(labels(await entry(resumed.job.outputPath, 'OPS/toc.ncx')), [
        '引言',
        '结论',
      ]);
    },
  );

  test(
    'EPUB3 navigation outside the spine receives translated labels',
    () async {
      final temp = await Directory.systemTemp.createTemp('audit3-nav-');
      addTearDown(() => temp.delete(recursive: true));
      final source = await book(temp, nav: true);
      final output = '${temp.path}/result.epub';
      final repository = EpubTranslationRepository(
        cacheStore: fixture.MemoryCache(),
      );
      final inspected = await repository.startJob(
        inputPath: source.path,
        outputDirectory: temp.path,
        config: TranslationConfig.defaults(),
      );
      expect(inspected.chapters.map((c) => c.path).toList(), [
        'OPS/chapter.xhtml',
      ]);
      await EpubRepacker().writeTranslatedEpub(
        inputPath: source.path,
        outputFilePath: output,
        config: TranslationConfig.defaults(),
        chapters: [fixture.translatedChapter(content, translations)],
      );
      final outputNav = html.parse(await entry(output, 'OPS/nav.xhtml'));
      expect(outputNav.querySelector('nav a')!.text, '引言: 结论');
    },
  );

  test(
    'retry keeps the user-selected subset instead of translating all chapters',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final repository = RetryProbeRepository();
      final controller = TranslationDashboardController(
        repository: repository,
        windowsPathObserverOverride: (_) async {},
      );
      addTearDown(controller.dispose);
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(
          apiKey: 'audit-placeholder',
          styleProfileEnabled: false,
        ),
      );
      controller.setInputPath('C:/audit/book.epub');
      controller.setOutputDirectory('C:/audit/output');
      await controller.startInspection();
      controller.toggleChapterInclusion('OPS/second.xhtml', false);
      await controller.startTranslation();
      expect(repository.selections.single, ['OPS/chapter.xhtml']);
      expect(controller.state.job!.status, TranslationJobStatus.failed);
      await controller.retryJob(controller.state.job!.id);
      expect(repository.selections, hasLength(2));
      expect(repository.selections.last, repository.selections.first);
      expect(controller.state.job!.selectedChapterPaths, ['OPS/chapter.xhtml']);
    },
  );

  test('selection survives JSON and repository progress callbacks', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final repository = RetryProbeRepository();
    final controller = TranslationDashboardController(
      repository: repository,
      windowsPathObserverOverride: (_) async {},
    );
    addTearDown(controller.dispose);
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('C:/audit/book.epub');
    controller.setOutputDirectory('C:/audit/output');
    await controller.startInspection();
    controller.toggleChapterInclusion('OPS/chapter.xhtml', false);
    await controller.startTranslation();
    final saved = TranslationJob.fromJson(
      jsonDecode(jsonEncode(controller.state.job!.toJson()))
          as Map<String, dynamic>,
    );
    expect(saved.selectedChapterPaths, ['OPS/second.xhtml']);
    expect(saved.copyWith(progress: 0.5).selectedChapterPaths, [
      'OPS/second.xhtml',
    ]);
    expect(
      saved.copyWith(selectedChapterPaths: null).selectedChapterPaths,
      isNull,
    );
    final restarted = TranslationDashboardController(
      repository: repository,
      historyStore: SeedHistory(saved),
      windowsPathObserverOverride: (_) async {},
    );
    addTearDown(restarted.dispose);
    restarted.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    await Future<void>.delayed(Duration.zero);
    await restarted.retryJob(saved.id);
    expect(repository.selections.last, ['OPS/second.xhtml']);
  });

  for (final scope in <List<String>?>[
    null,
    [],
    ['OPS/missing.xhtml'],
  ]) {
    test(
      'unknown, empty or missing retry scope never starts paid work: $scope',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final repository = RetryProbeRepository();
        final saved = TranslationJob(
          id: 'old',
          inputPath: 'C:/audit/book.epub',
          outputPath: 'C:/audit/output/book.epub',
          status: TranslationJobStatus.failed,
          phase: TranslationJobPhase.translation,
          progress: 0.5,
          totalBlocks: 2,
          selectedChapterPaths: scope,
        );
        final controller = TranslationDashboardController(
          repository: repository,
          historyStore: SeedHistory(saved),
          windowsPathObserverOverride: (_) async {},
        );
        addTearDown(controller.dispose);
        await Future<void>.delayed(Duration.zero);
        await controller.retryJob('old');
        expect(repository.selections, isEmpty);
        expect(repository.styleRequests, 0);
        expect(controller.state.job!.status, TranslationJobStatus.inspected);
        expect(
          controller.state.inspectedChapters.any((c) => c.includeInTranslation),
          isFalse,
        );
        expect(
          controller.state.logs.last,
          contains(
            scope == null ? 'no saved chapter selection' : 'selection is empty',
          ),
        );
      },
    );
  }

  test(
    'malformed saved selection is treated as unknown rather than truncated',
    () {
      final job = TranslationJob.fromJson({
        'id': 'bad',
        'selectedChapterPaths': ['chapter.xhtml', 1],
      });
      expect(job.selectedChapterPaths, isNull);
    },
  );

  for (final rendered in [false, true]) {
    test('manifest nav synchronizes toc only and keeps rendered prose: $rendered', () {
      const navPath = 'OPS/nav中.xhtml';
      const source =
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>'
          '<body><p id="prose">Original prose</p><nav epub:type="toc"><ol><li><a href="chapter.xhtml#intro"><span>Introduction</span><span class="pagenum">1</span></a></li>'
          '<li><a href="chapter.xhtml#unknown">Keep me</a></li></ol></nav>'
          '<nav epub:type="page-list"><a href="chapter.xhtml#intro">1</a></nav>'
          '<nav epub:type="landmarks"><a href="chapter.xhtml#intro">Start</a></nav></body></html>';
      final output = EpubIsolateWorker.renderNavigationMetadata(
        archiveFiles: {
          'META-INF/container.xml': utf8.encode(
            '<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
          ),
          'OPS/package.opf': utf8.encode(
            '<package><metadata/><manifest><item id="nav" href="nav%E4%B8%AD.xhtml" properties="nav scripted" media-type="application/xhtml+xml"/></manifest><spine/></package>',
          ),
          navPath: utf8.encode(source),
        },
        labelsByPath: {'OPS/chapter.xhtml#intro': '引言'},
        languageTag: 'zh-CN',
        renderedHtmlByPath: rendered
            ? {navPath: source.replaceAll('Original prose', '已译正文')}
            : {},
      );
      expect(() => XmlDocument.parse(output[navPath]!), returnsNormally);
      final document = html.parse(output[navPath]!);
      expect(document.querySelectorAll('a').map((a) => a.text).toList(), [
        '引言1',
        'Keep me',
        '1',
        'Start',
      ]);
      expect(
        document.querySelector('#prose')!.text,
        rendered ? '已译正文' : 'Original prose',
      );
      expect(
        document.querySelector('a')!.attributes['href'],
        'chapter.xhtml#intro',
      );
    });
  }

  test('malformed non-spine nav is rejected during inspection', () {
    expect(
      () => EpubInspector.validateNavigationEncodings(
        files: {
          'package.opf': utf8.encode(
            '<package><manifest><item id="nav" href="nav.xhtml" properties="nav"/></manifest></package>',
          ),
          'nav.xhtml': utf8.encode('<html><body>broken</html>'),
        },
        opfPath: 'package.opf',
      ),
      throwsA(isA<XmlTagException>()),
    );
  });

  test('EPUB namespace aliases identify the table of contents', () {
    final output = synchronizeEpub3Navigation(
      markup:
          '<html xmlns:e="http://www.idpf.org/2007/ops"><body><nav e:type="toc"><a href="chapter.xhtml">Chapter</a></nav>'
          '<nav e:type="page-list"><a href="chapter.xhtml">1</a></nav></body></html>',
      documentPath: 'OPS/nav.xhtml',
      labelsByPath: {'OPS/chapter.xhtml': '标题'},
      languageTag: 'zh-CN',
    );
    expect(
      html.parse(output).querySelectorAll('a').map((a) => a.text).toList(),
      ['标题', '1'],
    );
  });
}

class SeedHistory extends JobHistoryStore {
  SeedHistory(this.job);
  final TranslationJob job;
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: [job], clearedAt: 0);
  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {}
}

class RetryProbeRepository extends EpubTranslationRepository {
  final selections = <List<String>>[];
  int styleRequests = 0;
  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async {
    styleRequests++;
    return TranslationStyleProfile.empty;
  }

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final first = fixture.translatedChapter(
      '<html><body><p>Hello.</p></body></html>',
      ['<p>你好。</p>'],
    );
    return InspectionResult(
      job: TranslationJob(
        id: 'inspection',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.inspected,
        progress: 1,
      ),
      chapters: [
        first,
        first.copyWith(path: 'OPS/second.xhtml'),
      ],
    );
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    selections.add(
      chapters.where((c) => c.includeInTranslation).map((c) => c.path).toList(),
    );
    onProgress?.call(
      TranslationJob(
        id: 'repository-job',
        inputPath: inputPath,
        outputPath: '$outputDirectory/book.epub',
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.translation,
        progress: 0.1,
      ),
      'Working',
    );
    throw StateError('Simulated translation failure');
  }
}
