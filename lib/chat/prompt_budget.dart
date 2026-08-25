/// Keeps a chat prompt inside the model's context window.
///
/// Two parts of the prompt grow without bound: a repository's file tree, and
/// the conversation transcript. On-device models have a small window — a real
/// repo tree measured 2325 tokens against a 512-token batch — so an
/// unbudgeted prompt fails outright with "Prompt token count exceeds batch
/// capacity" instead of answering.
///
/// Truncation is always announced in the prompt text itself, so the model is
/// told its view is partial rather than being silently handed less than it
/// asked for.
library;

/// Assembles a prompt that fits within [maxChars].
///
/// Budget priority, most protected first:
/// 1. [header] and the trailing turn cue — always kept whole; they carry the
///    instructions, so dropping them changes the task.
/// 2. The newest [transcript] entries — the user's actual question lives here.
/// 3. [fileSection] — a file the user explicitly opened.
/// 4. [treeText] — the largest and most compressible part.
///
/// [transcript] runs oldest to newest and is trimmed from the front.
String buildBudgetedPrompt({
  required String header,
  required String treeText,
  required String fileSection,
  required List<String> transcript,
  required String turnCue,
  required int maxChars,
}) {
  const conversationLabel = 'Conversation so far:\n';

  final fixed = header.length + conversationLabel.length + turnCue.length;

  // Reserve up to half the remaining budget for conversation, taking the
  // newest entries first. A question the model never sees cannot be answered,
  // so recency wins over completeness.
  final conversationBudget = ((maxChars - fixed) * 0.5).floor();
  final keptTurns = <String>[];
  var used = 0;
  for (final line in transcript.reversed) {
    final cost = line.length + 1;
    if (used + cost > conversationBudget) break;
    keptTurns.insert(0, line);
    used += cost;
  }
  final droppedTurns = transcript.length - keptTurns.length;

  var remaining = maxChars - fixed - used;

  const fileNotice = '\n[file truncated to fit the context window]\n';
  const treeNotice = '\n[tree truncated to fit the context window — ask about '
      'a specific folder to see more]\n';

  // The opened file is more specific than the tree, so it is trimmed second.
  // The notice counts against the budget too, or the result overflows by
  // exactly the length of the text explaining that it was shortened.
  var file = fileSection;
  if (file.isNotEmpty) {
    final fileBudget = (remaining * 0.5).floor();
    if (file.length > fileBudget) {
      final room = fileBudget - fileNotice.length;
      file = room <= 0
          ? fileNotice
          : file.substring(0, _safeCut(file, room)) + fileNotice;
    }
    remaining -= file.length;
  }

  var tree = treeText;
  if (tree.length > remaining) {
    final room = remaining - treeNotice.length;
    tree = room <= 0 ? '' : tree.substring(0, _safeCut(tree, room)) + treeNotice;
  }

  final buffer = StringBuffer()..write(header);
  if (tree.isNotEmpty) buffer.write(tree);
  if (file.isNotEmpty) buffer.write(file);
  buffer.write(conversationLabel);
  if (droppedTurns > 0) {
    buffer.writeln('[$droppedTurns earlier message(s) omitted to fit]');
  }
  for (final line in keptTurns) {
    buffer.writeln(line);
  }
  buffer.write(turnCue);
  return buffer.toString();
}

/// Cuts at the last newline before [limit] so the text never ends mid-path,
/// falling back to a hard cut when there is no newline to use.
int _safeCut(String text, int limit) {
  if (limit >= text.length) return text.length;
  if (limit <= 0) return 0;
  final nl = text.lastIndexOf('\n', limit);
  return nl > limit ~/ 2 ? nl : limit;
}
