import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'llm_engine.dart';

/// On-device engine backed by llama_cpp_dart's isolate-based LlamaParent.
/// The package already runs inference in a child isolate, so this class
/// just drives its prompt/stream API.
class OnDeviceLlamaEngine implements LlmEngine {
  final String modelPath;
  LlamaParent? _parent;

  OnDeviceLlamaEngine({required this.modelPath});

  Future<LlamaParent> _ensureLoaded() async {
    if (_parent != null) return _parent!;
    final parent = LlamaParent(
      LlamaLoad(
        path: modelPath,
        modelParams: ModelParams(),
        contextParams: ContextParams(),
        samplingParams: SamplerParams(),
      ),
    );
    await parent.init();
    _parent = parent;
    return parent;
  }

  @override
  Future<String> generate(String prompt) async {
    final parent = await _ensureLoaded();
    final buffer = StringBuffer();
    final sub = parent.stream.listen(buffer.write);
    try {
      final promptId = await parent.sendPrompt(prompt);
      await parent.completions
          .firstWhere((event) => event.promptId == promptId)
          .timeout(const Duration(seconds: 120));
    } finally {
      await sub.cancel();
    }
    return buffer.toString();
  }
}
