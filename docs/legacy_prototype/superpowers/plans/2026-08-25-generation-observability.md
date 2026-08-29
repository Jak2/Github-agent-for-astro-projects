# Generation Observability Implementation Plan (Phases 0 + 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LLM generation observable so a working-but-slow generation is
never mistaken for a hang, and fix the on-device query that produces no output.

**Architecture:** Add a streaming event API to `LlmEngine`. Both engines emit a
common `GenerationEvent` type (status / token / done / error). The chat screen
renders tokens incrementally with a live status line and a stop button. The
existing buffered `generate()` is reimplemented on top of the stream so there is
one code path, not two.

**Tech Stack:** Flutter/Dart, `dio` (cloud), `llama_cpp_dart` (on-device),
`flutter_test`.

## Global Constraints

- Dart SDK `^3.13.0`; Flutter 3.47.0.
- **No error may be silently swallowed.** Every catch either handles
  meaningfully or emits a visible `GenerationEvent.error`. This project has lost
  two multi-hour debugging sessions to masked errors.
- **No fabricated signals.** Status text and token counts come from real
  events only — never simulated, estimated, or animated placeholders.
- Business logic lives in testable non-UI units, matching the existing 15-file
  test suite under `test/`.
- Visual system: use `app_theme.dart` helpers. `appPrimaryButton` /
  `appSecondaryButton` are `width: double.infinity` — wrap in `Expanded` inside
  any `Row` or the frame throws.
- Existing callers of `LlmEngine.generate()` must keep working unchanged
  (`github_tab_screen.dart` structuring flow).
