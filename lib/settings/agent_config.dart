import 'package:shared_preferences/shared_preferences.dart';

class AgentConfig {
  final String? defaultPersonaSlug;
  final String guardrails;

  const AgentConfig({this.defaultPersonaSlug, this.guardrails = ''});

  AgentConfig copyWith({
    String? defaultPersonaSlug,
    bool clearPersona = false,
    String? guardrails,
  }) {
    return AgentConfig(
      defaultPersonaSlug: clearPersona ? null : (defaultPersonaSlug ?? this.defaultPersonaSlug),
      guardrails: guardrails ?? this.guardrails,
    );
  }

  static const _keyPersona = 'agent_default_persona_slug';
  static const _keyGuardrails = 'agent_guardrails';

  static Future<AgentConfig> load(SharedPreferences prefs) async {
    return AgentConfig(
      defaultPersonaSlug: prefs.getString(_keyPersona),
      guardrails: prefs.getString(_keyGuardrails) ?? '',
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    if (defaultPersonaSlug == null) {
      await prefs.remove(_keyPersona);
    } else {
      await prefs.setString(_keyPersona, defaultPersonaSlug!);
    }
    await prefs.setString(_keyGuardrails, guardrails);
  }
}
