import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'repair_epub_xhtml_command.dart' as repair;
import 'rebuild_translated_epub_command.dart' as rebuild;

void main() {
  test('local EPUB maintenance', () async {
    final request =
        jsonDecode(Platform.environment['FOLIOFERRY_MAINTENANCE_REQUEST']!)
            as Map;
    final arguments = (request['arguments'] as List).cast<String>();
    if (request['operation'] == 'repair') {
      await repair.repair(arguments);
    } else if (request['operation'] == 'rebuild') {
      await rebuild.rebuild(arguments);
    } else {
      throw const FormatException('Unknown maintenance operation.');
    }
  });
}
