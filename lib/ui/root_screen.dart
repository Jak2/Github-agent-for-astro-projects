// lib/ui/root_screen.dart
import 'package:flutter/material.dart';

import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';
import 'repos_screen.dart';
import 'settings_screen.dart';

/// Two tabs and nothing else: the repositories, and the account they come
/// from. Every other surface in this app is a popup over one of them.
class RootScreen extends StatefulWidget {
  final SecretStore secretStore;
  const RootScreen({super.key, required this.secretStore});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tabIndex = 0;

  /// Bumped whenever the token or identity changes, so the repos tab rebuilds
  /// from scratch instead of showing the previous account's list.
  int _accountEpoch = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      ReposScreen(
        key: ValueKey(_accountEpoch),
        secretStore: widget.secretStore,
        onOpenSettings: () => setState(() => _tabIndex = 1),
      ),
      SettingsScreen(
        secretStore: widget.secretStore,
        onAccountChanged: () => setState(() => _accountEpoch++),
      ),
    ];
    final navItems = [
      (icon: Icons.folder_copy_outlined, label: 'Repos'),
      (icon: Icons.tune, label: 'Settings'),
    ];

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: tabs),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.fg, width: 2)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              for (var i = 0; i < navItems.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _tabIndex = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            navItems[i].icon,
                            size: 21,
                            color: _tabIndex == i ? AppColors.fg : AppColors.muted,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            navItems[i].label,
                            style: appMono(size: 10, color: _tabIndex == i ? AppColors.fg : AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
