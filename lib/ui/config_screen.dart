// lib/ui/config_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../engine/on_device_engine_registry.dart';
import '../instructions/instruction_library.dart';
import '../secrets/secret_store.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

class ConfigScreen extends StatefulWidget {
  final SecretStore secretStore;
  const ConfigScreen({super.key, required this.secretStore});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  EngineSettings _settings = const EngineSettings();
  final _patController = TextEditingController();
  final _endpointController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _headersController = TextEditingController();
  String? _structureMdOverridePath;
  bool _loading = true;
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  List<InstructionEntry> _skills = [];
  List<InstructionEntry> _personas = [];
  AgentConfig _agentConfig = const AgentConfig();
  final _guardrailsController = TextEditingController();
  bool _langchainEnabled = false;
  bool _langgraphEnabled = false;
  bool _modelBusy = false;
  int _modelBusyElapsedSeconds = 0;
  Timer? _modelBusyTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = await EngineSettings.load(prefs);
      final agentConfig = await AgentConfig.load(prefs);
      final pat = await widget.secretStore.read(secretKeyGithubPat) ?? '';
      final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';

      final docs = await getApplicationDocumentsDirectory();
      final skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
      final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
      final skills = await skillsLibrary.list();
      final personas = await personasLibrary.list();

      if (!mounted) return;
      setState(() {
        _settings = settings;
        _agentConfig = agentConfig;
        _patController.text = pat;
        _endpointController.text = settings.cloudEndpoint;
        _apiKeyController.text = apiKey;
        _modelController.text = settings.cloudModel;
        _headersController.text = settings.cloudHeaders;
        _guardrailsController.text = agentConfig.guardrails;
        _structureMdOverridePath =
            settings.structureMdOverridePath.isEmpty ? null : settings.structureMdOverridePath;
        _skillsLibrary = skillsLibrary;
        _personasLibrary = personasLibrary;
        _skills = skills;
        _personas = personas;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load settings: $e')));
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final updated = _settings.copyWith(
      cloudEndpoint: _endpointController.text,
      cloudModel: _modelController.text,
      cloudHeaders: _headersController.text,
    );
    await updated.save(prefs);
    await widget.secretStore.write(secretKeyGithubPat, _patController.text);
    await widget.secretStore.write(secretKeyCloudApiKey, _apiKeyController.text);

    final updatedAgentConfig = _agentConfig.copyWith(guardrails: _guardrailsController.text);
    await updatedAgentConfig.save(prefs);
    _agentConfig = updatedAgentConfig;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> _showEntryEditor({
    required InstructionLibrary library,
    required void Function(List<InstructionEntry>) onUpdated,
    InstructionEntry? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final descriptionController = TextEditingController(text: existing?.description ?? '');
    final contentController = TextEditingController(text: existing?.content ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.fg, width: 3),
        ),
        title: Text(existing == null ? 'Add' : 'Edit', style: appHeading(size: 16, weight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              appBorderedField(controller: nameController, hint: 'Name', enabled: existing == null),
              const SizedBox(height: 10),
              appBorderedField(controller: descriptionController, hint: 'Description'),
              const SizedBox(height: 10),
              appBorderedField(controller: contentController, hint: 'Content (Markdown)', maxLines: 5),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: appBody(size: 13, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Save', style: appBody(size: 13, weight: FontWeight.w600)),
          ),
        ],
      ),
    );

    try {
      if (saved != true) return;
      try {
        if (existing == null) {
          await library.add(
            name: nameController.text,
            description: descriptionController.text,
            content: contentController.text,
          );
        } else {
          await library.update(
            existing.slug,
            description: descriptionController.text,
            content: contentController.text,
          );
        }
        onUpdated(await library.list());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
        }
      }
    } finally {
      nameController.dispose();
      descriptionController.dispose();
      contentController.dispose();
    }
  }

