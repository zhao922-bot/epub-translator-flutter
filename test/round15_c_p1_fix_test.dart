import 'package:epub_translator_flutter/features/settings/application/connection_diagnostic.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/shared/security/sensitive_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReplayStore extends SettingsStore {
  TranslationConfig persisted = TranslationConfig.defaults().copyWith(
    uiLanguage: UiLanguage.english,
  );
  Object? saveError;
  final attempts = <TranslationConfig>[];

  @override
  Future<TranslationConfig> load() async => persisted;

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attempts.add(config);
    if (saveError case final error?) throw error;
    persisted = config;
  }
}

class _History extends JobHistoryStore {
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: <TranslationJob>[], clearedAt: 0);
}

void main() {
  test('C-P1-3 query names match exactly and preserve adjacent parameters', () {
    for (final name in [
      'key',
      'api_key',
      'apikey',
      'token',
      'access_token',
      'access-token',
      'auth_token',
      'secret',
      'client_secret',
      'password',
      'passwd',
      'pwd',
    ]) {
      for (final prefix in ['?', '&']) {
        expect(
          SensitiveText.redact(
            'https://api.example/$prefix$name=SECRET&model=x#y',
          ),
          'https://api.example/$prefix$name=***&model=x#y',
          reason: '$prefix$name',
        );
      }
    }
    expect(
      SensitiveText.redact('?monkey=banana&tokenizer=visible&KEY=SECRET'),
      '?monkey=banana&tokenizer=visible&KEY=***',
    );
    // Keep the existing non-query api_key behaviour.
    expect(SensitiveText.redact('api_key=SECRET'), 'api_key=[redacted]');
  });

  test('C-P1-3 query values stop at each required delimiter', () {
    for (final delimiter in ['&', '#', ' ', '\t', '\n', '"', "'", '<', '>']) {
      expect(
        SensitiveText.redact('?api_key=SECRET${delimiter}visible'),
        '?api_key=***${delimiter}visible',
      );
    }
  });

  test('C-P1-3 proxy authorization removes the entire scheme value', () {
    for (final header in ['Proxy-Authorization', 'proxy-authorization']) {
      for (final scheme in ['Basic', 'Bearer', 'Digest']) {
        expect(
          SensitiveText.redact(
            '$header: $scheme SECRET extra=value\nHost: proxy.example',
          ),
          '$header: $scheme [redacted]\nHost: proxy.example',
        );
      }
    }
  });

  test(
    'C-P1-3 schemeless userinfo is redacted without harming ordinary text',
    () {
      for (final address in [
        'proxy.example:8080/x',
        '127.0.0.1:8080',
        'host:8080',
        'host/x',
        '[::1]:8080',
      ]) {
        expect(
          SensitiveText.redact('proxy user:pa:ss@word@$address'),
          'proxy [redacted]@$address',
        );
      }
      expect(
        SensitiveText.redact('user:SECRET@proxy.example'),
        '[redacted]@proxy.example',
      );
      const ordinary = 'email user@proxy.example; appointment 12:30@night';
      expect(SensitiveText.redact(ordinary), ordinary);
      for (final scheme in ['http', 'HTTPS']) {
        final url = '$scheme://user:SECRET@proxy.example:80/x';
        final expected = '$scheme://[redacted]@proxy.example:80/x';
        expect(SensitiveText.redact(url), expected);
        expect(SensitiveText.redact(expected), expected);
      }
    },
  );

  test(
    'C-P1-3 ConnectionDiagnostic redacts all three error shapes end to end',
    () {
      final config = TranslationConfig.defaults().copyWith(
        apiKey: 'different-configured-key',
        uiLanguage: UiLanguage.english,
      );
      for (final error in [
        'transport failed https://api.example/?key=SECRET&model=x',
        'proxy-authorization: Basic SECRET extra=SECRET',
        'proxy user:SECRET@proxy.example:8080',
      ]) {
        final message = ConnectionDiagnostic.fromError(
          StateError(error),
          config: config,
        ).message;
        expect(message, isNot(contains('SECRET')));
        expect(
          message,
          contains(error.contains('?key=') ? '?key=***&model=x' : '[redacted]'),
        );
      }
    },
  );

  test(
    'C-P1-4 discard restores memory credentials and retains unrelated queued edits',
    () async {
      final store = _ReplayStore();
      store.persisted = store.persisted.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: 'https://original.example/v1',
        customApiBaseUrl: 'https://original.example/v1',
        deepseekApiKey: 'loaded-deepseek-key',
      );
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;
      store.saveError = SettingsWriteConflict();
      expect(await controller.setApiKey('FAILED-KEY'), isFalse);
      expect(await controller.setOutputSuffix('_retained'), isFalse);
      store.persisted = store.persisted.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: 'https://other.example/v1',
        customApiBaseUrl: 'https://other.example/v1',
        apiKey: 'loaded-custom-key',
        customApiKey: 'loaded-custom-key',
        deepseekApiKey: 'loaded-deepseek-key',
      );
      store.saveError = StateError('disk unavailable');
      await controller.reloadSettings();
      expect(controller.blockedReplayCount, 1);
      // A failed ordinary retry also leaves optimistic key material in memory.
      expect(await controller.setApiKey('FAILED-KEY'), isFalse);
      expect(controller.state.apiKey, 'FAILED-KEY');
      controller.discardBlockedConflictReplays();
      expect(controller.blockedReplayCount, 0);
      expect(controller.state.apiKey, 'loaded-custom-key');
      expect(controller.state.customApiKey, 'loaded-custom-key');
      expect(controller.state.deepseekApiKey, 'loaded-deepseek-key');
      expect(controller.state.outputSuffix, '_retained');
      store.saveError = null;
      await controller.setBilingual(true);
      expect(store.persisted.apiKey, 'loaded-custom-key');
      expect(store.persisted.customApiKey, 'loaded-custom-key');
      await controller.reloadSettings();
      expect(store.persisted.outputSuffix, '_retained');
      expect(store.persisted.apiKey, 'loaded-custom-key');
      expect(store.persisted.deepseekApiKey, 'loaded-deepseek-key');
      final count = store.attempts.length;
      await controller.reloadSettings();
      expect(store.attempts, hasLength(count));
    },
  );

  testWidgets(
    'C-P1-4 Discard resets dirty API input, cancels retries and prevents full-save leakage',
    (tester) async {
      final store = _ReplayStore();
      store.persisted = store.persisted.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: 'https://original.example/v1',
        customApiBaseUrl: 'https://original.example/v1',
        apiKey: 'loaded-key',
        customApiKey: 'loaded-key',
      );
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          jobHistoryStoreProvider.overrideWithValue(_History()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pumpAndSettle();
      final controller = container.read(settingsProvider.notifier);
      final keyField = find.byKey(const ValueKey<String>('settings-api-key'));
      store.saveError = SettingsWriteConflict();
      await tester.enterText(keyField, 'FAILED-KEY');
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(controller.state.apiKey, 'FAILED-KEY');
      store.persisted = store.persisted.copyWith(
        apiBaseUrl: 'https://changed.example/v1',
        customApiBaseUrl: 'https://changed.example/v1',
      );
      store.saveError = null;
      await controller.reloadSettings();
      await tester.pumpAndSettle();
      expect(controller.blockedReplayCount, 1);
      final editable = find.descendant(
        of: keyField,
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(editable).controller.text,
        'FAILED-KEY',
      );
      // Put the same failed credential in memory again; a discarded dirty
      // field must not retry it on blur, timer, test-connection or disposal.
      store.saveError = StateError('disk unavailable');
      expect(await controller.setApiKey('FAILED-KEY'), isFalse);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Discard'));
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(controller.state.apiKey, 'loaded-key');
      expect(controller.state.customApiKey, 'loaded-key');
      expect(
        tester.widget<EditableText>(editable).controller.text,
        'loaded-key',
      );
      expect(controller.blockedReplayCount, 0);
      store.saveError = null;
      final count = store.attempts.length;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(store.attempts, hasLength(count));
      await controller.setBilingual(true);
      expect(store.persisted.apiKey, 'loaded-key');
      expect(store.persisted.customApiKey, 'loaded-key');
      expect(store.persisted.bilingual, isTrue);
    },
  );
}
