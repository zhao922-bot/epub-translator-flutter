/// Quick-fill values for the app's single custom API profile.
enum CustomEndpointTemplate {
  openAi('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  siliconFlow(
    'SiliconFlow',
    'https://api.siliconflow.cn/v1',
    'Qwen/Qwen2.5-7B-Instruct',
  ),
  openRouter(
    'OpenRouter',
    'https://openrouter.ai/api/v1',
    'openai/gpt-4o-mini',
  ),
  ollama('Ollama', 'http://localhost:11434/v1', 'qwen3:8b');

  const CustomEndpointTemplate(this.label, this.baseUrl, this.model);

  final String label;
  final String baseUrl;
  final String model;

  bool changesOrigin(String currentBaseUrl) {
    final current = Uri.tryParse(currentBaseUrl.trim());
    final target = Uri.parse(baseUrl);
    return current == null ||
        current.scheme != target.scheme ||
        current.host != target.host ||
        current.port != target.port;
  }
}
