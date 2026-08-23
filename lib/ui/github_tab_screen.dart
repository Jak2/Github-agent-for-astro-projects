// lib/ui/github_tab_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chat/pending_file_handoff.dart';
import '../chat/save_path_resolver.dart';
import '../chat/slash_command.dart';
import '../chat/structuring_prompt.dart';
import '../engine/engine_factory.dart';
import '../engine/llm_engine.dart';
import '../engine/on_device_llama_engine.dart';
import '../files/file_tree.dart';
import '../git/repo_git_service.dart';
import '../git/repo_paths.dart';
import '../github/github_repo.dart';
import '../github/repo_browser_service.dart';
import '../instructions/instruction_library.dart';
import '../secrets/secret_store.dart';
import '../settings/agent_config.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

enum _SubScreen { repos, files, chat }

class _ChatMessage {
  final String text;
  final bool fromUser;
  const _ChatMessage(this.text, {required this.fromUser});
}

class GithubTabScreen extends StatefulWidget {
  final SecretStore secretStore;
  const GithubTabScreen({super.key, required this.secretStore});

  @override
  State<GithubTabScreen> createState() => _GithubTabScreenState();
}

class _GithubTabScreenState extends State<GithubTabScreen> {
  _SubScreen _subScreen = _SubScreen.repos;

  // --- repos state ---
  List<GithubRepo>? _repos;
  String? _reposError;
  String? _cloningFullName;
  Directory? _reposRoot;
  Set<String> _alreadyClonedFullNames = {};

  // --- files state ---
  GithubRepo? _activeRepo;
  Directory? _activeRepoDir;
  FileTreeNode? _fileRoot;

