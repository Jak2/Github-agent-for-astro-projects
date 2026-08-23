String buildStructuringPrompt({
  required String structureRules,
  required String sourceContent,
  required List<String> refinementRequests,
  String guardrails = '',
  String? personaContent,
  String? skillContent,
}) {
  final buffer = StringBuffer();

  if (guardrails.trim().isNotEmpty) {
    buffer
      ..writeln('Guardrails (always apply):')
      ..writeln(guardrails)
      ..writeln()
      ..writeln('---')
      ..writeln();
  }

  if (personaContent != null && personaContent.trim().isNotEmpty) {
    buffer
      ..writeln(personaContent)
      ..writeln()
      ..writeln('---')
      ..writeln();
  }

  buffer.writeln(structureRules);

  if (skillContent != null && skillContent.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln(skillContent);
  }

  buffer
    ..writeln()
    ..writeln('---')
    ..writeln()
    ..writeln('Source content to structure:')
    ..writeln()
    ..writeln(sourceContent);

  if (refinementRequests.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln('Additional refinement requests, apply in order:');
    for (final request in refinementRequests) {
      buffer.writeln('- $request');
    }
  }

  return buffer.toString();
}
