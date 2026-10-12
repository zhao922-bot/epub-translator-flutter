import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as parser;

import '../test/support/legacy_html_extractor.dart';

// Run: flutter test --no-pub tool/benchmark_html_wrapping.dart
// DOM construction/parsing is excluded. Timings include normalization and
// element selection for both implementations; medians avoid timing assertions.
void main() {
  test('mixed HTML wrapping benchmark', runBenchmark);
}

void runBenchmark() {
  const current = EpubHtmlExtractor();
  const legacy = LegacyHtmlExtractor();
  for (var i = 0; i < 5; i++) {
    for (final extractor in [legacy, current]) {
      extractor.extractTranslatableElements(
        parser.parse(
          '<body>${List.generate(200, (i) => 'bare $i<p>block $i</p>').join()}</body>',
        ),
      );
    }
  }
  stdout.writeln('pairs,legacy_ms,current_ms,speedup');
  for (final count in [1000, 4000, 16000]) {
    final source =
        '<body>${List.generate(count, (i) => 'bare $i<p>block $i</p>').join()}</body>';
    final timings = <EpubHtmlExtractor, List<int>>{legacy: [], current: []};
    for (var sample = 0; sample < 7; sample++) {
      // Alternate order to reduce JIT/GC ordering bias.
      for (final extractor
          in sample.isEven ? [legacy, current] : [current, legacy]) {
        final document = parser.parse(source);
        final watch = Stopwatch()..start();
        final elements = extractor.extractTranslatableElements(document);
        watch.stop();
        if (elements.length != count * 2) throw StateError('Unexpected output');
        timings[extractor]!.add(watch.elapsedMicroseconds);
      }
    }
    for (final samples in timings.values) {
      samples.sort();
    }
    final oldTime = timings[legacy]![3] / 1000;
    final newTime = timings[current]![3] / 1000;
    stdout.writeln(
      '$count,${oldTime.toStringAsFixed(3)},${newTime.toStringAsFixed(3)},${(oldTime / newTime).toStringAsFixed(2)}x',
    );
  }
}
