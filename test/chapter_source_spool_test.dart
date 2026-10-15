import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/chapter_source_spool.dart';
import 'package:flutter_test/flutter_test.dart';

InspectedChapter chapter(String text, {String path = 'OPS/c.xhtml'}) =>
    InspectedChapter(
      path: path,
      title: 'Chapter',
      body: 'preview $text',
      originalHtml: '<html><body><p>$text</p></body></html>',
      blocks: [
        ExtractedBlock(
          id: 'p-1',
          tagName: 'p',
          sourceHtml: '<p>$text</p>',
          sourceText: text,
          translatedHtml: '<p>traduit 🙂</p>',
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );

InspectedChapter cleared(InspectedChapter source) => source.copyWith(
  body: '',
  originalHtml: '',
  blocks: [
    for (final block in source.blocks)
      block.copyWith(sourceHtml: '', sourceText: ''),
  ],
);

void main() {
  late Directory directory;
  late ChapterSourceSpool spool;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-spool-test-');
    spool = ChapterSourceSpool(directory: directory);
  });
  tearDown(() async {
    await spool.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'worker round trip preserves exact sources and current translations',
    () async {
      final original = chapter('中文 🙂 &lt;T&gt;');
      final released = await spool.release(original);
      expect(released.originalHtml, isEmpty);
      expect(released.body, isEmpty);
      expect(released.blocks.single.sourceHtml, isEmpty);
      final changed = released.copyWith(
        blocks: [
          released.blocks.single.copyWith(
            translatedHtml: '<p>retry result</p>',
          ),
        ],
      );
      final restored = await spool.restore(changed);
      expect(restored.originalHtml, original.originalHtml);
      expect(restored.body, original.body);
      expect(
        restored.blocks.single.sourceHtml,
        original.blocks.single.sourceHtml,
      );
      expect(
        restored.blocks.single.sourceText,
        original.blocks.single.sourceText,
      );
      expect(restored.blocks.single.translatedHtml, '<p>retry result</p>');
    },
  );

  test(
    'queued reads observe earlier writes and replacements keep invocation order',
    () async {
      final first = chapter('first');
      final second = chapter('second');
      final initialWrite = spool.release(first);
      final firstRead = spool.restore(cleared(first));
      final replacement = spool.release(second);
      final otherWrite = spool.release(
        chapter('other', path: 'OPS/other.xhtml'),
      );
      await initialWrite;
      expect((await firstRead).originalHtml, first.originalHtml);
      await Future.wait([replacement, otherWrite]);
      expect(
        (await spool.restore(cleared(second))).originalHtml,
        second.originalHtml,
      );
      expect(
        (await spool.restore(
          cleared(chapter('other', path: 'OPS/other.xhtml')),
        )).body,
        'preview other',
      );
    },
  );

  test(
    'skeleton restore leaves block sources released and skips their index',
    () async {
      final original = chapter('skeleton');
      final released = await spool.release(original);
      final file =
          (await directory.list().where((e) => e is File).toList()).single
              as File;
      final payload =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // A skeleton read must not depend on the unused blocks representation.
      payload['blocks'] = 'not required for skeleton export';
      await file.writeAsString(jsonEncode(payload));
      final restored = await spool.restore(released, blocks: false);
      expect(restored.originalHtml, original.originalHtml);
      expect(restored.body, original.body);
      expect(restored.blocks.single.sourceHtml, isEmpty);
      expect(restored.blocks.single.sourceText, isEmpty);
      expect(
        restored.blocks.single.translatedHtml,
        released.blocks.single.translatedHtml,
      );
    },
  );

  test(
    'cancellation checks surround worker restore without capturing callbacks',
    () async {
      final original = chapter('cancel');
      final released = await spool.release(original);
      final port = ReceivePort();
      addTearDown(port.close);
      final restored = await spool.restore(
        released,
        isCancelled: () {
          // A ReceivePort cannot cross an isolate boundary.
          expect(port.hashCode, isA<int>());
          return false;
        },
      );
      expect(restored.originalHtml, original.originalHtml);
      var checks = 0;
      await expectLater(
        spool.restore(released, isCancelled: () => ++checks >= 3),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(checks, 3);
      // A failed/cancelled operation must not poison subsequent requests.
      expect((await spool.restore(released)).body, original.body);
    },
  );

  test('failed write retains sources and the same queue can recover', () async {
    final blocked = File('${directory.path}/blocked');
    await blocked.writeAsString('not a directory');
    final failing = ChapterSourceSpool(directory: Directory(blocked.path));
    addTearDown(failing.dispose);
    final original = chapter('keep me');
    expect(await failing.release(original), same(original));
    await blocked.delete();
    await Directory(blocked.path).create();
    final released = await failing.release(original);
    expect(released.originalHtml, isEmpty);
    expect(
      (await failing.restore(released)).originalHtml,
      original.originalHtml,
    );
  });

  test('dispose drains writes before closing the spool', () async {
    final original = chapter('drain');
    final pending = spool.release(original);
    await spool.dispose();
    expect((await pending).originalHtml, isEmpty);
    expect(await directory.list().where((e) => e is File).length, 1);
    await expectLater(spool.release(original), throwsStateError);
  });

  test(
    'parallel chapters share a recoverable run-owned temporary directory',
    () async {
      final owned = ChapterSourceSpool();
      try {
        final released = await Future.wait([
          owned.release(chapter('alpha', path: 'a.xhtml')),
          owned.release(chapter('beta', path: 'b.xhtml')),
        ]);
        final restored = await Future.wait(released.map(owned.restore));
        expect(restored.map((c) => c.body), ['preview alpha', 'preview beta']);
      } finally {
        await owned.dispose();
      }
    },
  );
}
