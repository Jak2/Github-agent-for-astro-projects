import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/file_proposal.dart';

void main() {
  group('parseFileProposals', () {
    test('extracts a single proposal with its content', () {
      final r = parseFileProposals('''
Sure, here it is.

```create-file path=cat/dog_food.md
# Dog food
Two meals a day.
```

Anything else?
''');
      expect(r.rejected, isEmpty);
      expect(r.proposals.single.path, 'cat/dog_food.md');
      expect(r.proposals.single.content, '# Dog food\nTwo meals a day.');
    });

    test('extracts several proposals from one reply', () {
      final r = parseFileProposals('''
```create-file path=a.md
A
```
```create-file path=b/c.md
C
```
''');
      expect(r.proposals.map((p) => p.path), ['a.md', 'b/c.md']);
    });

    test('plain replies produce nothing', () {
      expect(parseFileProposals('I cannot create files.').isEmpty, isTrue);
    });

    test('an ordinary code fence is not a proposal', () {
      final r = parseFileProposals('```dart\nvoid main() {}\n```');
      expect(r.isEmpty, isTrue);
    });

    test('tolerates quoted paths', () {
      final r = parseFileProposals('```create-file path="cat/dog food.md"\nx\n```');
      expect(r.proposals.single.path, 'cat/dog food.md');
    });

    test('keeps an unterminated block so a truncated reply is not lost', () {
      final r = parseFileProposals('```create-file path=notes.md\nline one\nline two');
      expect(r.proposals.single.path, 'notes.md');
      expect(r.proposals.single.content, 'line one\nline two');
    });

    test('preserves blank lines and indentation in content', () {
      final r = parseFileProposals('```create-file path=x.md\na\n\n    indented\n```');
      expect(r.proposals.single.content, 'a\n\n    indented');
    });

    group('rejects unsafe paths', () {
      void rejects(String path, String because) {
        test('$path — $because', () {
          final r = parseFileProposals('```create-file path=$path\nx\n```');
          expect(r.proposals, isEmpty, reason: 'must not be written');
          expect(r.rejected.single.reason, isNotEmpty);
        });
      }

      rejects('../outside.md', 'escapes the repo');
      rejects('cat/../../etc/passwd', 'escapes via a nested ..');
      rejects('/etc/passwd', 'absolute');
      rejects('.git/config', 'inside .git');
      rejects(r'cat\dog.md', 'backslashes');
    });

    test('a rejected path is reported, never silently dropped', () {
      final r = parseFileProposals('```create-file path=../x.md\nx\n```');
      expect(r.rejected.single.rawPath, '../x.md');
      expect(r.isEmpty, isFalse);
    });

    test('normalises redundant segments', () {
      final r = parseFileProposals('```create-file path=./cat//dog.md\nx\n```');
      expect(r.proposals.single.path, 'cat/dog.md');
    });
  });
}
