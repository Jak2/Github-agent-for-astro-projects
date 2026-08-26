import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/pinned_scope.dart';
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
  group('subtreeAt', () {
    test('empty path returns the whole tree', () {
      expect(subtreeAt(_sample(), '')!.relativePath, '');
    });

    test('finds a top-level folder', () {
      final node = subtreeAt(_sample(), 'cat');
      expect(node, isNotNull);
      expect(node!.children.map((c) => c.name), ['food.md', 'toys.md']);
    });

    test('finds a nested folder', () {
      expect(subtreeAt(_sample(), 'docs/guides')!.name, 'guides');
    });

    test('finds a file node', () {
      expect(subtreeAt(_sample(), 'cat/food.md')!.isDirectory, isFalse);
    });

    test('returns null for a path that no longer exists', () {
      // A pin left over from a previously selected repo must not crash or
      // silently fall back to the whole tree.
      expect(subtreeAt(_sample(), 'nope/gone'), isNull);
    });
  });

  group('filePathsUnder', () {
    test('lists only files, not directories', () {
      expect(filePathsUnder(subtreeAt(_sample(), 'cat')!), ['cat/food.md', 'cat/toys.md']);
    });

    test('descends through nested folders', () {
      expect(filePathsUnder(subtreeAt(_sample(), 'docs')!), ['docs/guides/setup.md']);
    });

    test('a pinned file yields just itself', () {
      expect(filePathsUnder(subtreeAt(_sample(), 'README.md')!), ['README.md']);
    });
  });

  group('PinnedScope', () {
    test('describes each kind for the prompt', () {
      expect(const PinnedScope.repo('me/repo').promptDescription, 'the whole repository');
      expect(
        const PinnedScope(kind: PinKind.folder, path: 'cat', label: 'cat').promptDescription,
        'the folder "cat"',
      );
      expect(
        const PinnedScope(kind: PinKind.file, path: 'cat/food.md', label: 'food.md')
            .promptDescription,
        'the file "cat/food.md"',
      );
    });

    test('equality is by kind and path so re-pinning the same target is a no-op', () {
      const a = PinnedScope(kind: PinKind.folder, path: 'cat', label: 'cat');
      const b = PinnedScope(kind: PinKind.folder, path: 'cat', label: 'different label');
      expect(a, equals(b));
      expect(
        a,
        isNot(equals(const PinnedScope(kind: PinKind.file, path: 'cat', label: 'cat'))),
      );
    });
  });

  group('applyPinnedFolder', () {
    const catPin = PinnedScope(kind: PinKind.folder, path: 'cat', label: 'cat');
    const nestedPin = PinnedScope(kind: PinKind.folder, path: 'docs/guides', label: 'guides');

    test('no pin leaves the path alone', () {
      expect(applyPinnedFolder('folder/name.md', null), 'folder/name.md');
    });

    test('a repo pin leaves the path alone — the whole repo is the scope', () {
      expect(applyPinnedFolder('folder/name.md', const PinnedScope.repo('me/repo')),
          'folder/name.md');
    });

    test('a file pin leaves the path alone', () {
      expect(
        applyPinnedFolder('notes.md',
            const PinnedScope(kind: PinKind.file, path: 'cat/food.md', label: 'food.md')),
        'notes.md',
      );
    });

    test('a path already inside the pin is untouched', () {
      expect(applyPinnedFolder('cat/food.md', catPin), 'cat/food.md');
      expect(applyPinnedFolder('cat/deep/food.md', catPin), 'cat/deep/food.md');
    });

    test('a bare filename moves inside the pin', () {
      expect(applyPinnedFolder('name.md', catPin), 'cat/name.md');
    });

    test('the model junk prefix is dropped, not nested under the pin', () {
      // The real device output. Both of these landed at the repo root.
      expect(applyPinnedFolder('folder/cat/dog_food/name.md', catPin), 'cat/name.md');
      expect(applyPinnedFolder('folder/dog/dog_food/name.md', catPin), 'cat/name.md');
    });

    test('a nested pin gets the basename too', () {
      expect(applyPinnedFolder('foo/bar/setup.md', nestedPin), 'docs/guides/setup.md');
      expect(applyPinnedFolder('setup.md', nestedPin), 'docs/guides/setup.md');
    });

    test('a nested pin recognises its own subtree as already inside', () {
      expect(applyPinnedFolder('docs/guides/setup.md', nestedPin), 'docs/guides/setup.md');
    });

    test('a sibling with the pin as a name prefix is not treated as inside', () {
      expect(applyPinnedFolder('docs/guidesx/setup.md', nestedPin), 'docs/guides/setup.md');
      expect(applyPinnedFolder('category/food.md', catPin), 'cat/food.md');
    });

    test('leading ./ and doubled slashes do not become the basename', () {
      expect(applyPinnedFolder('./a//name.md', catPin), 'cat/name.md');
    });

    test('an empty path is left for the validator to reject', () {
      expect(applyPinnedFolder('', catPin), '');
    });
  });
}
