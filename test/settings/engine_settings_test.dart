import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:git_agent_app/settings/engine_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns cloud defaults when nothing saved', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await EngineSettings.load(prefs);
    expect(settings.choice, EngineChoice.cloud);
    expect(settings.cloudEndpoint, '');
    expect(settings.onDeviceModelPath, '');
  });

  test('save then load round-trips all fields', () async {
    final prefs = await SharedPreferences.getInstance();
    const settings = EngineSettings(
      choice: EngineChoice.onDevice,
      cloudEndpoint: 'https://api.example.com/v1/chat',
      cloudModel: 'gpt-x',
      cloudHeaders: 'X-Org: acme',
      onDeviceModelPath: '/sdcard/models/model.gguf',
      structureMdOverridePath: '/sdcard/docs/structure.md',
    );
    await settings.save(prefs);

    final loaded = await EngineSettings.load(prefs);
    expect(loaded.choice, EngineChoice.onDevice);
    expect(loaded.cloudEndpoint, 'https://api.example.com/v1/chat');
    expect(loaded.cloudModel, 'gpt-x');
    expect(loaded.cloudHeaders, 'X-Org: acme');
    expect(loaded.onDeviceModelPath, '/sdcard/models/model.gguf');
    expect(loaded.structureMdOverridePath, '/sdcard/docs/structure.md');
  });

  test('cloudHeadersMap parses "Name: value" lines and skips malformed ones', () {
    const settings = EngineSettings(
      cloudHeaders: 'X-Org: acme\nbad-line-no-colon\nX-Env:  staging  ',
    );
    expect(settings.cloudHeadersMap, {
      'X-Org': 'acme',
      'X-Env': 'staging',
    });
  });
}
