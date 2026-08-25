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

  // The confirmation card lets the user retype the path, so these rules have
  // to hold for a hand-typed path exactly as they do for the model's.
  group('filePathRejection', () {
    test('accepts an ordinary repo-relative path', () {
      expect(filePathRejection('cat/dog_food.md'), isNull);
    });

    test('rejects a leading slash', () {
      expect(filePathRejection('/etc/passwd'), isNotNull);
    });

    test('rejects a windows drive letter', () {
      expect(filePathRejection(r'C:\temp\x.md'), isNotNull);
    });

    test('rejects ..', () {
      expect(filePathRejection('../outside.md'), isNotNull);
      expect(filePathRejection('cat/../../etc/passwd'), isNotNull);
    });

    test('rejects anything inside .git', () {
      expect(filePathRejection('.git/config'), isNotNull);
    });

    test('rejects an empty path and a directory', () {
      expect(filePathRejection(''), isNotNull);
      expect(filePathRejection('cat/'), isNotNull);
    });

    test('normaliseFilePath drops . and empty segments', () {
      expect(normaliseFilePath('./cat//dog.md'), 'cat/dog.md');
    });
  });

  group('claimsFileCreation', () {
    test('catches the exact hallucination seen on device', () {
      expect(
        claimsFileCreation('File "food.md" has been created successfully.'),
        isTrue,
      );
    });

    test('catches the common first-person phrasings', () {
      for (final reply in [
        "I've created dog.md for you.",
        'I have added the file to the cat folder.',
        'I created dog.md.',
        'The file was written to cat/dog.md.',
        'Successfully created dog.md!',
        'file created',
      ]) {
        expect(claimsFileCreation(reply), isTrue, reason: reply);
      }
    });

    test('ordinary answers are not claims', () {
      for (final reply in [
        'The cat folder contains food.md and toys.md.',
        'Do you want me to create dog.md?',
        'To create a file, use the create-file block.',
      ]) {
        expect(claimsFileCreation(reply), isFalse, reason: reply);
      }
    });

    test('a reply that actually proposes a file still parses', () {
      // The notice is only ever shown when parsing found nothing, so a reply
      // that both claims and proposes must keep proposing.
      const reply = 'I have created the file.\n'
          '```create-file path=cat/dog.md\nhi\n```';
      expect(parseFileProposals(reply).proposals.single.path, 'cat/dog.md');
    });
  });
}
