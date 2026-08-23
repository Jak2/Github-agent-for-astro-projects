import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'llm_engine.dart';

/// On-device engine backed by llama_cpp_dart's isolate-based LlamaParent.
/// The package already runs inference in a child isolate, so this class
/// just drives its prompt/stream API.
class OnDeviceLlamaEngine implements LlmEngine {
  final String modelPath;
  LlamaParent? _parent;

  OnDeviceLlamaEngine({required this.modelPath});

  bool get isLoaded => _parent != null;

  Future<LlamaParent> _ensureLoaded() async {
    if (_parent != null) return _parent!;
    final parent = LlamaParent(
      LlamaLoad(
        path: modelPath,
        // nGpuLayers defaults to 99 (offload almost everything to GPU), but
        // this app's llama.cpp is built from source without a mobile GPU
        // backend (no Vulkan/CUDA compute path linked in) — leaving the
        // default causes a native SIGSEGV inside the model-load isolate the
        // first time it tries to hand a layer to a GPU backend that isn't
        // there. Force CPU-only inference.
        modelParams: ModelParams()..nGpuLayers = 0,
        contextParams: ContextParams(),
        samplingParams: SamplerParams(),
      ),
    );
    await parent.init();
    _parent = parent;
    return parent;
  }

  /// Explicitly loads the model without generating anything, so the UI can
  /// show a "Load" action independent of sending a prompt.
  Future<void> load() => _ensureLoaded();

  /// Frees the loaded model's isolate/memory. Safe to call when not loaded.
  Future<void> unload() async {
    final parent = _parent;
    _parent = null;
    await parent?.dispose();
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
