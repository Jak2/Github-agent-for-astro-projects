import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/structuring_prompt.dart';

void main() {
  test('includes rules and source content with no refinements', () {
    final prompt = buildStructuringPrompt(
      structureRules: '# Rules\n1. Do X.',
      sourceContent: 'raw text here',
      refinementRequests: const [],
    );
    expect(prompt, contains('# Rules'));
    expect(prompt, contains('1. Do X.'));
    expect(prompt, contains('raw text here'));
    expect(prompt, isNot(contains('Additional refinement')));
  });

  test('appends refinement requests in order when present', () {
    final prompt = buildStructuringPrompt(
      structureRules: '# Rules',
      sourceContent: 'raw text',
      refinementRequests: const ['make it shorter', 'add a summary section'],
    );
    final shorterIndex = prompt.indexOf('make it shorter');
    final summaryIndex = prompt.indexOf('add a summary section');
    expect(shorterIndex, greaterThan(-1));
    expect(summaryIndex, greaterThan(shorterIndex));
  });

  test('omitting new params reproduces the exact prior output', () {
    final prompt = buildStructuringPrompt(
      structureRules: '# Rules\n1. Do X.',
      sourceContent: 'raw text here',
      refinementRequests: const [],
    );
    expect(prompt, '''
# Rules
1. Do X.

---

Source content to structure:

raw text here
''');
  });

  test('composes guardrails, persona, skill in the specified order', () {
    final prompt = buildStructuringPrompt(
      structureRules: 'BASE_RULES',
      sourceContent: 'SOURCE',
      refinementRequests: const ['REFINEMENT'],
      guardrails: 'GUARDRAILS_TEXT',
      personaContent: 'PERSONA_TEXT',
      skillContent: 'SKILL_TEXT',
    );
    final order = [
      'GUARDRAILS_TEXT',
      'PERSONA_TEXT',
      'BASE_RULES',
      'SKILL_TEXT',
      'SOURCE',
      'REFINEMENT',
    ];
    var lastIndex = -1;
    for (final marker in order) {
      final index = prompt.indexOf(marker);
      expect(index, greaterThan(lastIndex), reason: '$marker out of order');
      lastIndex = index;
    }
  });

  test('empty guardrails and null persona/skill are omitted entirely', () {
    final prompt = buildStructuringPrompt(
      structureRules: 'RULES',
      sourceContent: 'SOURCE',
      refinementRequests: const [],
      guardrails: '   ',
    );
    expect(prompt, isNot(contains('Guardrails')));
  });
}
