import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/chat/file_proposal.dart';
import 'package:git_agent_app/chat/proposal_writer.dart';

void main() {
  late Directory repo;

  setUp(() => repo = Directory.systemTemp.createTempSync('proposal_writer_test'));
  tearDown(() => repo.deleteSync(recursive: true));

  test('writes the file under the repo, creating parent folders', () async {
    final file = await writeProposal(
      repo,
      const FileProposal(path: 'cat/dog_food.md', content: '# Dog food\n'),
    );

    expect(file.path, '${repo.path}/cat/dog_food.md');
    expect(File('${repo.path}/cat/dog_food.md').readAsStringSync(), '# Dog food\n');
  });

  test('writes content verbatim — no trimming or reformatting', () async {
    const content = '\n  leading space\ttab\n\n\ntrailing newlines\n\n';
    await writeProposal(repo, const FileProposal(path: 'a.md', content: content));

    expect(File('${repo.path}/a.md').readAsStringSync(), content);
  });

  test('overwrites an existing file rather than appending', () async {
    File('${repo.path}/a.md').writeAsStringSync('old and much longer content');
    await writeProposal(repo, const FileProposal(path: 'a.md', content: 'new'));

    expect(File('${repo.path}/a.md').readAsStringSync(), 'new');
  });

  test('proposalFile reports whether the target already exists', () async {
    const proposal = FileProposal(path: 'a.md', content: 'x');
    expect(await proposalFile(repo, proposal).exists(), isFalse);
    await writeProposal(repo, proposal);
    expect(await proposalFile(repo, proposal).exists(), isTrue);
  });

  test('a short preview is shown whole, with no truncation notice', () {
    expect(proposalPreview('# Dog food\nkibble\n'), '# Dog food\nkibble\n');
  });

  test('a long preview is cut and says so, giving the full size', () {
    final preview = proposalPreview('x' * 500, maxChars: 100);
    expect(preview, startsWith('x' * 100));
    expect(preview, isNot(contains('x' * 101)));
    expect(preview, contains('truncated'));
    expect(preview, contains('500'));
  });
}
