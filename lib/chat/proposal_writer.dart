/// What the app does with a [FileProposal] once the user has confirmed it.
///
/// Writes land in the local clone only — nothing here commits or pushes.
library;

import 'dart:io';

import 'file_proposal.dart';

/// Where [proposal] lands inside [repoDir].
///
/// Path safety is `parseFileProposals`' job — it has already rejected absolute
/// paths, `..`, and `.git`. This only joins.
File proposalFile(Directory repoDir, FileProposal proposal) =>
    File('${repoDir.path}/${proposal.path}');

/// Writes [proposal] verbatim, creating parent directories.
///
/// Content is never trimmed or reformatted: what the model produced is what the
/// user saw in the preview and confirmed.
Future<File> writeProposal(Directory repoDir, FileProposal proposal) async {
  final file = await proposalFile(repoDir, proposal).create(recursive: true);
  return file.writeAsString(proposal.content);
}

/// A short preview for the confirmation card, saying so when it is short.
///
/// The user is being asked to approve a write; a preview that silently stops
/// mid-file would have them approving something they think they read in full.
String proposalPreview(String content, {int maxChars = 400}) =>
    content.length <= maxChars
        ? content
        : '${content.substring(0, maxChars)}\n'
            '… truncated — ${content.length} characters in full';
