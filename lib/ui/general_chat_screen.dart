// lib/ui/general_chat_screen.dart
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class _Message {
  final String text;
  final bool fromUser;
  const _Message(this.text, {required this.fromUser});
}

class GeneralChatScreen extends StatefulWidget {
  const GeneralChatScreen({super.key});

  @override
  State<GeneralChatScreen> createState() => _GeneralChatScreenState();
}

class _GeneralChatScreenState extends State<GeneralChatScreen> {
  final List<_Message> _messages = [
    const _Message(
      'Ask me anything about your repos, or open a file from the GitHub tab to structure it.',
      fromUser: false,
    ),
  ];
  final _inputController = TextEditingController();

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() {
      _messages.add(_Message(text, fromUser: true));
      _messages.add(const _Message(
        'Open a file from the GitHub tab to generate structured Markdown from it.',
        fromUser: false,
      ));
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 60,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('Assistant', style: appHeading(size: 17, weight: FontWeight.w700)),
              ],
            ),
          ),
          const Divider(color: AppColors.fg, thickness: 2, height: 2),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                return appChatBubble(text: m.text, fromUser: m.fromUser);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: appBorderedField(
                    controller: _inputController,
                    hint: 'Ask the assistant...',
                  ),
                ),
                const SizedBox(width: 8),
                appIconCircleButton(icon: Icons.arrow_forward, onPressed: _send, filled: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
