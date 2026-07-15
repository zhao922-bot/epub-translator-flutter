import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release Android manifest does not allow all cleartext traffic', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, isNot(contains('android:usesCleartextTraffic="true"')));
  });

  test('MainActivity handles legacy Downloads write permission', () {
    final String activity = File(
      'android/app/src/main/kotlin/com/yang/epubtranslator/MainActivity.kt',
    ).readAsStringSync();

    expect(activity, contains('requestPermissions'));
    expect(activity, contains('WRITE_EXTERNAL_STORAGE'));
  });
}
