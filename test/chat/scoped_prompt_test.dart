import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/file_proposal.dart';
import 'package:git_agent_app/chat/pinned_scope.dart';
import 'package:git_agent_app/chat/scoped_prompt.dart';
import 'package:git_agent_app/files/file_tree.dart';

FileTreeNode _dir(String name, String path, List<FileTreeNode> children) =>
    FileTreeNode(name: name, relativePath: path, isDirectory: true, children: children);

FileTreeNode _file(String name, String path) =>
    FileTreeNode(name: name, relativePath: path, isDirectory: false, children: const []);

/// root/
///   cat/        food.md, toys.md
///   docs/guides/ setup.md
///   README.md
FileTreeNode _sample() => _dir('root', '', [
      _dir('cat', 'cat', [_file('food.md', 'cat/food.md'), _file('toys.md', 'cat/toys.md')]),
      _dir('docs', 'docs', [
        _dir('guides', 'docs/guides', [_file('setup.md', 'docs/guides/setup.md')]),
      ]),
      _file('README.md', 'README.md'),
    ]);

void main() {
  ({String header, String treeText, bool pinStale}) build(PinnedScope? pinned) =>
      buildScopedContext(repoFullName: 'me/repo', tree: _sample(), pinned: pinned);

  test('no pin ships the whole tree and says nothing about a scope', () {
    final ctx = build(null);
    expect(ctx.header, contains('Repository: me/repo'));
    expect(ctx.header, isNot(contains('pinned')));
    expect(ctx.treeText, contains('food.md'));
    expect(ctx.treeText, contains('README.md'));
    expect(ctx.pinStale, isFalse);
  });

  test('a repo pin keeps the whole tree but states the scope', () {
    final ctx = build(const PinnedScope.repo('me/repo'));
    expect(ctx.header, contains('pinned the whole repository'));
    expect(ctx.treeText, contains('README.md'));
  });

  test('a folder pin narrows the tree to that subtree only', () {
    final ctx = build(const PinnedScope(kind: PinKind.folder, path: 'cat', label: 'cat'));
    expect(ctx.header, contains('pinned the folder "cat"'));
    expect(ctx.treeText, contains('food.md'));
    expect(ctx.treeText, contains('toys.md'));
    // The point of the feature: everything outside the pin is gone.
    expect(ctx.treeText, isNot(contains('README.md')));
    expect(ctx.treeText, isNot(contains('setup.md')));
  });

  test('a nested folder pin resolves by full relative path', () {
    final ctx = build(const PinnedScope(kind: PinKind.folder, path: 'docs/guides', label: 'guides'));
    expect(ctx.treeText.trim(), 'setup.md');
  });

  test('a file pin reduces the tree to the one path, content rides elsewhere', () {
    final ctx = build(const PinnedScope(kind: PinKind.file, path: 'cat/food.md', label: 'food.md'));
    expect(ctx.header, contains('pinned the file "cat/food.md"'));
    expect(ctx.treeText.trim(), 'cat/food.md');
  });

  test('every header teaches the create-file protocol and the confirm step', () {
    final header = build(null).header;
    expect(header, contains('```create-file path='));
    expect(header, contains('inside the repository'));
    expect(header, contains('confirm'));
  });

  test('the example block in the header is one the parser actually accepts', () {
    // If these two ever drift apart, the model follows the instructions
    // perfectly and the app still writes nothing.
    final parsed = parseFileProposals(build(null).header);
    expect(parsed.rejected, isEmpty);
    expect(parsed.proposals.single.path, '<folder>/<filename>.md');
  });

  test('the example path cannot be mistaken for a real one', () {
    // A 1-1.5B model copied the old `folder/name.md` verbatim and wrote
    // `folder/cat/dog_food/name.md` at the repo root. Angle brackets are the
    // one shape no real file has, so a literal copy is at least obviously a
    // placeholder — and applyPinnedFolder catches it anyway.
    final path = parseFileProposals(build(null).header).proposals.single.path;
    expect(path, contains('<'));
    expect(path, contains('>'));
    expect(build(null).header, contains('it is a placeholder'));
  });

  test('a folder pin tells the model to put new files in that folder', () {
    final header = build(const PinnedScope(kind: PinKind.folder, path: 'cat', label: 'cat')).header;
    expect(header, contains('Put new files inside "cat/"'));
  });

  test('with no folder pinned there is no default folder claim', () {
    expect(build(null).header, isNot(contains('Put new files inside')));
    expect(
      build(const PinnedScope(kind: PinKind.file, path: 'cat/food.md', label: 'food.md')).header,
      isNot(contains('Put new files inside')),
    );
  });

  test('a stale pin falls back to the whole tree and reports it', () {
    final ctx = build(const PinnedScope(kind: PinKind.folder, path: 'gone', label: 'gone'));
    expect(ctx.pinStale, isTrue);
    // Falls back rather than answering about nothing, and drops the claim that
    // a scope is in force — the caller tells the user instead.
    expect(ctx.treeText, contains('README.md'));
    expect(ctx.header, isNot(contains('pinned')));
  });

  test('the header says out loud that claiming a write is not a write', () {
    final header = build(null).header;
    expect(header, contains('does not create it'));
    expect(header, contains('exact filename'));
  });
}
