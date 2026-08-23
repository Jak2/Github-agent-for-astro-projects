// lib/main.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:git2dart/git2dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'instructions/instruction_library.dart';
import 'instructions/starter_personas.dart';
import 'secrets/secret_store.dart';
import 'theme/app_theme.dart';
import 'ui/onboarding_screen.dart';
import 'ui/root_screen.dart';

const _keyOnboarded = 'onboarded';

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
      theme: appThemeData(),
      home: _AppEntry(secretStore: secretStore),
    );
  }
}

class _AppEntry extends StatefulWidget {
  final SecretStore secretStore;
  const _AppEntry({required this.secretStore});

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool? _onboarded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _onboarded = prefs.getBool(_keyOnboarded) ?? false);
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyOnboarded, true);
    if (mounted) setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_onboarded!) {
      return OnboardingScreen(secretStore: widget.secretStore, onFinished: _finishOnboarding);
    }
    return RootScreen(secretStore: widget.secretStore);
  }
}
