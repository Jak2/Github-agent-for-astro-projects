// lib/ui/general_chat_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chat/pending_file_handoff.dart';
import '../chat/pinned_scope.dart';
import '../chat/prompt_budget.dart';
import '../chat/scoped_prompt.dart';
import '../engine/engine_factory.dart';
import '../engine/generation_event.dart';
import '../engine/llm_engine.dart';
import '../engine/on_device_llama_engine.dart' show kMaxPromptChars;
import '../files/file_tree.dart';
import '../git/repo_git_service.dart';
import '../git/repo_paths.dart';
import '../github/github_repo.dart';
import '../github/repo_browser_service.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';
import '../system/device_metrics.dart';
import '../theme/app_theme.dart';

sealed class _ChatItem {
  const _ChatItem();
}

class _TextItem extends _ChatItem {
  /// Mutable so a streaming reply can grow one bubble in place.
  String text;
  final bool fromUser;

  /// App-generated text (errors, setup prompts) rather than model output.
  /// Excluded from the prompt transcript: feeding failures back to the model
  /// makes every retry a little larger — observed growing 2325 -> 2365 -> 2399
  /// tokens across three failed sends — and asks it to explain its own errors.
  final bool isNotice;

  _TextItem(this.text, {required this.fromUser, this.isNotice = false});
}

class _RepoListItem extends _ChatItem {
  final List<GithubRepo> repos;
  final Set<String> alreadyClonedFullNames;
  _RepoListItem({required this.repos, required this.alreadyClonedFullNames});
}

class _FileListItem extends _ChatItem {
  final FileTreeNode root;
  _FileListItem(this.root);
}

class _FileActionsItem extends _ChatItem {
  final String relativePath;
  _FileActionsItem(this.relativePath);
}

class GeneralChatScreen extends StatefulWidget {
  final SecretStore secretStore;
  final void Function(int tabIndex) onSwitchTab;

  const GeneralChatScreen({super.key, required this.secretStore, required this.onSwitchTab});

  @override
  State<GeneralChatScreen> createState() => _GeneralChatScreenState();
}

class _GeneralChatScreenState extends State<GeneralChatScreen> {
  final List<_ChatItem> _items = [
    _TextItem(
      'Ask me anything about your repos. Tap the repo icon to browse and select one.',
      fromUser: false,
    ),
  ];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _busy = false;
  String _statusLine = '';
  StreamSubscription<GenerationEvent>? _genSub;
  _TextItem? _streamingReply;

  GithubRepo? _activeRepo;
  Directory? _activeRepoDir;
  FileTreeNode? _fileTree;
  String? _openFilePath;
  String? _openFileContent;
  String? _cloningFullName;

  /// Directories the user has unfolded, by relativePath. Display state only —
  /// renderFileTreeAsText still hands the LLM the whole tree.
  final Set<String> _expandedDirs = {};

  /// What the questions are aimed at. Null means the whole repo, unstated.
  PinnedScope? _pinned;

