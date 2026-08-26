/// Parsing of file-creation proposals out of an LLM reply.
///
/// The model cannot write anything itself. It asks, in a fenced block the app
/// parses deterministically:
///
/// ```
/// ```create-file path=cat/dog_food.md
/// # Dog food
/// ...
/// ```
/// ```
///
/// A fenced block is used rather than the model's own tool-calling API because
/// this app must also work with 0.5-1.5B on-device models, which cannot emit
/// reliable structured tool calls. Text in a fence they can manage.
library;

/// A file the model has asked to create, already validated as a safe path.
class FileProposal {
  /// Repo-relative path. Guaranteed by [parseFileProposals] to be relative,
  /// normalised, and free of `..` segments.
  final String path;
  final String content;

  const FileProposal({required this.path, required this.content});

  @override
  bool operator ==(Object other) =>
      other is FileProposal && other.path == path && other.content == content;

  @override
  int get hashCode => Object.hash(path, content);
}

/// A block that looked like a proposal but was rejected, with the reason.
/// Surfaced to the user — a silently dropped write request would leave them
/// waiting for a file that is never coming.
class RejectedProposal {
  final String rawPath;
  final String reason;
  const RejectedProposal(this.rawPath, this.reason);
}

class ProposalParseResult {
  final List<FileProposal> proposals;
  final List<RejectedProposal> rejected;
  const ProposalParseResult(this.proposals, this.rejected);

  bool get isEmpty => proposals.isEmpty && rejected.isEmpty;
}

final _fenceStart = RegExp(r'^\s*```create-file\s+path=(.+?)\s*$');
final _fenceEnd = RegExp(r'^\s*```\s*$');

/// Extracts every `create-file` block from [reply].
///
/// Unterminated blocks are kept: a reply cut short by the token limit would
/// otherwise silently lose the file the user asked for. The content is
/// whatever arrived.
ProposalParseResult parseFileProposals(String reply) {
  final proposals = <FileProposal>[];
  final rejected = <RejectedProposal>[];
  final lines = reply.split('\n');

  var i = 0;
  while (i < lines.length) {
    final match = _fenceStart.firstMatch(lines[i]);
    if (match == null) {
      i++;
      continue;
    }

    final rawPath = match.group(1)!.trim().replaceAll('"', '').replaceAll("'", '');
    final body = <String>[];
    i++;
    while (i < lines.length && !_fenceEnd.hasMatch(lines[i])) {
      body.add(lines[i]);
      i++;
    }
    i++; // step past the closing fence, if there was one

    final problem = filePathRejection(rawPath);
    if (problem != null) {
      rejected.add(RejectedProposal(rawPath, problem));
    } else {
      proposals.add(FileProposal(path: normaliseFilePath(rawPath), content: body.join('\n')));
    }
  }

  return ProposalParseResult(proposals, rejected);
}

/// Why [path] must not be written, or null when it is safe.
///
/// The model's output is untrusted input: it is free to emit `../../etc/passwd`
/// or an absolute path, and this runs against the user's real repository. So is
/// a path the user has typed into the confirmation card — the same rules decide
/// both, from here, so an edited path cannot take a softer route to disk.
/// [asFolder] relaxes exactly one rule — a trailing slash is a folder, which is
/// the point when the "New folder" action is what is asking. Everything else
/// (absolute, `..`, `.git`, backslashes) is identical, deliberately: one set of
/// rules decides every path this app writes to.
String? filePathRejection(String path, {bool asFolder = false}) {
  if (path.isEmpty) return 'no path given';
  if (path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) {
    return 'absolute paths are not allowed';
  }
  if (path.contains('\\')) return 'use forward slashes';
  final segments = path.split('/');
  if (segments.contains('..')) return 'paths may not escape the repository';
  if (segments.contains('.git')) return 'writing inside .git is not allowed';
  if (!asFolder && path.trimRight().endsWith('/')) return 'that is a folder, not a file';
  if (asFolder && normaliseFilePath(path).isEmpty) return 'no folder name given';
  return null;
}

/// Drops empty and `.` segments. Only ever applied to a path
/// [filePathRejection] has already cleared.
String normaliseFilePath(String path) =>
    path.split('/').where((s) => s.isNotEmpty && s != '.').join('/');

/// The phrasings a small model uses when it *claims* to have created a file.
///
/// Only ever consulted when [parseFileProposals] found nothing at all, so a
/// false positive costs one clarifying line while a false negative leaves the
/// user believing in a file that does not exist. Erring loud is the cheap side.
final _creationClaim = RegExp(
  r"(has|have|had) been (created|written|added|saved)"
  r"|\bfile (is |was )?(created|written|added|saved)"
  r"|successfully (created|written|added|saved)"
  r"|\bi(?:'ve| have)?\s+(?:just\s+|now\s+)?(?:created|written|added|saved)\b",
  caseSensitive: false,
);

/// True when [reply] reads as "I created that file" — a claim only the
/// create-file block can actually make true.
bool claimsFileCreation(String reply) => _creationClaim.hasMatch(reply);