  Widget _instructionSection({
    required String title,
    required InstructionLibrary? library,
    required List<InstructionEntry> entries,
    required void Function(List<InstructionEntry>) onUpdated,
    void Function(String slug)? onDeleted,
  }) {
    if (library == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: appHeading(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final entry in entries)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.fg, width: 2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name, style: appBody(size: 13.5, weight: FontWeight.w600)),
                      Text(entry.description, style: appBody(size: 11.5, color: AppColors.muted)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 16, color: AppColors.fg),
                  onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated, existing: entry),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 16, color: AppColors.fg),
                  onPressed: () async {
                    await library.delete(entry.slug);
                    onDeleted?.call(entry.slug);
                    onUpdated(await library.list());
                  },
                ),
              ],
            ),
          ),
        appSecondaryButton(
          label: '+ Add ${title.toLowerCase().substring(0, title.length - 1)}',
          onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated),
        ),
      ],
    );
  }

  Future<void> _pickOnDeviceModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) {
      setState(() => _settings = _settings.copyWith(onDeviceModelPath: path));
    }
  }

  Future<void> _loadModel() async {
    final path = _settings.onDeviceModelPath;
    if (path.isEmpty) return;

    // Fail fast on an obviously bad file instead of waiting out the full
    // native load timeout for something that can never succeed.
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Model file no longer exists at this path.')));
      }
      return;
    }
    final size = await file.length();
    if (size < 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Model file looks truncated/corrupt (${size}B) — re-download or re-pick it.')));
      }
      return;
    }

    setState(() => _modelBusy = true);
    _modelBusyElapsedSeconds = 0;
    _modelBusyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _modelBusyElapsedSeconds++);
    });
    try {
      await OnDeviceEngineRegistry.instance.forPath(path).load();
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Model load timed out after ${_modelBusyElapsedSeconds}s — likely stuck, not just slow. Try a smaller model or restart the app.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load model: $e')));
      }
    } finally {
      _modelBusyTimer?.cancel();
      _modelBusyTimer = null;
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _offloadModel() async {
    setState(() => _modelBusy = true);
    try {
      await OnDeviceEngineRegistry.instance.unload();
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _confirmUninstallModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.fg, width: 3),
        ),
        title: Text('Uninstall model?', style: appHeading(size: 16, weight: FontWeight.w700)),
        content: Text(
          'This deletes the model file from your device. You can re-add it later by choosing the file again.',
          style: appBody(size: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: appBody(size: 13, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Uninstall', style: appBody(size: 13, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed == true) await _uninstallModel();
  }

  Future<void> _uninstallModel() async {
    final path = _settings.onDeviceModelPath;
    if (path.isEmpty) return;
    setState(() => _modelBusy = true);
    try {
      await OnDeviceEngineRegistry.instance.unload();
      final file = File(path);
      if (await file.exists()) await file.delete();
      final prefs = await SharedPreferences.getInstance();
      final updated = _settings.copyWith(onDeviceModelPath: '');
      await updated.save(prefs);
      if (mounted) setState(() => _settings = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to uninstall model: $e')));
      }
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Widget _modelsSection() {
    final path = _settings.onDeviceModelPath;
    if (path.isEmpty) {
      return Text(
        'No model added yet — pick one above under "On-device (.gguf)".',
        style: appBody(size: 12.5, color: AppColors.muted),
      );
    }
    final loaded = OnDeviceEngineRegistry.instance.isLoadedFor(path);
    final name = path.split('/').last;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.fg, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: appBody(size: 13.5, weight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: loaded ? Colors.greenAccent : AppColors.muted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                loaded ? 'Active — loaded in memory' : 'Not loaded',
                style: appMono(size: 11, color: loaded ? Colors.greenAccent : AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: appSecondaryButton(
                  label: loaded ? 'Loaded' : (_modelBusy ? 'Loading… ${_modelBusyElapsedSeconds}s' : 'Load'),
                  onPressed: (loaded || _modelBusy) ? null : _loadModel,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: appSecondaryButton(
                  label: 'Offload',
                  onPressed: (!loaded || _modelBusy) ? null : _offloadModel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          appSecondaryButton(
            label: 'Uninstall',
            onPressed: _modelBusy ? null : _confirmUninstallModel,
          ),
        ],
      ),
    );
  }

  Future<void> _importStructureMd() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) {
      final prefs = await SharedPreferences.getInstance();
      final updated = _settings.copyWith(structureMdOverridePath: path);
      await updated.save(prefs);
      setState(() {
        _settings = updated;
        _structureMdOverridePath = path;
      });
    }
  }

  Future<void> _exportStructureMd() async {
    final path = _structureMdOverridePath;
    final content = path != null
        ? await File(path).readAsString()
        : await DefaultAssetBundle.of(context).loadString('assets/structure.md');
    final dir = await getTemporaryDirectory();
    final exportFile = File('${dir.path}/structure.md');
    await exportFile.writeAsString(content);
    await Share.shareXFiles([XFile(exportFile.path)]);
  }

  Widget _toggleRow({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.fg, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: appBody(size: 13.5, weight: FontWeight.w600)),
                Text(description, style: appBody(size: 11.5, color: AppColors.muted)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.bg,
            activeTrackColor: AppColors.fg,
            inactiveThumbColor: AppColors.fg,
            inactiveTrackColor: AppColors.bg,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.fg)));
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
        children: [
          SizedBox(
            height: 60,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('Agent configuration', style: appHeading(size: 17, weight: FontWeight.w700)),
              ],
            ),
          ),
          const Divider(color: AppColors.fg, thickness: 2, height: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              children: [
                Text('GitHub Personal Access Token', style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 0.6)),
                const SizedBox(height: 8),
                appBorderedField(controller: _patController, hint: 'ghp_xxxxxxxxxxxx', obscure: true),
                const SizedBox(height: 22),

                Text('LLM Engine', style: appHeading(size: 14, weight: FontWeight.w700)),
                RadioListTile<EngineChoice>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Cloud API', style: appBody(size: 14)),
                  value: EngineChoice.cloud,
                  groupValue: _settings.choice,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
                ),
                if (_settings.choice == EngineChoice.cloud) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 8),
                    child: Column(
                      children: [
                        appBorderedField(controller: _endpointController, hint: 'Endpoint URL'),
                        const SizedBox(height: 8),
                        appBorderedField(controller: _apiKeyController, hint: 'API key', obscure: true),
                        const SizedBox(height: 8),
                        appBorderedField(controller: _modelController, hint: 'Model name (optional)'),
                        const SizedBox(height: 8),
                        appBorderedField(controller: _headersController, hint: 'Extra headers (Name: value per line)', maxLines: 2),
                      ],
                    ),
                  ),
                ],
                RadioListTile<EngineChoice>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('On-device (.gguf)', style: appBody(size: 14)),
                  value: EngineChoice.onDevice,
                  groupValue: _settings.choice,
                  onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
                ),
                if (_settings.choice == EngineChoice.onDevice)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _settings.onDeviceModelPath.isEmpty ? 'No model selected' : _settings.onDeviceModelPath,
                            style: appMono(size: 11.5, color: AppColors.muted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 120,
                          child: appSecondaryButton(label: 'Choose file', onPressed: _pickOnDeviceModel),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 22),

                Text('Models', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                _modelsSection(),
                const SizedBox(height: 22),

                Text('Agent framework', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 10),
                _toggleRow(
                  title: 'LangChain',
                  description: 'Chain prompts and tools for structuring',
                  value: _langchainEnabled,
                  onChanged: (v) => setState(() => _langchainEnabled = v),
                ),
                _toggleRow(
                  title: 'LangGraph',
                  description: 'Multi-step agent orchestration',
                  value: _langgraphEnabled,
                  onChanged: (v) => setState(() => _langgraphEnabled = v),
                ),
                const SizedBox(height: 22),

                Text('Structuring rules (structure.md)', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(_structureMdOverridePath ?? 'Using bundled default', style: appMono(size: 12, color: AppColors.muted)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: appSecondaryButton(label: 'Import', onPressed: _importStructureMd)),
                    const SizedBox(width: 8),
                    Expanded(child: appSecondaryButton(label: 'Export', onPressed: _exportStructureMd)),
                  ],
                ),
                const SizedBox(height: 22),

                _instructionSection(
                  title: 'Skills',
                  library: _skillsLibrary,
                  entries: _skills,
                  onUpdated: (updated) => setState(() => _skills = updated),
                ),
                const SizedBox(height: 22),

                _instructionSection(
                  title: 'Personas',
                  library: _personasLibrary,
                  entries: _personas,
                  onUpdated: (updated) => setState(() => _personas = updated),
                  onDeleted: (slug) async {
                    if (_agentConfig.defaultPersonaSlug == slug) {
                      setState(() => _agentConfig = _agentConfig.copyWith(clearPersona: true));
                      final prefs = await SharedPreferences.getInstance();
                      await _agentConfig.save(prefs);
                    }
                  },
                ),
                if (_personasLibrary != null) ...[
                  const SizedBox(height: 8),
                  Text('Default persona', style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 0.6)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.fg, width: 2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: _agentConfig.defaultPersonaSlug,
                        isExpanded: true,
                        dropdownColor: AppColors.bg,
                        style: appBody(size: 13),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('None')),
                          for (final p in _personas) DropdownMenuItem<String?>(value: p.slug, child: Text(p.name)),
                        ],
                        onChanged: (slug) => setState(() {
                          _agentConfig = _agentConfig.copyWith(defaultPersonaSlug: slug, clearPersona: slug == null);
                        }),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 22),

                Text('Guardrails', style: appHeading(size: 14, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                appBorderedField(
                  controller: _guardrailsController,
                  hint: 'One rule per line, always applied',
                  maxLines: 4,
                ),
                const SizedBox(height: 22),

                appPrimaryButton(label: 'Save', onPressed: _save),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _patController.dispose();
    _endpointController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _headersController.dispose();
    _guardrailsController.dispose();
    _modelBusyTimer?.cancel();
    super.dispose();
  }
}
