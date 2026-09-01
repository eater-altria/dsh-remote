import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
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
  late final TextEditingController _dshTokenController;
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _urlController = TextEditingController(text: existing?.url ?? '');
    _dshTokenController = TextEditingController(text: existing?.dshToken ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _dshTokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = normalizeBaseUrl(_urlController.text);
    if (url.isEmpty) return;
    final name = _nameController.text.trim();
    final dshToken = _dshTokenController.text.trim();
    final existing = widget.existing;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      // 地址或令牌变化时才探测连通性；仅改名称不阻塞保存。
      final connectionChanged = existing == null ||
          existing.url != url ||
          existing.dshToken != dshToken;
      if (connectionChanged) {
        final probe = ref.read(connectionProbeProvider);
        await probe(url, dshToken: dshToken.isEmpty ? null : dshToken);
      }
      if (existing == null) {
        await ref
            .read(hostsProvider.notifier)
            .add(url: url, name: name, dshToken: dshToken);
      } else {
        await ref.read(hostsProvider.notifier).update(
              existing.copyWith(
                name: name.isEmpty ? HostProfile.defaultName(url) : name,
                url: url,
                dshToken: dshToken,
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
    final theme = Theme.of(context);
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? '编辑主机' : '添加主机')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '名称（可选）',
                    hintText: '留空则使用主机地址',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: '主机地址',
                    hintText: '192.168.1.5:3081',
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dshTokenController,
                  decoration: const InputDecoration(
                    labelText: 'DSH 启动令牌（新版 dsh 必填）',
                    hintText: '`dsh web` 启动 URL 里 ?token= 的值',
                    prefixIcon: Icon(Icons.verified_user_outlined),
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
                  label: Text(_testing ? '连接中…' : (isEdit ? '保存' : '测试并添加')),
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
                            '连接失败',
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
                            '确认 relay 已在主机上运行（launchd 服务或 node relay/dsh-relay.mjs），'
                            '且手机与主机在同一 Wi-Fi。',
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
                  '提示：在主机上运行 `node relay/dsh-relay.mjs` 启动局域网中继，'
                  '手机与主机连同一 Wi-Fi 后填写中继地址（默认端口 3081）。'
                  '新版 dsh（≥0.1.2）另需 DSH 启动令牌——dsh 启动时打印的 '
                  'URL 中 `?token=` 后的部分。',
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
    Provider<Future<void> Function(String, {String? dshToken})>((ref) {
      return (String baseUrl, {String? dshToken}) async {
        final api = DshApi(baseUrl, dshToken: dshToken);
        try {
          // session/list 的 args 键是全 API 唯一的 `_request`（必填）。
          await api.rpc('session/list', {'_request': {}});
        } finally {
          api.dispose();
        }
      };
    });