  final _metrics = DeviceMetrics();
  DeviceSnapshot? _snapshot;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _initEngine();
    _metrics.start(_onMetrics);
    // Stop polling while the app is backgrounded. ponytail: tab switches are
    // not covered — RootScreen keeps every tab alive in an IndexedStack, so
    // there is no visibility signal here without plumbing one through it, and
    // one /proc read per 1.5s is not what drains a phone.
    _lifecycle = AppLifecycleListener(
      onPause: _metrics.stop,
      onResume: () => _metrics.start(_onMetrics),
    );
  }

  @override
  void dispose() {
    _metrics.stop();
    _lifecycle?.dispose();
    _genSub?.cancel();
    _scrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  void _onMetrics(DeviceSnapshot? snapshot) {
    if (mounted) setState(() => _snapshot = snapshot);
  }

  /// Every insertion into the chat list goes through here, so whatever an
  /// action produced — a reply, a repo list, a file tree — is scrolled into
  /// view. Uniform by construction rather than special-cased per action.
  /// Call inside setState; the scroll runs after the frame that lays it out.
  void _append(_ChatItem item) {
    _items.add(item);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<LlmEngine?> _resolveEngine() async {
    final prefs = await SharedPreferences.getInstance();
    var settings = await EngineSettings.load(prefs);
    final apiKey = await widget.secretStore.read(secretKeyCloudApiKey) ?? '';
    settings = settings.copyWith(cloudApiKey: apiKey);
    return buildEngine(settings);
  }

  Future<void> _initEngine() async {
    final engine = await _resolveEngine();
    if (!mounted) return;
    if (engine == null) {
      setState(() {
        _append(_TextItem(
          'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
          fromUser: false, isNotice: true,
        ));
      });
    }
  }

  Future<void> _browseRepos() async {
    setState(() => _busy = true);
    try {
      final reposRoot = await getApplicationDocumentsDirectory();
      final result = await loadReposWithCloneStatus(secretStore: widget.secretStore, reposRoot: reposRoot);
      if (!mounted) return;
      setState(() {
        _append(_RepoListItem(repos: result.repos, alreadyClonedFullNames: result.alreadyClonedFullNames));
      });
    } on NoGithubTokenException {
      if (mounted) {
        setState(() => _append(_TextItem(
              'Add a GitHub Personal Access Token in Config first.',
              fromUser: false, isNotice: true,
            )));
      }
    } catch (e) {
      if (mounted) setState(() => _append(_TextItem('Failed to load repos: $e', fromUser: false, isNotice: true)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectRepo(GithubRepo repo, bool alreadyCloned) async {
    setState(() => _cloningFullName = alreadyCloned ? null : repo.fullName);
    try {
      final reposRoot = await getApplicationDocumentsDirectory();
      Directory dir = await repoDirectory(reposRoot, repo.fullName);
      final actuallyExists = await dir.exists();
      if (!actuallyExists) {
        final token = await widget.secretStore.read(secretKeyGithubPat);
        if (token == null) {
          if (mounted) {
            setState(() => _append(_TextItem(
                  'GitHub Personal Access Token missing. Add one in Config.',
                  fromUser: false, isNotice: true,
                )));
          }
          return;
        }
        final service = RepoGitService(reposRoot: reposRoot);
        dir = await service.cloneRepo(repo: repo, token: token);
      }
      final tree = await buildFileTree(dir);
      if (!mounted) return;
      setState(() {
        _activeRepo = repo;
        _activeRepoDir = dir;
        _fileTree = tree;
        _openFilePath = null;
        _openFileContent = null;
        _expandedDirs.clear(); // paths belonged to the previous repo
        _pinned = null; // so did the pin
        _append(_TextItem('Repo selected: ${repo.fullName}', fromUser: false));
      });
    } catch (e) {
      if (mounted) setState(() => _append(_TextItem('Failed to open repo: $e', fromUser: false, isNotice: true)));
    } finally {
      if (mounted) setState(() => _cloningFullName = null);
    }
  }

  void _browseFiles() {
    final tree = _fileTree;
    if (tree == null) return;
    setState(() => _append(_FileListItem(tree)));
  }

  void _tapFile(String relativePath) {
    setState(() => _append(_FileActionsItem(relativePath)));
  }

  /// Reads [relativePath] into the prompt's file section. Returns false, having
  /// already told the user, when it could not be read.
  Future<bool> _loadFile(String relativePath) async {
    final dir = _activeRepoDir;
    if (dir == null) return false;
    try {
      final content = await File('${dir.path}/$relativePath').readAsString();
      if (!mounted) return false;
      setState(() {
        _openFilePath = relativePath;
        _openFileContent = content;
      });
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _append(_TextItem('Could not read file: $e', fromUser: false, isNotice: true)));
      }
      return false;
    }
  }

  Future<void> _askAboutFile(String relativePath) async {
    if (!await _loadFile(relativePath) || !mounted) return;
    setState(() => _append(_TextItem('Opened $relativePath — ask me anything about it.', fromUser: false)));
  }

  /// Pinning the already-pinned entity unpins it — the same icon both ways.
  Future<void> _togglePin(PinnedScope scope) async {
    if (_pinned == scope) {
      setState(() {
        _pinned = null;
        // The pin is what loaded this file; drop it with the pin.
        if (scope.kind == PinKind.file && _openFilePath == scope.path) {
          _openFilePath = null;
          _openFileContent = null;
        }
        _append(_TextItem('Unpinned ${scope.label}.', fromUser: false, isNotice: true));
      });
      return;
    }
    if (scope.kind == PinKind.file) {
      // Unreadable file: _loadFile already said so, and no pin is set.
      if (!await _loadFile(scope.path)) return;
    } else {
      // A folder/repo pin is a tree slice; a file opened earlier must not ride
      // along, or "answer only about this folder" arrives with a stray file.
      setState(() {
        _openFilePath = null;
        _openFileContent = null;
      });
    }
    if (!mounted) return;
    setState(() {
      _pinned = scope;
      _append(_TextItem('Pinned: ${scope.label} — questions will focus here.', fromUser: false, isNotice: true));
    });
  }

  /// A repo can only be pinned once it is the active one, so pinning an
  /// unselected repo selects (cloning if needed) it first.
  Future<void> _togglePinRepo(GithubRepo repo, bool alreadyCloned) async {
    if (_activeRepo?.fullName != repo.fullName) {
      await _selectRepo(repo, alreadyCloned);
      // Selection failed — _selectRepo has already explained why.
      if (!mounted || _activeRepo?.fullName != repo.fullName) return;
    }
    await _togglePin(PinnedScope.repo(repo.fullName));
  }

  Future<void> _structureFile(String relativePath) async {
    final repo = _activeRepo;
    final dir = _activeRepoDir;
    if (repo == null || dir == null) return;
    try {
      final content = await File('${dir.path}/$relativePath').readAsString();
      PendingFileHandoff.instance.request(
        repo: repo,
        repoDir: dir,
        relativePath: relativePath,
        content: content,
      );
      widget.onSwitchTab(1);
    } catch (e) {
      if (mounted) setState(() => _append(_TextItem('Could not read file: $e', fromUser: false)));
    }
  }

  String _buildPrompt() {
    final repo = _activeRepo;
    final tree = _fileTree;

    var header = 'You are a helpful assistant. If the user wants to browse their '
        'GitHub repos, they can use the repo icon above.\n\n';
    var treeText = '';
    if (repo != null && tree != null) {
      final scoped = buildScopedContext(repoFullName: repo.fullName, tree: tree, pinned: _pinned);
      header = scoped.header;
      treeText = scoped.treeText;
      if (scoped.pinStale) {
        // The pinned path is gone. Fall back to the whole tree, but never
        // silently: drop the dead pin and say so in the chat.
        final label = _pinned!.label;
        _pinned = null;
        _append(_TextItem(
          'Pinned "$label" no longer exists in this repo — answering about the whole repository instead.',
          fromUser: false, isNotice: true,
        ));
      }
    }

    var fileSection = '';
    if (_openFilePath != null && _openFileContent != null) {
      fileSection = 'The user has opened this file for discussion:\n'
          '$_openFilePath\n---\n$_openFileContent\n---\n';
    }

    final transcript = <String>[
      for (final item in _items)
        if (item is _TextItem && !item.isNotice)
          '${item.fromUser ? "User" : "Assistant"}: ${item.text}',
    ];

    // The tree and the transcript both grow without bound, and an over-long
    // prompt is rejected outright ("Prompt token count exceeds batch
    // capacity") rather than degrading. Budget it before sending.
    return buildBudgetedPrompt(
      header: header,
      treeText: treeText,
      fileSection: fileSection,
      transcript: transcript,
      // Cue the model that it is the assistant's turn. Without this it
      // continues the transcript instead of answering — inventing the next
      // "User:" line and role-playing both sides. Pairs with kStopSequences in
      // the on-device engine, which cuts generation if it starts a turn anyway.
      turnCue: 'Assistant:',
      maxChars: kMaxPromptChars,
    );
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() => _append(_TextItem(text, fromUser: true)));

    final engine = await _resolveEngine();
    if (!mounted) return;
    if (engine == null) {
      setState(() => _append(_TextItem(
            'No LLM configured. Go to Config and set up a Cloud API or On-device engine first.',
            fromUser: false, isNotice: true,
          )));
      return;
    }
    // Built before the empty reply bubble is added so it isn't in the transcript.
    final prompt = _buildPrompt();

    // One growing bubble the tokens stream into.
    final reply = _TextItem('', fromUser: false);
    setState(() {
      _busy = true;
      _statusLine = 'starting…';
      _streamingReply = reply;
      _append(reply);
    });

    final buffer = StringBuffer();
    _genSub = engine.generateStream(prompt).listen(
      (event) {
        if (!mounted) return;
        setState(() {
          switch (event) {
            case GenerationStatus(:final stage):
              _statusLine = stage;
            case GenerationToken(:final text):
              buffer.write(text);
              reply.text = buffer.toString();
            case GenerationDone(:final fullText):
              reply.text = fullText.isEmpty ? buffer.toString() : fullText;
              _statusLine = '';
            case GenerationError(:final message):
              reply.text = 'Generation failed: $message';
              _statusLine = '';
          }
        });
        _scrollToBottom();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          reply.text = 'Generation failed: $e';
          _statusLine = '';
          _busy = false;
        });
        _scrollToBottom();
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _statusLine = '';
          if (reply.text.isEmpty) {
            // Never leave a blank bubble — that is the original bug's symptom.
            reply.text = 'The model returned no output.';
          }
        });
        _scrollToBottom();
      },
      cancelOnError: true,
    );
  }

  void _stopGeneration() {
    _genSub?.cancel();
    _genSub = null;
    final reply = _streamingReply;
    if (mounted) {
      setState(() {
        _busy = false;
        _statusLine = 'stopped';
        if (reply != null && reply.text.isEmpty) reply.text = 'Stopped before any output.';
      });
    }
  }

  void _toggleDir(String relativePath) {
    setState(() {
      if (!_expandedDirs.remove(relativePath)) _expandedDirs.add(relativePath);
    });
  }

  /// The pin toggle for one row. Its own gesture target, so tapping it on a
  /// folder row pins instead of folding — the row's InkWell never sees the tap.
  Widget _pinButton(PinnedScope scope, {VoidCallback? onTap}) {
    final pinned = _pinned == scope;
    return Tooltip(
      message: pinned ? 'Unpin ${scope.label}' : 'Pin ${scope.label} — the assistant will focus here',
      child: InkWell(
        onTap: onTap ?? () => _togglePin(scope),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Icon(
            pinned ? Icons.push_pin : Icons.push_pin_outlined,
            size: 15,
            color: pinned ? AppColors.fg : AppColors.muted,
            semanticLabel: pinned ? 'Unpin ${scope.label}' : 'Pin ${scope.label}',
          ),
        ),
      ),
    );
  }

  /// Folders start collapsed — every one of them, at every depth. A real repo
  /// tree is hundreds of rows fully expanded, which is what made this list
  /// unusable; starting shut means one screenful of top-level entries and the
  /// user opens only the branch they want.
  List<Widget> _fileTiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      final expanded = child.isDirectory && _expandedDirs.contains(child.relativePath);
      tiles.add(InkWell(
        onTap: child.isDirectory ? () => _toggleDir(child.relativePath) : () => _tapFile(child.relativePath),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12 + depth * 16.0, 8, 12, 8),
          child: Row(
            children: [
              // Files keep the same left edge as their sibling folders.
              SizedBox(
                width: 15,
                child: child.isDirectory
                    ? Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 15,
                        color: AppColors.fg,
                      )
                    : null,
              ),
              const SizedBox(width: 4),
              Icon(
                child.isDirectory ? Icons.folder_outlined : Icons.description_outlined,
                size: 15,
                color: child.isDirectory ? AppColors.fg : AppColors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(child.name, style: appMono(size: 12), overflow: TextOverflow.ellipsis),
              ),
              _pinButton(PinnedScope(
                kind: child.isDirectory ? PinKind.folder : PinKind.file,
                path: child.relativePath,
                label: child.name,
              )),
            ],
          ),
        ),
      ));
      if (expanded) tiles.addAll(_fileTiles(child, depth + 1));
    }
    return tiles;
  }

  /// Sits right above the input so the scope the next question lands in is
  /// impossible to miss. The X clears it.
  Widget _pinnedChip(PinnedScope scope) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.fg, width: 2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.push_pin, size: 13, color: AppColors.fg),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Pinned: ${scope.label}',
                      style: appMono(size: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Clear pin',
                    child: InkWell(
                      onTap: () => _togglePin(scope),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 13, color: AppColors.muted, semanticLabel: 'Clear pin'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// This app's own CPU and RAM. An em-dash means the reading was unavailable
  /// — never the last good value dressed up as live.
  Widget _metricsReadout() {
    // Device-relative, not the top-style per-process sum: 'CPU 633%'
    // is technically right and reads as a bug.
    final cpu = _snapshot?.cpuPercentOfDevice;
    final rssKb = _snapshot?.rssKb;
    final style = appMono(size: 11, color: AppColors.muted);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('CPU ${cpu == null ? '—' : '${cpu.round()}%'}', style: style),
        Text('RAM ${rssKb == null ? '—' : '${(rssKb / 1024).round()}MB'}', style: style),
      ],
    );
  }

  Widget _buildItem(_ChatItem item) {
    return switch (item) {
      _TextItem() => appChatBubble(text: item.text, fromUser: item.fromUser),
      _RepoListItem() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.fg, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (final r in item.repos)
                InkWell(
                  onTap: _cloningFullName != null
                      ? null
                      : () => _selectRepo(r, item.alreadyClonedFullNames.contains(r.fullName)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        if (_cloningFullName == r.fullName)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg),
                          )
                        else
                          Icon(
                            item.alreadyClonedFullNames.contains(r.fullName) ? Icons.folder_open : Icons.download,
                            size: 16,
                            color: AppColors.fg,
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(r.fullName, style: appMono(size: 12.5), overflow: TextOverflow.ellipsis),
                        ),
                        // Hidden mid-clone: pinning would race the checkout.
                        if (_cloningFullName == null)
                          _pinButton(
                            PinnedScope.repo(r.fullName),
                            onTap: () => _togglePinRepo(r, item.alreadyClonedFullNames.contains(r.fullName)),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      _FileListItem() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.fg, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(children: _fileTiles(item.root, 0)),
        ),
      _FileActionsItem() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.fg, width: 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.relativePath, style: appMono(size: 12.5, weight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: appSecondaryButton(
                      label: 'Ask about this file',
                      onPressed: () => _askAboutFile(item.relativePath),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: appSecondaryButton(
                      label: 'Structure this file',
                      onPressed: () => _structureFile(item.relativePath),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
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
                  Expanded(
                    child: Text(
                      'Assistant',
                      style: appHeading(size: 17, weight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _metricsReadout(),
                  const SizedBox(width: 10),
                  appIconCircleButton(icon: Icons.hub_outlined, onPressed: _busy ? null : _browseRepos),
                  const SizedBox(width: 8),
                  appIconCircleButton(
                    icon: Icons.folder_outlined,
                    onPressed: (_busy || _activeRepo == null) ? null : _browseFiles,
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
            const Divider(color: AppColors.fg, thickness: 2, height: 2),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _items.length + (_busy ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _items.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: LinearProgressIndicator(color: AppColors.fg, backgroundColor: AppColors.divider),
                    );
                  }
                  return _buildItem(_items[index]);
                },
              ),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _statusLine.isEmpty ? 'working…' : _statusLine,
                        style: appMono(size: 11, color: AppColors.muted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    appIconCircleButton(icon: Icons.stop, onPressed: _stopGeneration),
                  ],
                ),
              ),
            if (_pinned != null) _pinnedChip(_pinned!),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: appBorderedField(
                      controller: _inputController,
                      hint: 'Ask about your repos...',
                    ),
                  ),
                  const SizedBox(width: 8),
                  appIconCircleButton(icon: Icons.arrow_forward, onPressed: _busy ? null : _send, filled: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
