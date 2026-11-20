import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/security/sensitive_text.dart';
import '../../translation/domain/models/translation_config.dart';
import '../../translation/domain/repositories/translation_repository.dart';
import '../../translation/infrastructure/epub/translation_api_client.dart';
import 'connection_diagnostic.dart';

class ConnectionTestController extends StateNotifier<AsyncValue<String?>> {
  ConnectionTestController(this._repository)
    : super(const AsyncData<String?>(null));

  final TranslationRepository _repository;
  int _revision = 0;
  CancelToken? _probeCancelToken;

  Future<void> run(TranslationConfig config) async {
    if (!mounted) {
      return;
    }
    final revision = ++_revision;
    _probeCancelToken?.cancel();
    final token = _probeCancelToken = CancelToken();
    state = const AsyncLoading<String?>();
    try {
      final String result = await TranslationApiClient.runWithProbeCancelToken(
        token,
        () => _repository.testConnection(config: config),
      );
      if (!mounted || revision != _revision) {
        return;
      }
      // P1-#5: a successful probe response can echo the request, including
      // the current API key — redact it like the error path does, so the
      // displayed result can never leak the key via screenshot or copy.
      state = AsyncData<String?>(
        SensitiveText.redact(result, configuredApiKey: config.apiKey),
      );
    } catch (error, stackTrace) {
      if (!mounted || revision != _revision) {
        return;
      }
      final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
        error,
        config: config,
      );
      state = AsyncError<String?>(diagnostic.message, stackTrace);
    } finally {
      if (identical(_probeCancelToken, token)) _probeCancelToken = null;
    }
  }

  void clear() {
    if (!mounted) {
      return;
    }
    _revision++;
    _probeCancelToken?.cancel();
    _probeCancelToken = null;
    state = const AsyncData<String?>(null);
  }

  @override
  void dispose() {
    _revision++;
    _probeCancelToken?.cancel();
    _probeCancelToken = null;
    super.dispose();
  }
}
