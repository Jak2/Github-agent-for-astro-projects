// lib/ui/file_browser_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import '../files/file_tree.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import 'chat_screen.dart';

class FileBrowserScreen extends StatefulWidget {
  final GithubRepo repo;
  final Directory repoDir;
  final SecretStore secretStore;

  const FileBrowserScreen({
    super.key,
    required this.repo,
    required this.repoDir,
    required this.secretStore,
  });

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  FileTreeNode? _root;

  @override
  void initState() {
    super.initState();
    buildFileTree(widget.repoDir).then((tree) => setState(() => _root = tree));
  }

  Future<void> _openFile(FileTreeNode node) async {
    String content;
    try {
      content = await File('${widget.repoDir.path}/${node.relativePath}').readAsString();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not read file: $e')));
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        repo: widget.repo,
        repoDir: widget.repoDir,
        secretStore: widget.secretStore,
        sourceRelativePath: node.relativePath,
        sourceContent: content,
      ),
    ));
  }

  List<Widget> _tiles(FileTreeNode node, int depth) {
    final tiles = <Widget>[];
    for (final child in node.children) {
      tiles.add(Padding(
        padding: EdgeInsets.only(left: depth * 16.0),
        child: ListTile(
          leading: Icon(child.isDirectory ? Icons.folder : Icons.description),
          title: Text(child.name),
          onTap: child.isDirectory ? null : () => _openFile(child),
        ),
      ));
      if (child.isDirectory) {
        tiles.addAll(_tiles(child, depth + 1));
      }
    }
    return tiles;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.repo.fullName)),
      body: _root == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: _tiles(_root!, 0)),
    );
  }
}
