import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'theme.dart';

/// First-run server setup: enter the DSH host address (host:port or URL).
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key});

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _controller = TextEditingController();
  bool _testing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      // Probe host.describe before persisting the profile.
      final url = normalizeBaseUrl(input);
      final probe = ref.read(connectionProbeProvider);
      await probe(url);
      await ref.read(serverProfileProvider.notifier).setUrl(url);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const NekoMascot(size: 104),
                  const SizedBox(height: 16),
                  Text('DSH Remote', style: theme.textTheme.displaySmall, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    '连接到你的 DeepSeek Harness 主机',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: '主机地址',
                      hintText: '192.168.1.5:3081',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onSubmitted: (_) => _connect(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _testing ? null : _connect,
                    icon: _testing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const PawIcon(size: 18),
                    label: Text(_testing ? '连接中…' : '连接'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  Text(
                    '提示：在主机上运行 `node relay/dsh-relay.mjs` 启动局域网中继，'
                    '手机与主机连同一 Wi-Fi 后填写中继地址（默认端口 3081）。',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One-shot probe used by setup: verifies host.describe succeeds against a
/// candidate base URL before the profile is persisted.
final connectionProbeProvider = Provider<Future<void> Function(String)>((ref) {
  return (String baseUrl) async {
    final api = ref.read(apiFactoryProvider)(baseUrl);
    try {
      await api.rpc('host.describe');
    } finally {
      api.dispose();
    }
  };
});