- Run tests with: `export PATH="$PATH:/home/asterisk/develop/flutter/bin"` first.
- Build on this machine with `bash android/gradlew assembleDebug` (NTFS mount
  blocks `flutter run`'s gradlew exec).

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/engine/generation_event.dart` (create) | The event type emitted by all engines |
| `lib/engine/llm_engine.dart` (modify) | Add `generateStream`; keep `generate` |
| `lib/engine/cloud_api_engine.dart` (modify) | Emit events for the HTTP path |
| `lib/engine/on_device_llama_engine.dart` (modify) | Emit events from `LlamaParent.stream`; fix the silent path |
| `lib/ui/general_chat_screen.dart` (modify) | Render tokens live, status line, stop button |
| `test/engine/generation_event_test.dart` (create) | Event type behaviour |
| `test/engine/llm_engine_stream_test.dart` (create) | Buffered-on-top-of-stream contract |

---

### Task 1: The `GenerationEvent` type

**Files:**
- Create: `lib/engine/generation_event.dart`
- Test: `test/engine/generation_event_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `sealed class GenerationEvent` with subclasses
  `GenerationStatus(String stage)`, `GenerationToken(String text)`,
  `GenerationDone(String fullText)`, `GenerationError(String message)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/engine/generation_event_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/engine/generation_event.dart';

void main() {
  test('events expose their payloads', () {
    expect(const GenerationStatus('loading model').stage, 'loading model');
    expect(const GenerationToken('hi').text, 'hi');
    expect(const GenerationDone('hello there').fullText, 'hello there');
    expect(const GenerationError('boom').message, 'boom');
  });

  test('events are exhaustively switchable', () {
    String describe(GenerationEvent e) => switch (e) {
          GenerationStatus() => 'status',
          GenerationToken() => 'token',
          GenerationDone() => 'done',
          GenerationError() => 'error',
        };
    expect(describe(const GenerationStatus('x')), 'status');
    expect(describe(const GenerationToken('x')), 'token');
    expect(describe(const GenerationDone('x')), 'done');
    expect(describe(const GenerationError('x')), 'error');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/engine/generation_event_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:git_agent_app/engine/generation_event.dart'`

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/engine/generation_event.dart

/// One observable step in an LLM generation. Engines emit these so the UI can
/// distinguish "thinking" from "stuck" — a distinction the old buffered
/// `Future<String>` API could not express.
sealed class GenerationEvent {
  const GenerationEvent();
}

/// A human-readable stage, e.g. "loading model", "prompt sent".
class GenerationStatus extends GenerationEvent {
  final String stage;
  const GenerationStatus(this.stage);
}

/// An incremental chunk of generated text.
class GenerationToken extends GenerationEvent {
  final String text;
  const GenerationToken(this.text);
}

/// Generation finished successfully. [fullText] is the complete output.
class GenerationDone extends GenerationEvent {
  final String fullText;
  const GenerationDone(this.fullText);
}

/// Generation failed. Always surfaced to the user — never swallowed.
class GenerationError extends GenerationEvent {
  final String message;
  const GenerationError(this.message);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/engine/generation_event_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/engine/generation_event.dart test/engine/generation_event_test.dart
git commit -m "feat: add GenerationEvent type for observable LLM generation"
```

---

### Task 2: Extend the `LlmEngine` interface

**Files:**
- Modify: `lib/engine/llm_engine.dart`
- Test: `test/engine/llm_engine_stream_test.dart`

**Interfaces:**
- Consumes: `GenerationEvent` from Task 1.
- Produces: `Stream<GenerationEvent> generateStream(String prompt)` on
  `LlmEngine`, plus a shared `bufferStream` helper that turns an event stream
  into a `Future<String>` so `generate()` has one implementation.

Read `lib/engine/llm_engine.dart` first to match its existing style.

- [ ] **Step 1: Write the failing test**

```dart
// test/engine/llm_engine_stream_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/engine/generation_event.dart';
import 'package:git_agent_app/engine/llm_engine.dart';

class _FakeEngine implements LlmEngine {
  final List<GenerationEvent> events;
  _FakeEngine(this.events);

  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    for (final e in events) {
      yield e;
    }
  }

  @override
  Future<String> generate(String prompt) => bufferStream(generateStream(prompt));
}

void main() {
  test('bufferStream concatenates tokens into the final string', () async {
    final engine = _FakeEngine(const [
      GenerationStatus('prompt sent'),
      GenerationToken('Hello '),
      GenerationToken('world'),
      GenerationDone('Hello world'),
    ]);
    expect(await engine.generate('hi'), 'Hello world');
  });

  test('bufferStream throws on an error event instead of returning empty', () async {
    final engine = _FakeEngine(const [
      GenerationStatus('prompt sent'),
      GenerationError('model exploded'),
    ]);
    expect(() => engine.generate('hi'), throwsA(isA<Exception>()));
  });

  test('bufferStream throws when the stream ends with no done event', () async {
    final engine = _FakeEngine(const [GenerationToken('partial')]);
    expect(() => engine.generate('hi'), throwsA(isA<Exception>()));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/engine/llm_engine_stream_test.dart`
Expected: FAIL — `generateStream` and `bufferStream` are not defined.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/engine/llm_engine.dart` (keep the existing `generate` declaration):

```dart
import 'generation_event.dart';

abstract class LlmEngine {
  /// Buffered generation, kept for non-interactive callers (the structuring
  /// flow). Implement it as `bufferStream(generateStream(prompt))` so there is
  /// a single code path.
  Future<String> generate(String prompt);

  /// Observable generation. Emits status, tokens, then exactly one
  /// [GenerationDone] — or one [GenerationError].
  Stream<GenerationEvent> generateStream(String prompt);
}

/// Collapses an event stream into the final text.
///
/// Throws on [GenerationError], and throws if the stream ends without a
/// [GenerationDone] — returning an empty string there would reproduce exactly
/// the "silent, no output, no error" failure this work exists to fix.
Future<String> bufferStream(Stream<GenerationEvent> events) async {
  final buffer = StringBuffer();
  var done = false;
  String? result;

  await for (final event in events) {
    switch (event) {
      case GenerationStatus():
        break;
      case GenerationToken(:final text):
        buffer.write(text);
      case GenerationDone(:final fullText):
        done = true;
        result = fullText.isEmpty ? buffer.toString() : fullText;
      case GenerationError(:final message):
        throw Exception(message);
    }
  }

  if (!done) {
    throw Exception('Generation ended without completing (no done event)');
  }
  return result ?? buffer.toString();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/engine/llm_engine_stream_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/engine/llm_engine.dart test/engine/llm_engine_stream_test.dart
git commit -m "feat: add generateStream to LlmEngine with buffered fallback"
```

---

### Task 3: On-device engine emits events (the actual bug fix)

**Files:**
- Modify: `lib/engine/on_device_llama_engine.dart`

**Interfaces:**
- Consumes: `GenerationEvent`, `bufferStream` from Tasks 1–2.
- Produces: `OnDeviceLlamaEngine.generateStream` emitting real load/prompt/token
  status; `generate` delegates to it.

The current `generate()` buffers everything and returns only at completion,
which is why a slow generation is indistinguishable from a hang. Read the file
first; keep `isLoaded`, `load()`, and `unload()` exactly as they are.

- [ ] **Step 1: Replace `generate` with a streaming implementation**

```dart
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
      final done = completion.then((event) => event).whenComplete(tokens.close);

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
```

- [ ] **Step 2: Add the required imports**

At the top of `lib/engine/on_device_llama_engine.dart`:

```dart
import 'dart:async';
import 'generation_event.dart';
```

(`llm_engine.dart` is already imported; `bufferStream` comes from it.)

- [ ] **Step 3: Verify it analyzes clean**

Run: `flutter analyze lib/engine/on_device_llama_engine.dart`
Expected: `No issues found!`

- [ ] **Step 4: Run the full existing suite for regressions**

Run: `flutter test`
Expected: all existing tests still pass. If `engine_factory_test.dart` fails
because a fake engine no longer satisfies `LlmEngine`, add a
`generateStream` override to that fake returning
`Stream.value(GenerationDone('...'))` — do not weaken the interface.

- [ ] **Step 5: Commit**

```bash
git add lib/engine/on_device_llama_engine.dart
git commit -m "fix: stream on-device generation events instead of returning only at completion"
```

---

### Task 4: Cloud engine emits events

**Files:**
- Modify: `lib/engine/cloud_api_engine.dart`
- Test: `test/engine/cloud_api_engine_test.dart` (existing — extend)

**Interfaces:**
- Consumes: `GenerationEvent`, `bufferStream`.
- Produces: `CloudApiEngine.generateStream`.

Read the existing file and its test first. This task does **not** add HTTP
streaming (SSE) — it wraps the existing single-response call in the event API so
the UI is uniform. Real token streaming for cloud is out of scope here.

- [ ] **Step 1: Add the streaming method**

```dart
  @override
  Future<String> generate(String prompt) => bufferStream(generateStream(prompt));

  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    yield const GenerationStatus('contacting API…');
    try {
      final text = await _requestCompletion(prompt);
      yield const GenerationStatus('response received');
      yield GenerationToken(text);
      yield GenerationDone(text);
    } catch (e) {
      yield GenerationError('$e');
    }
  }
```

Rename the existing body of `generate` to `Future<String> _requestCompletion(String prompt)`,
keeping its logic and error handling byte-for-byte otherwise.

- [ ] **Step 2: Run the existing cloud tests**

Run: `flutter test test/engine/cloud_api_engine_test.dart`
Expected: PASS — the existing tests call `generate()`, which now routes through
the stream. If any fail, the refactor changed behaviour; fix the refactor, not
the test.

- [ ] **Step 3: Add a streaming test**

```dart
  test('generateStream emits status, token, then done', () async {
    // Build the engine with the same mocked Dio the existing tests use.
    final engine = buildTestEngine(responseText: 'hello');
    final events = await engine.generateStream('hi').toList();
    expect(events.whereType<GenerationDone>().single.fullText, 'hello');
    expect(events.whereType<GenerationError>(), isEmpty);
  });
```

Adapt `buildTestEngine` to whatever helper the existing test file already uses
for mocking Dio — do not introduce a second mocking approach.

- [ ] **Step 4: Run it**

Run: `flutter test test/engine/cloud_api_engine_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engine/cloud_api_engine.dart test/engine/cloud_api_engine_test.dart
git commit -m "feat: emit generation events from the cloud engine"
```

---

### Task 5: Chat screen renders live tokens, status, and a stop button

**Files:**
- Modify: `lib/ui/general_chat_screen.dart`

**Interfaces:**
- Consumes: `generateStream` from Tasks 3–4.
- Produces: no new public API.

Current `_send()` awaits `engine.generate(...)` and appends one bubble at the
end. Replace that with incremental rendering. Read `_send()`, `_TextItem`, and
`_buildItem` first.

- [ ] **Step 1: Add streaming state fields**

Beside the existing `_busy` field in the State class:

```dart
  String _statusLine = '';
  StreamSubscription<GenerationEvent>? _genSub;
```

- [ ] **Step 2: Rewrite `_send` to consume the stream**

```dart
  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() => _items.add(_TextItem(text, fromUser: true)));

    final engine = await _resolveEngine();
    if (!mounted) return;
    if (engine == null) {
      setState(() => _items.add(const _TextItem(
            'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
            fromUser: false,
          )));
      return;
    }

    // One growing bubble the tokens stream into.
    final reply = _TextItem('', fromUser: false);
    setState(() {
      _busy = true;
      _statusLine = 'starting…';
      _items.add(reply);
    });

    final buffer = StringBuffer();
    _genSub = engine.generateStream(_buildPrompt()).listen(
      (event) {
        if (!mounted) return;
        setState(() {
          switch (event) {
            case GenerationStatus(:final stage):
              _statusLine = stage;
            case GenerationToken(:final text):
              buffer.write(text);
              reply.text = buffer.toString();
            case GenerationDone(:final fullText):
              reply.text = fullText.isEmpty ? buffer.toString() : fullText;
              _statusLine = '';
            case GenerationError(:final message):
              reply.text = 'Generation failed: $message';
              _statusLine = '';
          }
        });
        _scrollToBottom();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          reply.text = 'Generation failed: $e';
          _statusLine = '';
          _busy = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _statusLine = '';
          if (reply.text.isEmpty) {
            // Never leave a blank bubble — that is the original bug's symptom.
            reply.text = 'The model returned no output.';
          }
        });
      },
      cancelOnError: true,
    );
  }

  void _stopGeneration() {
    _genSub?.cancel();
    _genSub = null;
    if (mounted) setState(() { _busy = false; _statusLine = 'stopped'; });
  }
```

`_TextItem.text` must become mutable — change its `final String text` field to
`String text` and drop `const` at its construction sites.

- [ ] **Step 3: Add a `_scrollToBottom` helper**

If the screen has no `ScrollController` yet, add one, attach it to the messages
`ListView`, and dispose it. Then:

```dart
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }
```

- [ ] **Step 4: Show the status line and stop button while busy**

Above the input row, render only when `_busy`:

```dart
  if (_busy)
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _statusLine.isEmpty ? 'working…' : _statusLine,
              style: appMono(size: 11, color: AppColors.muted),
            ),
          ),
          const SizedBox(width: 8),
          appIconCircleButton(icon: Icons.stop, onPressed: _stopGeneration),
        ],
      ),
    ),
```

`appIconCircleButton` is fixed 40×40, so it is safe inside a `Row`. The
`Expanded` around the text is required.

- [ ] **Step 5: Cancel the subscription in `dispose`**

```dart
  @override
  void dispose() {
    _genSub?.cancel();
    _scrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }
```

- [ ] **Step 6: Verify**

Run: `flutter analyze` — expected `No issues found!`
Run: `flutter test` — expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/ui/general_chat_screen.dart
git commit -m "feat: render generation tokens live with status line and stop button"
```

---

### Task 6: On-device verification

**Files:** none (manual verification).

This is the task that proves the bug is actually fixed. It cannot be skipped —
the whole failure mode was believing something worked without watching it.

- [ ] **Step 1: Apply the pub-cache setup if this is a fresh machine**

```bash
bash scripts/setup_llama_cpp_dart.sh
```

- [ ] **Step 2: Build and install**

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
bash android/gradlew assembleDebug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

- [ ] **Step 3: Watch the log while querying**

```bash
adb logcat -c && adb logcat -v time flutter:* *:S
```

In the app: Config → load the on-device model → Chat → send a short prompt
such as "say hello".

- [ ] **Step 4: Confirm each expected behaviour**

Record the actual result for each:

1. The status line advances (`loading model…` → `model ready` → `prompt sent` →
   `generating (N tokens)`).
2. Text appears **incrementally**, not all at once at the end.
3. The stop button interrupts generation.
4. If nothing is produced, the bubble says so — never stays blank.

- [ ] **Step 5: Report findings honestly**

If generation still stalls, the status line now names the exact stage it
stalls at. Record that stage — it identifies the remaining root cause. Do not
claim the bug is fixed unless tokens were observed arriving incrementally.

---

## Self-Review

**Spec coverage:** Phase 0 (silent LLM) → Tasks 3, 5, 6. Phase 1 (step
visibility) → Tasks 1, 2, 5. Error-never-swallowed constraint → Task 2's
`bufferStream` throw-on-no-done, Task 5's blank-bubble guard. Stop button →
Task 5. Engine-sharing concern → resolved during design (`buildEngine` already
routes through `OnDeviceEngineRegistry`), no task needed.

**Deliberately out of scope:** real SSE token streaming for the cloud engine
(Task 4 wraps the single response); multi-step decomposition (separate plan).

**Type consistency:** `GenerationEvent` subclasses are named identically in
Tasks 1–5. `bufferStream` has one definition (Task 2) used by Tasks 3 and 4.
`_TextItem.text` is made mutable in Task 5 where it is first mutated.
