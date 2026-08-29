// lib/ui/settings_screen.dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../git/git_identity.dart';
import '../git/repo_git_service.dart';
import '../github/github_api.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';

const _appVersion = '1.0.0';

/// The second tab: the account every clone, commit and push in this app runs
/// as, and nothing else.
class SettingsScreen extends StatefulWidget {
  final SecretStore secretStore;
  final VoidCallback onAccountChanged;

  const SettingsScreen({super.key, required this.secretStore, required this.onAccountChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  bool _busy = false;

  /// Whether a token is stored. The token itself is never held in state — it
  /// is read for the one call that needs it and dropped again.
  bool _connected = false;

  /// Cached from the last successful sign-in, so the screen has something to
  /// show before the network answers.
  CommitIdentity? _identity;

  /// Only set by a live `currentUser()` call; null means "not refreshed yet".
  GithubUser? _user;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = await widget.secretStore.read(secretKeyGithubPat);
    final prefs = await SharedPreferences.getInstance();
    final identity = await loadCommitIdentity(prefs);
    if (!mounted) return;
    final connected = token != null && token.isNotEmpty;
    setState(() {
      _connected = connected;
      _identity = identity;
      _loading = false;
    });
    if (connected) await _refreshUser(silent: true);
  }

  /// The single reporting path for failures, with the token stripped out of
  /// the message before it can reach a widget.
  Future<void> _report(String title, Object failure, String? token) async {
    final message = redactSecrets('$failure', token: token);
    final help = githubAuthHelp(message);
    if (!mounted) return;
    await showOutputPopup(
      context,
      title: title,
      body: help == null ? message : '$help\n\n$message',
    );
  }

  /// Re-asks GitHub who the stored token belongs to and re-saves the commit
  /// identity from the answer. [silent] is the automatic refresh on open,
  /// which must not throw popups at a user who only opened the tab.
  Future<void> _refreshUser({bool silent = false}) async {
    setState(() => _busy = true);
    final token = await widget.secretStore.read(secretKeyGithubPat);
    if (token == null || token.isEmpty) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _connected = false;
      });
      return;
    }

    GithubUser? user;
    Object? failure;
    try {
      user = await GithubApi(client: Dio(), token: token).currentUser();
      final prefs = await SharedPreferences.getInstance();
      await saveCommitIdentity(prefs, CommitIdentity.fromGithubUser(user));
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (user != null) {
        _user = user;
        _identity = CommitIdentity.fromGithubUser(user);
      }
    });

    if (failure != null) {
      if (!silent) await _report('Could not reach GitHub', failure, token);
      return;
    }
    if (!silent && user != null) {
      await showOutputPopup(
        context,
        title: 'Identity refreshed',
        body: 'Commits are authored as ${_identity!.name} <${_identity!.email}>.',
      );
    }
  }

  /// Takes a token, proves it works, and only then stores it. A token that
  /// GitHub rejects never reaches the keystore.
  Future<void> _connect() async {
    final token = await _askForToken();
    if (token == null || !mounted) return;

    setState(() => _busy = true);
    GithubUser? user;
    Object? failure;
    // Two phases, reported separately: a token GitHub rejects is never
    // written, but once it *is* written, a later failure must not tell the
    // user nothing was saved while it sits in the keystore.
    var stored = false;
    try {
      user = await GithubApi(client: Dio(), token: token).currentUser();
      await widget.secretStore.write(secretKeyGithubPat, token);
      stored = true;
      final prefs = await SharedPreferences.getInstance();
      await saveCommitIdentity(prefs, CommitIdentity.fromGithubUser(user));
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (user != null) {
        _connected = true;
        _user = user;
        _identity = CommitIdentity.fromGithubUser(user);
      }
    });

    if (failure != null) {
      if (stored) {
        // The token works and is stored; only the identity cache failed.
        widget.onAccountChanged();
        if (!mounted) return;
        await _report('Token saved, but the commit identity could not be cached', failure, token);
      } else {
        await _report('Token rejected — nothing was saved', failure, token);
      }
      return;
    }
    widget.onAccountChanged();
    if (!mounted) return;
    await showOutputPopup(
      context,
      title: 'Connected',
      body: 'Signed in as ${user!.login}.\n'
          'Commits are authored as ${_identity!.name} <${_identity!.email}>.',
    );
  }

  Future<void> _signOut() async {
    final ok = await showConfirmPopup(
      context,
      title: 'Sign out?',
      message: 'The token is deleted from this device. Repositories already cloned stay '
          'on disk, but nothing can be fetched or pushed until you connect again.',
      confirmLabel: 'Sign out',
    );
    if (!ok || !mounted) return;

    await widget.secretStore.delete(secretKeyGithubPat);
    final prefs = await SharedPreferences.getInstance();
    await clearCommitIdentity(prefs);
    if (!mounted) return;
    setState(() {
      _connected = false;
      _user = null;
      _identity = null;
    });
    widget.onAccountChanged();
  }

  /// The token popup, masked.
  ///
  /// It goes through `showInputPopup` rather than a hand-rolled dialog so the
  /// controller is owned by the route: disposing it when the future completes
  /// crashes the field that is still rebuilding through the close animation.
  Future<String?> _askForToken() {
    return showInputPopup(
      context,
      title: 'GitHub token',
      hint: 'ghp_… / github_pat_…',
      confirmLabel: 'Connect',
      obscure: true,
      description: 'Paste a personal access token. It is checked against GitHub '
          'before anything is saved, and stored in the device keystore.',
    );
  }

  Future<void> _showTokenHelp() {
    return showOutputPopup(
      context,
      title: 'Creating a token',
      body: 'PocketGit talks to GitHub with a personal access token (PAT).\n\n'
          'Where:\n'
          '  github.com/settings/tokens\n\n'
          'Classic token:\n'
          '  Generate new token (classic), then tick the "repo" scope.\n'
          '  That single scope covers reading, cloning and pushing.\n\n'
          'Fine-grained token:\n'
          '  Generate new token, select the repositories you want to use here,\n'
          '  then set Repository permissions > Contents: Read and write.\n'
          '  A fine-grained token only works on the repositories you listed.\n\n'
          'Give it an expiry you are comfortable with — an expired token shows\n'
          'up here as "GitHub rejected the token (HTTP 401)".\n\n'
          'Storage:\n'
          '  The token is written to the device keystore through\n'
          '  flutter_secure_storage. It is never written to app settings, never\n'
          '  printed in an error message, and never sent anywhere except\n'
          '  api.github.com and github.com.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(color: AppColors.fg)),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          children: [
            Text('Settings', style: appHeading(size: 22)),
            const SizedBox(height: 18),
            _accountSection(),
            const SizedBox(height: 18),
            _identitySection(),
            const SizedBox(height: 18),
            _section(
              title: 'Token help',
              children: [
                Text(
                  'What kind of token PocketGit needs, and where it is kept.',
                  style: appBody(size: 12, color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                appSecondaryButton(label: 'How to create a token', onPressed: _showTokenHelp),
              ],
            ),
            const SizedBox(height: 18),
            _section(
              title: 'About',
              children: [
                Text('PocketGit $_appVersion', style: appMono(size: 13)),
                const SizedBox(height: 6),
                Text(
                  'Browse your GitHub repositories, clone them, edit files, commit and '
                  'push — from your phone.',
                  style: appBody(size: 12, color: AppColors.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _accountSection() {
    final identity = _identity;
    return _section(
      title: 'GitHub account',
      children: [
        if (!_connected)
          Text('Not connected.', style: appMono(size: 13, color: AppColors.muted))
        else ...[
          Text('@${_user?.login ?? identity?.name ?? '…'}', style: appMono(size: 14)),
          const SizedBox(height: 4),
          Text(
            identity == null ? 'Signed in.' : '${identity.name} · ${identity.email}',
            style: appBody(size: 12, color: AppColors.muted),
          ),
        ],
        const SizedBox(height: 12),
        appSecondaryButton(
          label: _connected ? 'Replace token' : 'Connect GitHub account',
          onPressed: _busy ? null : _connect,
        ),
        if (_connected) ...[
          const SizedBox(height: 8),
          appSecondaryButton(label: 'Sign out', onPressed: _busy ? null : _signOut),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.fg),
              ),
              const SizedBox(width: 10),
              Text('Talking to GitHub…', style: appBody(size: 12, color: AppColors.muted)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _identitySection() {
    final identity = _identity;
    return _section(
      title: 'Commit identity',
      children: [
        Text(
          identity == null
              ? 'No identity yet — connect a GitHub account.'
              : 'Commits are authored as ${identity.name} <${identity.email}>',
          style: appMono(size: 12.5),
        ),
        const SizedBox(height: 6),
        Text(
          'Taken from the signed-in GitHub account; it is not editable here.',
          style: appBody(size: 12, color: AppColors.muted),
        ),
        const SizedBox(height: 12),
        appSecondaryButton(
          label: 'Refresh from GitHub',
          onPressed: (_busy || !_connected) ? null : () => _refreshUser(),
        ),
      ],
    );
  }

  Widget _section({required String title, required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.fg, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: appHeading(size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
