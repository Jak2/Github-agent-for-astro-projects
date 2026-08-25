import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/prompt_budget.dart';

String _prompt({
  String header = 'HEADER\n',
  String tree = '',
  String file = '',
  List<String> transcript = const [],
  String cue = 'Assistant:',
  int maxChars = 1000,
}) =>
    buildBudgetedPrompt(
      header: header,
      treeText: tree,
      fileSection: file,
      transcript: transcript,
      turnCue: cue,
      maxChars: maxChars,
    );

void main() {
  group('buildBudgetedPrompt', () {
    test('passes small input through with everything intact', () {
      final p = _prompt(
        tree: 'lib/\n  main.dart\n',
        transcript: ['User: hi'],
      );
      expect(p, contains('HEADER'));
      expect(p, contains('main.dart'));
      expect(p, contains('User: hi'));
      expect(p, endsWith('Assistant:'));
      expect(p, isNot(contains('truncated')));
    });

    test('stays within the budget when the tree is enormous', () {
      final huge = List.generate(5000, (i) => 'src/file_$i.dart').join('\n');
      final p = _prompt(tree: huge, transcript: ['User: q'], maxChars: 800);
      expect(p.length, lessThanOrEqualTo(800));
    });

    test('announces tree truncation rather than silently shortening', () {
      final huge = List.generate(5000, (i) => 'src/file_$i.dart').join('\n');
      final p = _prompt(tree: huge, maxChars: 600);
      expect(p, contains('tree truncated'));
    });

    test('keeps the newest turn and drops the oldest when over budget', () {
      final many = List.generate(200, (i) => 'User: message number $i');
      final p = _prompt(transcript: many, maxChars: 700);
      expect(p, contains('message number 199'));
      expect(p, isNot(contains('message number 0\n')));
      expect(p, contains('omitted to fit'));
    });

    test('always keeps the header and the turn cue', () {
      final many = List.generate(500, (i) => 'User: $i');
      final p = _prompt(transcript: many, maxChars: 300);
      expect(p, startsWith('HEADER'));
      expect(p, endsWith('Assistant:'));
    });

    test('truncates an opened file before touching the question', () {
      final bigFile = 'x' * 5000;
      final p = _prompt(
        file: bigFile,
        transcript: ['User: what does this do?'],
        maxChars: 900,
      );
      expect(p, contains('what does this do?'));
      expect(p, contains('file truncated'));
      expect(p.length, lessThanOrEqualTo(900));
    });

    test('cuts the tree at a line break so no path is left half-written', () {
      final tree = List.generate(200, (i) => 'src/module_$i/widget.dart').join('\n');
      final p = _prompt(tree: tree, maxChars: 700);
      final body = p.split('[tree truncated').first;
      expect(body.trimRight(), endsWith('.dart'));
    });

    test('handles an empty transcript and empty tree', () {
      final p = _prompt();
      expect(p, startsWith('HEADER'));
      expect(p, endsWith('Assistant:'));
    });
  });
}
