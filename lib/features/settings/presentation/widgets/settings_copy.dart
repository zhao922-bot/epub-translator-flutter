import '../../../../shared/localization/app_strings.dart';

extension SettingsCopy on AppStrings {
  String get settingsConflictSnackBar => isChinese
      ? '设置已被其他实例修改，请重新加载后再编辑。'
      : 'Settings changed in another instance; reload before editing.';

  String get endpointTemplates => isChinese ? '接口模板' : 'Endpoint templates';

  String get confirmEndpointChange =>
      isChinese ? '将已保存的密钥用于新接口？' : 'Use the saved key with this endpoint?';

  String savedKeyEndpointChange(String endpoint) => isChinese
      ? '连接测试和翻译请求会将当前自定义 API 密钥发送到 $endpoint。'
      : 'Connection tests and translation requests will send your current Custom API key to $endpoint.';

  String get useEndpoint => isChinese ? '使用此接口' : 'Use endpoint';

  String get ollamaKeyHint => isChinese
      ? '本地 Ollama 可在密钥栏填写 ollama。'
      : 'Enter ollama as the API key for a local Ollama server.';

  String get streamingApi => isChinese ? '流式 API 响应' : 'Stream API responses';

  String get streamingApiBody => isChinese
      ? '使用支持流式响应的接口逐步接收译文。'
      : 'Receive translations incrementally from compatible endpoints.';

  String editExactValue(String setting) =>
      isChinese ? '输入精确值（$setting）' : 'Enter an exact value ($setting)';

  String numericRange(int min, int max) => '$min–$max';
}
