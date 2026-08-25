// lib/ui/general_chat_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../chat/pending_file_handoff.dart';
import '../engine/engine_factory.dart';
import '../engine/generation_event.dart';
import '../engine/llm_engine.dart';
import '../files/file_tree.dart';
import '../files/file_tree_text.dart';
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
  _TextItem(this.text, {required this.fromUser});
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
          fromUser: false,
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
              fromUser: false,
            )));
      }
    } catch (e) {
      if (mounted) setState(() => _append(_TextItem('Failed to load repos: $e', fromUser: false)));
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
                  fromUser: false,
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
        _append(_TextItem('Repo selected: ${repo.fullName}', fromUser: false));
      });
    } catch (e) {
      if (mounted) setState(() => _append(_TextItem('Failed to open repo: $e', fromUser: false)));
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

  Future<void> _askAboutFile(String relativePath) async {
    final dir = _activeRepoDir;
    if (dir == null) return;
    try {
      final content = await File('${dir.path}/$relativePath').readAsString();
      if (!mounted) return;
      setState(() {
        _openFilePath = relativePath;
        _openFileContent = content;
        _append(_TextItem('Opened $relativePath — ask me anything about it.', fromUser: false));
      });
    } catch (e) {
      if (mounted) setState(() => _append(_TextItem('Could not read file: $e', fromUser: false)));
    }
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
    final buffer = StringBuffer();
    final repo = _activeRepo;
    final tree = _fileTree;
    if (repo != null && tree != null) {
      buffer
        ..writeln('You are a helpful assistant answering questions about a GitHub repository.')
        ..writeln('Repository: ${repo.fullName}')
        ..writeln('File and folder structure:')
        ..writeln(renderFileTreeAsText(tree))
        ..writeln();
    } else {
      buffer
        ..writeln(
            'You are a helpful assistant. If the user wants to browse their GitHub repos, they can use the repo icon above.')
        ..writeln();
    }
    if (_openFilePath != null && _openFileContent != null) {
      buffer
        ..writeln('The user has opened this file for discussion:')
        ..writeln(_openFilePath)
        ..writeln('---')
        ..writeln(_openFileContent)
        ..writeln('---')
        ..writeln();
    }
    buffer.writeln('Conversation so far:');
    for (final item in _items) {
      if (item is _TextItem) {
        buffer.writeln('${item.fromUser ? "User" : "Assistant"}: ${item.text}');
      }
    }
    // Cue the model that it is the assistant's turn. Without this it continues
    // the transcript instead of answering — inventing the next "User:" line and
    // role-playing both sides. Pairs with kStopSequences in the on-device
    // engine, which cuts generation if it starts a new turn anyway.
    buffer.write('Assistant:');
    return buffer.toString();
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
            fromUser: false,
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
            ],
          ),
        ),
      ));
      if (expanded) tiles.addAll(_fileTiles(child, depth + 1));
    }
    return tiles;
  }

  /// This app's own CPU and RAM. An em-dash means the reading was unavailable
  /// — never the last good value dressed up as live.
  Widget _metricsReadout() {
    final cpu = _snapshot?.cpuPercent;
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
