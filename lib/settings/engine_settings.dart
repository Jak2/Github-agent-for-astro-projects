import 'package:shared_preferences/shared_preferences.dart';

enum EngineChoice { cloud, onDevice }

class EngineSettings {
  final EngineChoice choice;
  final String cloudEndpoint;
  final String cloudApiKey;
  final String cloudModel;
  final String cloudHeaders; // raw "Header: value" lines, one per line
  final String onDeviceModelPath;
  final String structureMdOverridePath;

  const EngineSettings({
    this.choice = EngineChoice.cloud,
    this.cloudEndpoint = '',
    this.cloudApiKey = '',
    this.cloudModel = '',
    this.cloudHeaders = '',
    this.onDeviceModelPath = '',
    this.structureMdOverridePath = '',
  });

  EngineSettings copyWith({
    EngineChoice? choice,
    String? cloudEndpoint,
    String? cloudApiKey,
    String? cloudModel,
    String? cloudHeaders,
    String? onDeviceModelPath,
    String? structureMdOverridePath,
  }) {
    return EngineSettings(
      choice: choice ?? this.choice,
      cloudEndpoint: cloudEndpoint ?? this.cloudEndpoint,
      cloudApiKey: cloudApiKey ?? this.cloudApiKey,
      cloudModel: cloudModel ?? this.cloudModel,
      cloudHeaders: cloudHeaders ?? this.cloudHeaders,
      onDeviceModelPath: onDeviceModelPath ?? this.onDeviceModelPath,
      structureMdOverridePath: structureMdOverridePath ?? this.structureMdOverridePath,
    );
  }

  Map<String, String> get cloudHeadersMap {
    final map = <String, String>{};
    for (final line in cloudHeaders.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
    return map;
  }

  static const _keyChoice = 'engine_choice';
  static const _keyEndpoint = 'cloud_endpoint';
  static const _keyModel = 'cloud_model';
  static const _keyHeaders = 'cloud_headers';
  static const _keyModelPath = 'on_device_model_path';
  static const _keyStructureMdOverridePath = 'structure_md_override_path';

  static Future<EngineSettings> load(SharedPreferences prefs) async {
    return EngineSettings(
      choice: EngineChoice.values.firstWhere(
        (c) => c.name == prefs.getString(_keyChoice),
        orElse: () => EngineChoice.cloud,
      ),
      cloudEndpoint: prefs.getString(_keyEndpoint) ?? '',
      cloudModel: prefs.getString(_keyModel) ?? '',
      cloudHeaders: prefs.getString(_keyHeaders) ?? '',
      onDeviceModelPath: prefs.getString(_keyModelPath) ?? '',
      structureMdOverridePath: prefs.getString(_keyStructureMdOverridePath) ?? '',
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_keyChoice, choice.name);
    await prefs.setString(_keyEndpoint, cloudEndpoint);
    await prefs.setString(_keyModel, cloudModel);
    await prefs.setString(_keyHeaders, cloudHeaders);
    await prefs.setString(_keyModelPath, onDeviceModelPath);
    await prefs.setString(_keyStructureMdOverridePath, structureMdOverridePath);
  }
}
