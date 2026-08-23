import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/save_path_resolver.dart';

void main() {
  test('resolves an explicit folder instruction, keeping the source filename', () {
    final path = resolveSavePath(
      instruction: 'save it in docs/posts/',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, 'docs/posts/raw-idea.md');
  });

  test('resolves an instruction that already includes a filename', () {
    final path = resolveSavePath(
      instruction: 'put it at content/blog/my-post.md',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, 'content/blog/my-post.md');
  });

  test('resolves a bare path with no lead-in words', () {
    final path = resolveSavePath(
      instruction: 'src/content/blog/',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, 'src/content/blog/raw-idea.md');
  });

  test('returns null for an instruction with no discernible path', () {
    final path = resolveSavePath(
      instruction: 'looks good, thanks!',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, isNull);
  });

  test('returns null for an absolute path instruction', () {
    final path = resolveSavePath(
      instruction: 'save it at /etc/passwd',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, isNull);
  });

  test('returns null for a path containing ".." segments', () {
    final path = resolveSavePath(
      instruction: 'save it in ../../../outside/',
      sourceRelativePath: 'notes/raw-idea.txt',
    );
    expect(path, isNull);
  });
}
