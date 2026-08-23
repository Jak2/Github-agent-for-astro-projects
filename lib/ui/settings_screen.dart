// lib/ui/settings_screen.dart
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../instructions/instruction_library.dart';
import '../secrets/secret_store.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';

class SettingsScreen extends StatefulWidget {
  final SecretStore secretStore;
  const SettingsScreen({super.key, required this.secretStore});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
        title: Text(existing == null ? 'Add' : 'Edit'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                enabled: existing == null, // slug is derived from name at creation only
              ),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              TextField(
                controller: contentController,
                decoration: const InputDecoration(labelText: 'Content (Markdown)'),
                maxLines: 6,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
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
        const SizedBox(height: 24),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        for (final entry in entries)
          ListTile(
            title: Text(entry.name),
            subtitle: Text(entry.description),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _showEntryEditor(
                    library: library,
                    onUpdated: onUpdated,
                    existing: entry,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () async {
                    await library.delete(entry.slug);
                    onDeleted?.call(entry.slug);
                    onUpdated(await library.list());
                  },
                ),
              ],
            ),
          ),
        ElevatedButton(
          onPressed: () => _showEntryEditor(library: library, onUpdated: onUpdated),
          child: const Text('Add'),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _patController,
            decoration: const InputDecoration(labelText: 'GitHub Personal Access Token'),
            obscureText: true,
          ),
          const SizedBox(height: 24),
          const Text('LLM Engine', style: TextStyle(fontWeight: FontWeight.bold)),
          RadioListTile<EngineChoice>(
            title: const Text('Cloud API'),
            value: EngineChoice.cloud,
            groupValue: _settings.choice,
            onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
          ),
          if (_settings.choice == EngineChoice.cloud) ...[
            TextField(
              controller: _endpointController,
              decoration: const InputDecoration(labelText: 'Cloud endpoint URL'),
            ),
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'Cloud API key'),
              obscureText: true,
            ),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(labelText: 'Model name (optional)'),
            ),
            TextField(
              controller: _headersController,
              decoration: const InputDecoration(labelText: 'Extra headers (Name: value per line)'),
              maxLines: 3,
            ),
          ],
          RadioListTile<EngineChoice>(
            title: const Text('On-device (.gguf)'),
            value: EngineChoice.onDevice,
            groupValue: _settings.choice,
            onChanged: (v) => setState(() => _settings = _settings.copyWith(choice: v)),
          ),
          if (_settings.choice == EngineChoice.onDevice) ...[
            ListTile(
              title: Text(_settings.onDeviceModelPath.isEmpty
                  ? 'No model selected'
                  : _settings.onDeviceModelPath),
              trailing: ElevatedButton(onPressed: _pickOnDeviceModel, child: const Text('Choose file')),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Structuring rules (structure.md)', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(_structureMdOverridePath ?? 'Using bundled default'),
          Row(
            children: [
              ElevatedButton(onPressed: _importStructureMd, child: const Text('Import')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _exportStructureMd, child: const Text('Export')),
            ],
          ),
          _instructionSection(
            title: 'Skills',
            library: _skillsLibrary,
            entries: _skills,
            onUpdated: (updated) => setState(() => _skills = updated),
          ),
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
            DropdownButton<String?>(
              value: _agentConfig.defaultPersonaSlug,
              hint: const Text('Default persona'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None')),
                for (final p in _personas) DropdownMenuItem<String?>(value: p.slug, child: Text(p.name)),
              ],
              onChanged: (slug) => setState(() {
                _agentConfig = _agentConfig.copyWith(defaultPersonaSlug: slug, clearPersona: slug == null);
              }),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Guardrails', style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            controller: _guardrailsController,
            decoration: const InputDecoration(hintText: 'One rule per line, always applied'),
            maxLines: 4,
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _guardrailsController.dispose();
    super.dispose();
  }
}
