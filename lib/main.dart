// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:git2dart/git2dart.dart';
import 'package:path_provider/path_provider.dart';
import 'instructions/instruction_library.dart';
import 'instructions/starter_personas.dart';
import 'secrets/secret_store.dart';
import 'ui/repo_list_screen.dart';
import 'ui/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlatformSpecific.initialize();
  final docs = await getApplicationDocumentsDirectory();
  final personasLibrary = InstructionLibrary(root: Directory('${docs.path}/personas'));
  await seedStarterPersonasIfEmpty(personasLibrary, rootBundle.loadString);
  runApp(const GitAgentApp());
}

class GitAgentApp extends StatelessWidget {
  const GitAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    final secretStore = SecureSecretStore();
    return MaterialApp(
      title: 'git_agent_app',
      home: HomeScreen(secretStore: secretStore),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final SecretStore secretStore;
  const HomeScreen({super.key, required this.secretStore});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('git_agent_app'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SettingsScreen(secretStore: secretStore),
            )),
          ),
        ],
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RepoListScreen(secretStore: secretStore),
          )),
          child: const Text('Browse your repositories'),
        ),
      ),
    );
  }
}