  // --- chat state ---
  String? _activeFilePath;
  String? _activeFileContent;
  final List<_ChatMessage> _chatMessages = [];
  final List<String> _refinements = [];
  final _chatInputController = TextEditingController();
  LlmEngine? _engine;
  String _structureRules = '';
  String? _latestStructuredContent;
  String? _resolvedSavePath;
  bool _chatBusy = false;
  InstructionLibrary? _skillsLibrary;
  InstructionLibrary? _personasLibrary;
  AgentConfig _agentConfig = const AgentConfig();
  String? _activePersonaSlug;
  String? _pendingSkillSlug;
  Timer? _loadTimer;
  int _loadElapsedSeconds = 0;
  bool _onDeviceModelLoaded = false;
  String? _toast;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _loadRepos();
    _consumePendingHandoffIfAny();
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _toastTimer?.cancel();
    _chatInputController.dispose();
    super.dispose();
  }

  Future<void> _loadRepos() async {
    final reposRoot = await getApplicationDocumentsDirectory();
    try {
      final result = await loadReposWithCloneStatus(secretStore: widget.secretStore, reposRoot: reposRoot);
      if (!mounted) return;
      setState(() {
        _repos = result.repos;
        _reposRoot = reposRoot;
        _alreadyClonedFullNames = result.alreadyClonedFullNames;
      });
    } on NoGithubTokenException {
      if (mounted) setState(() => _reposError = 'Add a GitHub Personal Access Token in Config first.');
    } catch (e) {
      if (mounted) setState(() => _reposError = 'Failed to load repos: $e');
    }
  }

  Future<void> _openRepo(GithubRepo repo, Directory dir) async {
    final tree = await buildFileTree(dir);
    if (!mounted) return;
    setState(() {
      _activeRepo = repo;
      _activeRepoDir = dir;
      _fileRoot = tree;
      _subScreen = _SubScreen.files;
    });
  }

  Future<void> _tapRepo(GithubRepo repo) async {
    if (_cloningFullName != null) return;
    final reposRoot = _reposRoot ?? await getApplicationDocumentsDirectory();
    final dir = await repoDirectory(reposRoot, repo.fullName);
    if (await dir.exists()) {
      await _openRepo(repo, dir);
      return;
    }
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('GitHub Personal Access Token missing. Add one in Config.'),
        ));
      }
      return;
    }
    setState(() => _cloningFullName = repo.fullName);
    try {
      final root = await getApplicationDocumentsDirectory();
      final service = RepoGitService(reposRoot: root);
      final dir = await service.cloneRepo(repo: repo, token: token);
      if (!mounted) return;
      setState(() => _alreadyClonedFullNames = {..._alreadyClonedFullNames, repo.fullName});
      await _openRepo(repo, dir);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Clone failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _cloningFullName = null);
    }
  }

  Future<void> _openFile(FileTreeNode node) async {
    final dir = _activeRepoDir;
    if (dir == null) return;
    String content;
    try {
      content = await File('${dir.path}/${node.relativePath}').readAsString();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read file: $e')));
      }
      return;
    }
    if (!mounted) return;
    _startStructuringChat(
      repo: _activeRepo!,
      repoDir: dir,
      relativePath: node.relativePath,
      content: content,
    );
    await _initChat();
  }

  void _startStructuringChat({
    required GithubRepo repo,
    required Directory repoDir,
    required String relativePath,
    required String content,
  }) {
    setState(() {
      _activeRepo = repo;
      _activeRepoDir = repoDir;
      _activeFilePath = relativePath;
      _activeFileContent = content;
      _chatMessages.clear();
      _refinements.clear();
      _latestStructuredContent = null;
      _resolvedSavePath = null;
      _activePersonaSlug = null;
      _pendingSkillSlug = null;
      _onDeviceModelLoaded = false;
      _subScreen = _SubScreen.chat;
    });
  }

  void _consumePendingHandoffIfAny() {
    final pending = PendingFileHandoff.instance.consume();
    if (pending == null) return;
    _startStructuringChat(
      repo: pending.repo,
      repoDir: pending.repoDir,
      relativePath: pending.relativePath,
      content: pending.content,
    );
    _initChat();
  }

  @override
  void didUpdateWidget(covariant GithubTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _consumePendingHandoffIfAny();
  }

  void _goBackToRepos() => setState(() => _subScreen = _SubScreen.repos);
  void _goBackToFiles() => setState(() => _subScreen = _SubScreen.files);

  void _showToast(String message) {
    setState(() => _toast = message);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<void> _initChat() async {
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
        ? await DefaultAssetBundle.of(context).loadString('assets/structure.md')
        : await File(settings.structureMdOverridePath).readAsString();
    if (!mounted) return;
    if (engine == null) {
      setState(() {
        _chatMessages.add(const _ChatMessage(
          'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
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
    setState(() => _chatBusy = true);
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
        if (personaContent == null) _activePersonaSlug = null;
      }
      final skillContent =
          _pendingSkillSlug != null ? await _skillsLibrary?.contentFor(_pendingSkillSlug!) : null;
      _pendingSkillSlug = null;

      final prompt = buildStructuringPrompt(
        structureRules: _structureRules,
        sourceContent: _activeFileContent ?? '',
        refinementRequests: _refinements,
        guardrails: _agentConfig.guardrails,
        personaContent: personaContent,
        skillContent: skillContent,
      );
      final result = await _engine!.generate(prompt);
      if (isFirstOnDeviceLoad) _onDeviceModelLoaded = true;
      setState(() {
        _latestStructuredContent = result;
        _chatMessages.add(_ChatMessage(result, fromUser: false));
      });
    } catch (e) {
      setState(() => _chatMessages.add(_ChatMessage('Generation failed: $e', fromUser: false)));
    } finally {
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() => _chatBusy = false);
    }
  }

  Future<void> _handleSlashCommand(SlashCommand command, String rawText) async {
    setState(() => _chatMessages.add(_ChatMessage(rawText, fromUser: true)));
    if (command is SkillCommand) {
      final content = await _skillsLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _chatMessages.add(_ChatMessage('No skill named "${command.slug}".', fromUser: false)));
        return;
      }
      _pendingSkillSlug = command.slug;
      setState(() => _chatMessages
          .add(_ChatMessage('Applying skill "${command.slug}" to the next generation.', fromUser: false)));
      if (_engine != null) await _generate();
      return;
    }
    if (command is PersonaCommand) {
      final content = await _personasLibrary?.contentFor(command.slug);
      if (content == null) {
        setState(() => _chatMessages.add(_ChatMessage('No persona named "${command.slug}".', fromUser: false)));
        return;
      }
      setState(() {
        _activePersonaSlug = command.slug;
        _chatMessages.add(_ChatMessage('Persona switched to "${command.slug}" for this session.', fromUser: false));
      });
    }
  }

  void _sendChat() {
    final text = _chatInputController.text.trim();
    if (text.isEmpty) return;
    _chatInputController.clear();

    final command = parseSlashCommand(text);
    if (command != null) {
      _handleSlashCommand(command, text);
      return;
    }

    final path = _activeFilePath ?? '';
    final looksLikePathInstruction =
        RegExp(r'\b(save|put|store|write)\b', caseSensitive: false).hasMatch(text);
    final resolved =
        looksLikePathInstruction ? resolveSavePath(instruction: text, sourceRelativePath: path) : null;
    setState(() {
      _chatMessages.add(_ChatMessage(text, fromUser: true));
      if (resolved != null) {
        _resolvedSavePath = resolved;
        _chatMessages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
      } else {
        _refinements.add(text);
      }
    });

    if (resolved == null) {
      if (_engine == null) {
        setState(() => _chatMessages.add(const _ChatMessage(
              'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
              fromUser: false,
            )));
      } else {
        _generate();
      }
    }
  }

  List<Widget> _folderTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      if (!child.isDirectory) continue;
      tiles.add(InkWell(
        onTap: () => _pickSaveFolder(child),
        child: Padding(
          padding: EdgeInsets.fromLTRB(18 + depth * 16.0, 12, 18, 12),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 16, color: AppColors.fg),
              const SizedBox(width: 10),
              Text(child.name, style: appMono(size: 13)),
            ],
          ),
        ),
      ));
      tiles.addAll(_folderTiles(child, depth + 1));
    }
    return tiles;
  }

  void _pickSaveFolder(FileTreeNode node) {
    final resolved = resolveSavePath(
      instruction: '${node.relativePath}/',
      sourceRelativePath: _activeFilePath ?? '',
    );
    Navigator.of(context).pop();
    if (resolved == null) return;
    setState(() {
      _resolvedSavePath = resolved;
      _chatMessages.add(_ChatMessage('Save path set to: $resolved', fromUser: false));
    });
  }

  Future<void> _browseSaveFolder() async {
    final dir = _activeRepoDir;
    if (dir == null) return;
    final root = await buildFileTree(dir);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: AppColors.fg, width: 3),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Choose a folder', style: appHeading(size: 15, weight: FontWeight.w700)),
              ),
            ),
            Flexible(child: ListView(shrinkWrap: true, children: _folderTiles(root, 0))),
          ],
        ),
      ),
    );
  }

  Future<void> _pushChat() async {
    final content = _latestStructuredContent;
    final savePath = _resolvedSavePath;
    if (content == null || savePath == null) {
      _showToast('Generate a result and set a save path (via chat) before pushing.');
      return;
    }
    final dir = _activeRepoDir;
    if (dir == null) return;
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null) {
      if (mounted) _showToast('GitHub Personal Access Token missing. Add one in Config.');
      return;
    }
    setState(() => _chatBusy = true);
    try {
      final service = RepoGitService(reposRoot: dir);
      await service.commitAndPush(
        repoDir: dir,
        relativeFilePath: savePath,
        content: content,
        commitMessage: 'Add structured content at $savePath',
        token: token,
      );
      if (mounted) _showToast('Pushed successfully');
    } catch (e) {
      if (mounted) _showToast('Push failed: $e');
    } finally {
      if (mounted) setState(() => _chatBusy = false);
    }
  }

  Widget _reposBody() {
    if (_reposError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_reposError!, style: appBody(color: AppColors.muted), textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() => _reposError = null);
                _loadRepos();
              },
              child: Text('Retry', style: appBody(color: AppColors.fg, weight: FontWeight.w600)),
            ),
          ],
        ),
      );
    }
    if (_repos == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.fg));
    }
    return ListView(
      children: [
        for (final r in _repos!)
          _RepoRow(
            repo: r,
            isCloning: _cloningFullName == r.fullName,
            isCloned: _alreadyClonedFullNames.contains(r.fullName) && _cloningFullName != r.fullName,
            onTap: _cloningFullName != null ? null : () => _tapRepo(r),
          ),
      ],
    );
  }

  List<Widget> _fileTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      tiles.add(InkWell(
        onTap: child.isDirectory ? null : () => _openFile(child),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16 + depth * 16.0, 10, 16, 10),
          child: Row(
            children: [
              Icon(
                child.isDirectory ? Icons.folder_outlined : Icons.description_outlined,
                size: 16,
                color: child.isDirectory ? AppColors.fg : AppColors.muted,
              ),
              const SizedBox(width: 10),
              Text(child.name, style: appMono(size: 13)),
            ],
          ),
        ),
      ));
      if (child.isDirectory) tiles.addAll(_fileTiles(child, depth + 1));
    }
    return tiles;
  }

  Widget _filesBody() {
    final root = _fileRoot;
    return Column(
      children: [
        SizedBox(
          height: 60,
          child: Row(
            children: [
              const SizedBox(width: 16),
              appIconCircleButton(icon: Icons.arrow_back, onPressed: _goBackToRepos),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _activeRepo?.fullName ?? '',
                  style: appMono(size: 14, weight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(color: AppColors.fg, thickness: 2, height: 2),
        Expanded(
          child: root == null
              ? const Center(child: CircularProgressIndicator(color: AppColors.fg))
              : ListView(children: _fileTiles(root, 0)),
        ),
      ],
    );
  }

  Widget _chatBody() {
    final activePersona = _activePersonaSlug;
    return Stack(
      children: [
        Column(
          children: [
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  appIconCircleButton(icon: Icons.arrow_back, onPressed: _goBackToFiles),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _activeFilePath ?? '',
                      style: appMono(size: 13.5, weight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.fg, thickness: 2, height: 2),
            if (activePersona != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.fg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Persona: $activePersona',
                      style: appMono(size: 10, color: AppColors.bg).copyWith(letterSpacing: 0.5),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _chatMessages.length + (_chatBusy ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _chatMessages.length) {
                    if (_loadTimer != null) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'Loading model & generating… ${_loadElapsedSeconds}s',
                          style: appMono(size: 12, color: AppColors.muted),
                        ),
                      );
                    }
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: LinearProgressIndicator(color: AppColors.fg, backgroundColor: AppColors.divider),
                    );
                  }
                  final m = _chatMessages[index];
                  return appChatBubble(text: m.text, fromUser: m.fromUser, mono: !m.fromUser);
                },
              ),
            ),
            if (_resolvedSavePath != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppColors.surfaceMuted,
                child: Row(
                  children: [
                    Text('Will push to ', style: appBody(size: 11, color: AppColors.muted)),
                    Text(_resolvedSavePath!, style: appMono(size: 11.5, weight: FontWeight.w600)),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  appIconCircleButton(icon: Icons.folder_outlined, onPressed: _chatBusy ? null : _browseSaveFolder),
                  const SizedBox(width: 8),
                  Expanded(
                    child: appBorderedField(
                      controller: _chatInputController,
                      hint: 'Refine, or say "save it in docs/posts/"',
                    ),
                  ),
                  const SizedBox(width: 8),
                  appIconCircleButton(icon: Icons.arrow_forward, onPressed: _chatBusy ? null : _sendChat, filled: true),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: appPrimaryButton(
                label: _chatBusy ? 'Pushing…' : 'Push to repo',
                onPressed: _chatBusy ? null : _pushChat,
              ),
            ),
          ],
        ),
        if (_toast != null)
          Positioned(
            bottom: 90,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: AppColors.fg, borderRadius: BorderRadius.circular(999)),
              child: Text(_toast!, textAlign: TextAlign.center, style: appBody(size: 12.5, color: AppColors.bg)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _subScreen == _SubScreen.repos,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_subScreen == _SubScreen.chat) {
          _goBackToFiles();
        } else if (_subScreen == _SubScreen.files) {
          _goBackToRepos();
        }
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: switch (_subScreen) {
            _SubScreen.repos => _reposBody(),
            _SubScreen.files => _filesBody(),
            _SubScreen.chat => _chatBody(),
          },
        ),
      ),
    );
  }
}

class _RepoRow extends StatelessWidget {
  final GithubRepo repo;
  final bool isCloning;
  final bool isCloned;
  final VoidCallback? onTap;

  const _RepoRow({required this.repo, required this.isCloning, required this.isCloned, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider, width: 2)),
        ),
        child: Row(
          children: [
            if (isCloning)
              const SizedBox(
                width: 36,
                height: 36,
                child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg))),
              )
            else
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.fg, width: 2),
                  borderRadius: BorderRadius.circular(10),
                  color: isCloned ? AppColors.fg : AppColors.bg,
                ),
                child: Icon(
                  isCloned ? Icons.folder_open : Icons.download,
                  size: 16,
                  color: isCloned ? AppColors.bg : AppColors.fg,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(repo.fullName, style: appMono(size: 13.5), overflow: TextOverflow.ellipsis),
                  if (isCloned)
                    Text('Already cloned — tap to open', style: appBody(size: 11, color: AppColors.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
