// lib/ui/chat_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chat/save_path_resolver.dart';
import '../chat/slash_command.dart';
import '../chat/structuring_prompt.dart';
import '../engine/engine_factory.dart';
import '../engine/llm_engine.dart';
import '../engine/on_device_llama_engine.dart';
import '../files/file_tree.dart';
import '../git/repo_git_service.dart';
import '../github/github_repo.dart';
import '../instructions/instruction_library.dart';
import '../secrets/secret_store.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';

class _ChatMessage {
  final String text;
  final bool fromUser;
  const _ChatMessage(this.text, {required this.fromUser});
}

class ChatScreen extends StatefulWidget {
  final GithubRepo repo;
  final Directory repoDir;
  final SecretStore secretStore;
  final String sourceRelativePath;
  final String sourceContent;

  const ChatScreen({
    super.key,
    required this.repo,
    required this.repoDir,
    required this.secretStore,
    required this.sourceRelativePath,
    required this.sourceContent,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_ChatMessage> _messages = [];
  final List<String> _refinements = [];
  final _inputController = TextEditingController();
  LlmEngine? _engine;
  String _structureRules = '';
  String? _latestStructuredContent;
  String? _resolvedSavePath;
  bool _busy = false;
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  AgentConfig _agentConfig = const AgentConfig();
  String? _activePersonaSlug; // session-local override; never persisted
  String? _pendingSkillSlug; // one-time, cleared after next generation
  Timer? _loadTimer;
  int _loadElapsedSeconds = 0;
  bool _onDeviceModelLoaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final assetBundle = DefaultAssetBundle.of(context);
    final prefs = await SharedPreferences.getInstance();
    final docs = await getApplicationDocumentsDirectory();
    _skillsLibrary = InstructionLibrary(root: Directory('${docs.path}/skills'));
    _personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
    _agentConfig = await AgentConfig.load(prefs);
    _activePersonaSlug = _agentConfig.defaultPersonaSlug;
    var settings = await EngineSettings.load(prefs);
    final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';
    settings = settings.copyWith(cloudApiKey: apiKey);
    final engine = buildEngine(settings);
    _structureRules = settings.structureMdOverridePath.isEmpty
        ? await assetBundle.loadString('assets/structure.md')
        : await File(settings.structureMdOverridePath).readAsString();
    if (!mounted) return;
    if (engine == null) {
      setState(() {
        _messages.add(const _ChatMessage(
          'No LLM configured. Go to Settings and set up a Cloud API or On-device engine first.',
          fromUser: false,
        ));
      });
      return;
    }
    _engine = engine;
    await _generate();
  }

  Future<void> _generate() async {
    if (_engine == null) return;
    final isFirstOnDeviceLoad = _engine is OnDeviceLlamaEngine && !_onDeviceModelLoaded;
    setState(() => _busy = true);
    if (isFirstOnDeviceLoad) {
      _loadElapsedSeconds = 0;
      _loadTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _loadElapsedSeconds++);
      });
    }
    try {
      String? personaContent;
      if (_activePersonaSlug != null) {
        personaContent = await _personasLibrary?.contentFor(_activePersonaSlug!);
        if (personaContent == null) _activePersonaSlug = null; // fail safe: deleted since selection
      }

      final skillContent =
          _pendingSkillSlug != null ? await _skillsLibrary?.contentFor(_pendingSkillSlug!) : null;
      _pendingSkillSlug = null; // one-time use, cleared regardless of hit/miss

      final prompt = buildStructuringPrompt(
        structureRules: _structureRules,
        sourceContent: widget.sourceContent,
        refinementRequests: _refinements,
        guardrails: _agentConfig.guardrails,
        personaContent: personaContent,
        skillContent: skillContent,
      );
      final result = await _engine!.generate(prompt);
      if (isFirstOnDeviceLoad) _onDeviceModelLoaded = true;
      setState(() {
        _latestStructuredContent = result;
        _messages.add(_ChatMessage(result, fromUser: false));
      });
    } catch (e) {
      setState(() => _messages.add(_ChatMessage('Generation failed: $e', fromUser: false)));
    } finally {
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() => _busy = false);
    }
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();

    final command = parseSlashCommand(text);
    if (command != null) {
      _handleSlashCommand(command, text);
      return;
    }

    final looksLikePathInstruction =
        RegExp(r'\b(save|put|store|write)\b', caseSensitive: false).hasMatch(text);
    final resolved = looksLikePathInstruction
        ? resolveSavePath(instruction: text, sourceRelativePath: widget.sourceRelativePath)
        : null;
    setState(() {
      _messages.add(_ChatMessage(text, fromUser: true));
      if (resolved != null) {
        _resolvedSavePath = resolved;
        _messages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
      } else {
        _refinements.add(text);
      }
    });

    if (resolved == null) {
      if (_engine == null) {
        setState(() => _messages.add(const _ChatMessage(
              'No LLM configured. Go to Settings and set up a Cloud API or On-device engine first.',
              fromUser: false,
            )));
      } else {
        _generate();
      }
    }
  }

  Future<void> _handleSlashCommand(SlashCommand command, String rawText) async {
    setState(() => _messages.add(_ChatMessage(rawText, fromUser: true)));

    if (command is SkillCommand) {
      final content = await _skillsLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _messages.add(_ChatMessage('No skill named "${command.slug}".', fromUser: false)));
        return;
      }
      _pendingSkillSlug = command.slug;
      setState(() => _messages
          .add(_ChatMessage('Applying skill "${command.slug}" to the next generation.', fromUser: false)));
      if (_engine != null) await _generate();
      return;
    }

    if (command is PersonaCommand) {
      final content = await _personasLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _messages.add(_ChatMessage('No persona named "${command.slug}".', fromUser: false)));
        return;
      }
      setState(() {
        _activePersonaSlug = command.slug;
        _messages.add(_ChatMessage('Persona switched to "${command.slug}" for this session.', fromUser: false));
      });
    }
  }

  List<Widget> _folderTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      if (!child.isDirectory) continue;
      tiles.add(Padding(
        padding: EdgeInsets.only(left: depth * 16.0),
        child: ListTile(
          leading: const Icon(Icons.folder),
          title: Text(child.name),
          onTap: () => _pickSaveFolder(child),
        ),
      ));
      tiles.addAll(_folderTiles(child, depth + 1));
    }
    return tiles;
  }

  void _pickSaveFolder(FileTreeNode node) {
    final resolved = resolveSavePath(
      instruction: '${node.relativePath}/',
      sourceRelativePath: widget.sourceRelativePath,
    );
    Navigator.of(context).pop();
    if (resolved == null) return;
    setState(() {
      _resolvedSavePath = resolved;
      _messages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
    });
  }

  Future<void> _browseSaveFolder() async {
    final root = await buildFileTree(widget.repoDir);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: _folderTiles(root, 0),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _push() async {
    final content = _latestStructuredContent;
    final savePath = _resolvedSavePath;
    if (content == null || savePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Generate a result and set a save path (via chat) before pushing.'),
      ));
      return;
    }
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('GitHub Personal Access Token missing. Add one in Settings.'),
        ));
      }
      return;
    }

    setState(() => _busy = true);
    try {
      // reposRoot is unused by commitAndPush in this path (it only matters for cloneRepo).
      final service = RepoGitService(reposRoot: widget.repoDir);
      await service.commitAndPush(
        repoDir: widget.repoDir,
        relativeFilePath: savePath,
        content: content,
        commitMessage: 'Add structured content at $savePath',
        token: token,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pushed successfully')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Push failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.sourceRelativePath)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                return Align(
                  alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: m.fromUser ? Colors.blue[100] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(m.text),
                  ),
                );
              },
            ),
          ),
          if (_busy && _loadTimer != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Loading model & generating… ${_loadElapsedSeconds}s'),
            )
          else if (_busy)
            const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Choose save folder',
                  onPressed: _busy ? null : _browseSaveFolder,
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      hintText: 'Refine, or say "save it in docs/posts/"',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _busy ? null : _send),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _push,
                child: const Text('Push to repo'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
