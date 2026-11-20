import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/translation_config.dart';

extension SettingsCopy on AppStrings {
  String get modelReasoningEffort =>
      isChinese ? '模型推理强度' : 'Model reasoning effort';

  String reasoningEffortLabel(ModelReasoningEffort effort) => switch (effort) {
    ModelReasoningEffort.automatic =>
      isChinese ? '自动（按模型适配）' : 'Automatic (model-aware)',
    ModelReasoningEffort.providerDefault =>
      isChinese ? '服务商默认' : 'Provider default',
    ModelReasoningEffort.none => isChinese ? '无（none）' : 'None',
    ModelReasoningEffort.minimal => isChinese ? '极低（minimal）' : 'Minimal',
    ModelReasoningEffort.low => isChinese ? '较低（low）' : 'Low',
    ModelReasoningEffort.medium => isChinese ? '中等（medium）' : 'Medium',
    ModelReasoningEffort.high => isChinese ? '较高（high）' : 'High',
    ModelReasoningEffort.xhigh =>
      isChinese ? '极高（xhigh）' : 'Extra high (xhigh)',
    ModelReasoningEffort.max => isChinese ? '最高（max）' : 'Maximum (max)',
    ModelReasoningEffort.custom =>
      isChinese ? '自定义推理参数' : 'Custom reasoning parameter',
  };

  String savedReasoningChoice(ModelReasoningEffort effort) => isChinese
      ? '已保存（当前接口未验证）：${reasoningEffortLabel(effort)}'
      : '${reasoningEffortLabel(effort)} (saved, unverified for this endpoint)';

  String get automaticReasoningBody => isChinese
      ? '节省 Token 模式对普通正文使用当前接口已验证的低推理设置。'
      : 'Token-saving mode uses verified low-reasoning settings for ordinary text.';

  String get providerDefaultReasoningBody => isChinese
      ? '请求省略推理强度、思考开关和思考预算参数。'
      : 'Requests omit reasoning effort, thinking mode, and thinking budget.';

  String get thinkingMode => isChinese ? '思考模式' : 'Thinking mode';

  String thinkingModeLabel(ModelThinkingMode mode) => switch (mode) {
    ModelThinkingMode.automatic => isChinese ? '自动' : 'Automatic',
    ModelThinkingMode.enabled => isChinese ? '开启' : 'Enabled',
    ModelThinkingMode.disabled => isChinese ? '关闭' : 'Disabled',
  };

  String get configureCustomReasoning =>
      isChinese ? '设置自定义推理参数' : 'Configure custom reasoning';

  String customReasoningBody(String model) => isChinese
      ? '选择当前接口为 $model 声明支持的参数和值。设置仅用于此接口和模型。'
      : 'Choose a parameter and value documented for $model. This setting applies to the current endpoint and model.';

  String get reasoningParameter => isChinese ? '请求参数' : 'Request parameter';
  String get reasoningValue => isChinese ? '参数值' : 'Parameter value';
  String get reasoningBudget =>
      isChinese ? '思考预算（Token）' : 'Thinking budget (tokens)';
  String get applyCustomReasoning => isChinese ? '应用参数' : 'Apply parameter';
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

  String get tokenSavingMode => isChinese ? '节省 Token 模式' : 'Token-saving mode';

  String get tokenSavingModeBody => isChinese
      ? '缩减请求中的上下文，合并合适的请求，并在有需要时局部修复。保留你设置的本地质量检查。'
      : 'Send less context, group suitable requests, and repair only the parts that need it. Keeps your local quality checks.';

  String get streamingApi => isChinese ? '流式 API 响应' : 'Stream API responses';

  String get streamingApiBody => isChinese
      ? '使用支持流式响应的接口逐步接收译文。'
      : 'Receive translations incrementally from compatible endpoints.';

  String editExactValue(String setting) =>
      isChinese ? '输入精确值（$setting）' : 'Enter an exact value ($setting)';

  String numericRange(int min, int max) => '$min–$max';
}
