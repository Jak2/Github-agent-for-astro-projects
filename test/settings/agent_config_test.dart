// test/settings/agent_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:git_agent_app/settings/agent_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load returns defaults when nothing saved', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final config = await AgentConfig.load(prefs);
    expect(config.defaultPersonaSlug, isNull);
    expect(config.guardrails, '');
  });

  test('save then load round-trips persona slug and guardrails', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const config = AgentConfig(defaultPersonaSlug: 'code-reviewer', guardrails: 'Never invent facts.');
    await config.save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.defaultPersonaSlug, 'code-reviewer');
    expect(loaded.guardrails, 'Never invent facts.');
  });

  test('copyWith with clearPersona removes the default persona', () async {
    const config = AgentConfig(defaultPersonaSlug: 'debugger', guardrails: 'g');
    final cleared = config.copyWith(clearPersona: true);
    expect(cleared.defaultPersonaSlug, isNull);
    expect(cleared.guardrails, 'g');
  });

  test('saving a null defaultPersonaSlug removes any previously saved value', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await const AgentConfig(defaultPersonaSlug: 'analyst').save(prefs);
    await const AgentConfig().save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.defaultPersonaSlug, isNull);
  });
}
