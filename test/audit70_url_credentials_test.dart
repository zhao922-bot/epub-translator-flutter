import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';

class _EmptySecrets implements SettingsSecretStore {
  @override
  Future<String?> readApiKey() async => null;
  @override
  Future<String?> readDeepSeekApiKey() async => null;
  @override
  Future<String?> readCustomApiKey() async => null;
  @override
  Future<String?> readProxyAuthentication() async => null;
  @override
  Future<void> writeApiKey(String value) async {}
  @override
  Future<void> writeDeepSeekApiKey(String value) async {}
  @override
  Future<void> writeCustomApiKey(String value) async {}
  @override
  Future<void> writeProxyAuthentication(String value) async {}
  @override
  Future<void> deleteApiKey() async {}
  @override
  Future<void> deleteDeepSeekApiKey() async {}
  @override
  Future<void> deleteCustomApiKey() async {}
  @override
  Future<void> deleteProxyAuthentication() async {}
}

void main() {
  final cases = <String, String>{
    'valid URI with userinfo control':
        'https://audit-user:audit-password@example.invalid/v1',
    'malformed port with userinfo':
        'https://audit-user:audit-password@example.invalid:notaport/v1',
    'malformed port with query credential':
        'https://example.invalid:notaport/v1?api_key=audit-password',
  };
  for (final entry in cases.entries) {
    test('settings rejects credential-bearing ${entry.key}', () async {
      final temp = await Directory.systemTemp.createTemp('audit-r11-url-');
      final file = File('${temp.path}/settings.json');
      final controller = SettingsController(
        SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: _EmptySecrets(),
        ),
      );
      await controller.ready;
      final saved = await controller.setApiBaseUrl(entry.value);
      final json = await file.exists() ? await file.readAsString() : '';
      controller.dispose();
      await temp.delete(recursive: true);
      debugPrint(
        'AUDIT ${entry.key}: parseable=${Uri.tryParse(entry.value) != null}, saved=$saved, plaintextCredential=${json.contains('audit-password')}',
      );
      expect(
        json,
        isNot(contains('audit-password')),
        reason:
            'An invalid port must not disable the URL credential persistence guard',
      );
      expect(saved, isFalse);
    });
  }
}
