// lib/ui/root_screen.dart
import 'package:flutter/material.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';
import 'config_screen.dart';
import 'general_chat_screen.dart';
import 'github_tab_screen.dart';

class RootScreen extends StatefulWidget {
  final SecretStore secretStore;
  const RootScreen({super.key, required this.secretStore});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const GeneralChatScreen(),
      GithubTabScreen(secretStore: widget.secretStore),
      ConfigScreen(secretStore: widget.secretStore),
    ];
    final navItems = [
      (icon: Icons.chat_bubble_outline, label: 'Chat'),
      (icon: Icons.hub_outlined, label: 'GitHub'),
      (icon: Icons.tune, label: 'Config'),
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
