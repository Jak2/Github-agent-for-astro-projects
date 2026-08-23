// lib/ui/onboarding_screen.dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../github/github_api.dart';
import '../github/github_repo.dart';
import '../secrets/secret_store.dart';
import '../settings/engine_settings.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  final SecretStore secretStore;
  final VoidCallback onFinished;

  const OnboardingScreen({super.key, required this.secretStore, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { pat, reposIntro, llm }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.pat;
  bool _reposPreviewOpen = false;

  final _patController = TextEditingController();
  final _endpointController = TextEditingController(text: 'https://api.openai.com/v1/chat/completions');
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController(text: 'gpt-4o-mini');
  final _headersController = TextEditingController();
  EngineChoice _engineChoice = EngineChoice.cloud;
  String _onDeviceModelPath = '';

  List<GithubRepo>? _previewRepos;
  String? _previewError;

  @override
  void dispose() {
    _patController.dispose();
    _endpointController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _headersController.dispose();
    super.dispose();
  }

  Future<void> _openReposPreview() async {
    setState(() {
      _reposPreviewOpen = true;
      _previewRepos = null;
      _previewError = null;
    });
    try {
      final api = GithubApi(client: Dio(), token: _patController.text);
      final repos = await api.listRepos();
      if (mounted) setState(() => _previewRepos = repos);
    } catch (e) {
      if (mounted) setState(() => _previewError = 'Failed to load repos: $e');
    }
  }

  Future<void> _pickOnDeviceModel() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = result?.files.single.path;
    if (path != null) setState(() => _onDeviceModelPath = path);
  }

  Future<void> _next() async {
    if (_step == _Step.llm) {
      await _persistAndFinish();
      return;
    }
    setState(() => _step = _Step.values[_step.index + 1]);
  }

  Future<void> _skip() => _persistAndFinish();

  Future<void> _persistAndFinish() async {
    await widget.secretStore.write(secretKeyGithubPat, _patController.text);
    final prefs = await SharedPreferences.getInstance();
    final settings = EngineSettings(
      choice: _engineChoice,
      cloudEndpoint: _endpointController.text,
      cloudModel: _modelController.text,
      cloudHeaders: _headersController.text,
      onDeviceModelPath: _onDeviceModelPath,
    );
    await settings.save(prefs);
    if (_engineChoice == EngineChoice.cloud) {
      await widget.secretStore.write(secretKeyCloudApiKey, _apiKeyController.text);
    }
    widget.onFinished();
  }

  Widget _dots() {
    return Row(
      children: [
        for (var i = 0; i < _Step.values.length; i++)
          Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == _Step.values.length - 1 ? 0 : 10),
              decoration: BoxDecoration(
                color: i <= _step.index ? AppColors.fg : AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }

  Widget _stepLabel(String text) => Text(
        text,
        style: appMono(size: 11, color: AppColors.muted).copyWith(letterSpacing: 1.5),
      );

  Widget _patStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepLabel('STEP 1 OF 3'),
          const SizedBox(height: 16),
          Text('Connect GitHub', style: appHeading()),
          const SizedBox(height: 16),
          Text(
            'Paste a Personal Access Token with repo scope. Generate one at github.com/settings/tokens.',
            style: appBody(size: 13.5, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          appBorderedField(controller: _patController, hint: 'ghp_xxxxxxxxxxxx', obscure: true),
        ],
      ),
    );
  }

  Widget _reposIntroStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepLabel('STEP 2 OF 3'),
          const SizedBox(height: 16),
          Text('Your repositories', style: appHeading()),
          const SizedBox(height: 16),
          Text(
            "Take a look at what's on your GitHub account, or skip for now.",
            style: appBody(size: 13.5, color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          appSecondaryButton(label: 'Browse your repositories', onPressed: _openReposPreview),
        ],
      ),
    );
  }

  Widget _llmStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepLabel('STEP 3 OF 3'),
          const SizedBox(height: 16),
          Text('Choose your LLM', style: appHeading()),
          const SizedBox(height: 14),
          RadioListTile<EngineChoice>(
            contentPadding: EdgeInsets.zero,
            title: Text('Cloud API', style: appBody(size: 14.5)),
            value: EngineChoice.cloud,
            groupValue: _engineChoice,
            onChanged: (v) => setState(() => _engineChoice = v!),
          ),
          if (_engineChoice == EngineChoice.cloud)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 8),
              child: Column(
                children: [
                  appBorderedField(controller: _endpointController, hint: 'Endpoint URL'),
                  const SizedBox(height: 8),
                  appBorderedField(controller: _apiKeyController, hint: 'API key', obscure: true),
                  const SizedBox(height: 8),
                  appBorderedField(controller: _modelController, hint: 'Model name (optional)'),
                  const SizedBox(height: 8),
                  appBorderedField(controller: _headersController, hint: 'Extra headers (Name: value per line)', maxLines: 2),
                ],
              ),
            ),
          RadioListTile<EngineChoice>(
            contentPadding: EdgeInsets.zero,
            title: Text('On-device (.gguf)', style: appBody(size: 14.5)),
            value: EngineChoice.onDevice,
            groupValue: _engineChoice,
            onChanged: (v) => setState(() => _engineChoice = v!),
          ),
          if (_engineChoice == EngineChoice.onDevice)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _onDeviceModelPath.isEmpty ? 'No model selected' : _onDeviceModelPath,
                      style: appMono(size: 11.5, color: AppColors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  appSecondaryButton(label: 'Choose file', onPressed: _pickOnDeviceModel),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _reposPreviewOverlay() {
    return Positioned.fill(
      child: Container(
        color: AppColors.bg,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  appIconCircleButton(
                    icon: Icons.arrow_back,
                    onPressed: () => setState(() => _reposPreviewOpen = false),
                  ),
                  const SizedBox(width: 12),
                  Text('Your repositories', style: appHeading(size: 17, weight: FontWeight.w700)),
                ],
              ),
            ),
            const Divider(color: AppColors.fg, thickness: 2, height: 2),
            Expanded(
              child: _previewError != null
                  ? Center(child: Text(_previewError!, style: appBody(color: AppColors.muted)))
                  : _previewRepos == null
                      ? const Center(child: CircularProgressIndicator(color: AppColors.fg))
                      : ListView(
                          children: [
                            for (final r in _previewRepos!)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                decoration: const BoxDecoration(
                                  border: Border(bottom: BorderSide(color: AppColors.divider, width: 2)),
                                ),
                                child: Text(r.fullName, style: appMono(size: 13)),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: _dots(),
                ),
                Expanded(
                  child: Center(
                    child: switch (_step) {
                      _Step.pat => _patStep(),
                      _Step.reposIntro => _reposIntroStep(),
                      _Step.llm => _llmStep(),
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                  child: Column(
                    children: [
                      appPrimaryButton(
                        label: _step == _Step.llm ? 'Finish setup' : 'Next',
                        onPressed: _next,
                      ),
                      if (_step == _Step.reposIntro)
                        TextButton(
                          onPressed: _skip,
                          child: Text('Skip', style: appBody(size: 13, color: AppColors.muted)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_reposPreviewOpen) _reposPreviewOverlay(),
          ],
        ),
      ),
    );
  }
}
