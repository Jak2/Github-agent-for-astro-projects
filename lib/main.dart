// lib/main.dart
import 'package:flutter/material.dart';
import 'package:git2dart/git2dart.dart';

import 'secrets/secret_store.dart';
import 'theme/app_theme.dart';
import 'ui/root_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads libgit2 through the FFI bindings. Everything git in this app goes
  // through it, so a failure here is fatal by design.
  await PlatformSpecific.initialize();
  runApp(const PocketGitApp());
}

class PocketGitApp extends StatelessWidget {
  const PocketGitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketGit',
      theme: appThemeData(),
      home: RootScreen(secretStore: SecureSecretStore()),
    );
  }
}
