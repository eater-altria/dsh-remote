import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../state/app_settings.dart';
import '../state/providers.dart';
import 'theme.dart';

/// 新增 / 编辑主机配置：地址 + 令牌 + 可选名称，保存前探测连通性。
class HostEditPage extends ConsumerStatefulWidget {
  const HostEditPage({super.key, this.existing});

  /// 传入即为编辑模式，否则为新增。
  final HostProfile? existing;

  @override
  ConsumerState<HostEditPage> createState() => _HostEditPageState();
}

class _HostEditPageState extends ConsumerState<HostEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _urlController = TextEditingController(text: existing?.url ?? '');
    _tokenController = TextEditingController(text: existing?.token ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = normalizeBaseUrl(_urlController.text);
    if (url.isEmpty) return;
    final name = _nameController.text.trim();
    final token = _tokenController.text.trim();
    final existing = widget.existing;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      // 地址或令牌变化时才探测连通性；仅改名称不阻塞保存。
      final connectionChanged = existing == null ||
          existing.url != url ||
          existing.token != token;
      if (connectionChanged) {
        final probe = ref.read(connectionProbeProvider);
        await probe(url, token: token.isEmpty ? null : token);
      }
      if (existing == null) {
        await ref
            .read(hostsProvider.notifier)
            .add(url: url, name: name, token: token);
      } else {
        await ref.read(hostsProvider.notifier).update(
              existing.copyWith(
                name: name.isEmpty ? HostProfile.defaultName(url) : name,
                url: url,
                token: token,
              ),
            );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? s.editHost : s.addHost)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: s.hostNameOptional,
                    hintText: s.hostNameHint,
                    prefixIcon: const Icon(Icons.label_outline),
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: s.hostAddress,
                    hintText: '192.168.1.5:3081',
                    prefixIcon: const Icon(Icons.dns_outlined),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  decoration: InputDecoration(
                    labelText: s.tokenRequired,
                    hintText: s.tokenHint,
                    prefixIcon: const Icon(Icons.key_outlined),
                  ),
                  obscureText: true,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _testing ? null : _save,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const PawIcon(size: 18),
                  label: Text(_testing ? s.connecting : (isEdit ? s.save : s.testAndAdd)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.connectFailed,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            s.connectFailedBody,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer.withValues(alpha: 0.75),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                Text(
                  s.relayHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One-shot probe used by host editing: verifies a basic unary RPC succeeds
/// against a candidate base URL before the profile is persisted.
final connectionProbeProvider =
    Provider<Future<void> Function(String, {String? token})>((ref) {
      return (String baseUrl, {String? token}) async {
        final api = DshApi(baseUrl, token: token);
        try {
          // session/list 的 args 键是全 API 唯一的 `_request`（必填）。
          await api.rpc('session/list', {'_request': {}});
        } finally {
          api.dispose();
        }
      };
    });
