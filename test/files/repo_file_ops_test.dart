// test/files/repo_file_ops_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_git/files/repo_file_ops.dart';

void main() {
  late Directory repo;

  setUp(() => repo = Directory.systemTemp.createTempSync('repo_file_ops_test'));
  tearDown(() => repo.deleteSync(recursive: true));

  group('path validation', () {
    // Every entry point takes an untrusted path, so each one is checked —
    // one unguarded call is all it takes to write outside the clone.
    test('escaping the repo is refused everywhere', () {
      expect(() => writeRepoFile(repo, '../evil.txt', 'x'), throwsArgumentError);
      expect(() => readRepoFile(repo, '../evil.txt'), throwsArgumentError);
      expect(() => repoFileExists(repo, 'a/../../evil.txt'), throwsArgumentError);
      expect(() => deleteRepoFile(repo, '../evil.txt'), throwsArgumentError);
      expect(() => looksBinary(repo, '../evil.txt'), throwsArgumentError);
      expect(
        () => renameRepoFile(repo, 'a.txt', '../evil.txt'),
        throwsArgumentError,
      );
      expect(
        () => importFileInto(repo, '/etc/hosts', '../evil.txt'),
        throwsArgumentError,
      );
    });

    test('absolute paths and .git are refused', () {
      expect(() => writeRepoFile(repo, '/etc/passwd', 'x'), throwsArgumentError);
      expect(() => writeRepoFile(repo, '.git/config', 'x'), throwsArgumentError);
      expect(() => writeRepoFile(repo, 'a/.git/hooks/pre-commit', 'x'),
          throwsArgumentError);
      expect(() => writeRepoFile(repo, '', 'x'), throwsArgumentError);
    });
  });

  test('write creates parent directories and reads back', () async {
    await writeRepoFile(repo, 'docs/deep/guide.md', 'hello');
    expect(await readRepoFile(repo, 'docs/deep/guide.md'), 'hello');
    expect(await repoFileExists(repo, 'docs/deep/guide.md'), isTrue);
    expect(await repoFileExists(repo, 'docs/missing.md'), isFalse);
  });

  test('delete removes the file and is quiet about a missing one', () async {
    await writeRepoFile(repo, 'a.txt', 'x');
    await deleteRepoFile(repo, 'a.txt');
    expect(await repoFileExists(repo, 'a.txt'), isFalse);
    await deleteRepoFile(repo, 'a.txt'); // no throw
  });

  group('rename', () {
    test('moves the file, creating the target directory', () async {
      await writeRepoFile(repo, 'a.txt', 'body');
      await renameRepoFile(repo, 'a.txt', 'docs/b.txt');
      expect(await repoFileExists(repo, 'a.txt'), isFalse);
      expect(await readRepoFile(repo, 'docs/b.txt'), 'body');
    });

    test('refuses to overwrite an existing file', () async {
      await writeRepoFile(repo, 'a.txt', 'keep me');
      await writeRepoFile(repo, 'b.txt', 'other');
      expect(
        () => renameRepoFile(repo, 'a.txt', 'b.txt'),
        throwsA(isA<StateError>()),
      );
      expect(await readRepoFile(repo, 'b.txt'), 'other');
    });

    test('refuses a source that does not exist', () {
      expect(
        () => renameRepoFile(repo, 'nope.txt', 'b.txt'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('import copies bytes from outside the repo', () async {
    final source = File('${repo.parent.path}/import_source.bin');
    addTearDown(() => source.deleteSync());
    source.writeAsBytesSync([1, 2, 3]);

    final copied = await importFileInto(repo, source.path, 'assets/in.bin');
    expect(copied.readAsBytesSync(), [1, 2, 3]);
    expect(source.existsSync(), isTrue);
  });

  group('looksBinary', () {
    test('plain text is not binary', () async {
      await writeRepoFile(repo, 'a.txt', 'just text\nwith lines\n');
      expect(await looksBinary(repo, 'a.txt'), isFalse);
    });

    test('a NUL byte in the first 8KB is binary', () async {
      File('${repo.path}/a.png').writeAsBytesSync([0x89, 0x50, 0x00, 0x0d]);
      expect(await looksBinary(repo, 'a.png'), isTrue);
    });

    test('a NUL past the first 8KB is not sniffed — bounded read', () async {
      File('${repo.path}/big.txt')
          .writeAsBytesSync([...List.filled(9000, 0x41), 0x00]);
      expect(await looksBinary(repo, 'big.txt'), isFalse);
    });

    test('an empty file is not binary', () async {
      await writeRepoFile(repo, 'empty.txt', '');
      expect(await looksBinary(repo, 'empty.txt'), isFalse);
    });
  });
}
