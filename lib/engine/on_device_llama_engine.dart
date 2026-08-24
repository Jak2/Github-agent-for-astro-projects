import 'dart:async';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'generation_event.dart';
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
  Future<String> generate(String prompt) => bufferStream(generateStream(prompt));

  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    if (_parent == null) {
      yield const GenerationStatus('loading model…');
    }
    final LlamaParent parent;
    try {
      parent = await _ensureLoaded();
    } catch (e) {
      yield GenerationError('Model failed to load: $e');
      return;
    }
    yield const GenerationStatus('model ready');

    final buffer = StringBuffer();
    final tokens = StreamController<String>();
    final sub = parent.stream.listen(tokens.add, onError: tokens.addError);

    // Subscribe to completions BEFORE sending the prompt. Subscribing after
    // `sendPrompt` returns leaves a window where the completion event can fire
    // unobserved on this broadcast stream, which strands the caller until a
    // timeout — one of the suspected causes of the silent-generation bug.
    final completion = parent.completions.first;

    try {
      yield const GenerationStatus('prompt sent');
      await parent.sendPrompt(prompt);

      var count = 0;
      final done = completion.whenComplete(tokens.close);

      await for (final token in tokens.stream) {
        buffer.write(token);
        count++;
        yield GenerationToken(token);
        if (count % 8 == 0) {
          yield GenerationStatus('generating ($count tokens)');
        }
      }

      final event = await done;
      if (!event.success) {
        yield GenerationError(event.errorDetails ?? 'Generation failed');
        return;
      }
      yield GenerationDone(buffer.toString());
    } catch (e) {
      yield GenerationError('$e');
    } finally {
      await sub.cancel();
      if (!tokens.isClosed) await tokens.close();
    }
  }
}
