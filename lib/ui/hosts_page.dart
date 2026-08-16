import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'home_page.dart';
import 'host_edit_page.dart';
import 'theme.dart';

/// 主机选择主页：列出已配置的远程主机，点选进入对应主机的会话列表。
class HostsPage extends ConsumerWidget {
  const HostsPage({super.key});

  Future<void> _enterHost(BuildContext context, WidgetRef ref, HostProfile host) async {
    await ref.read(activeHostIdProvider.notifier).select(host.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  Future<void> _showHostActions(BuildContext context, WidgetRef ref, HostProfile host) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑主机'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('删除主机', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'edit') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => HostEditPage(existing: host)),
      );
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除主机'),
          content: Text('删除「${host.name}」的连接配置？此操作不影响主机上的数据。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
          ],
        ),
      );
      if (confirmed == true) {
        await ref.read(hostsProvider.notifier).remove(host.id);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider) ?? const <HostProfile>[];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择主机'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加主机',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HostEditPage()),
            ),
          ),
        ],
      ),
      body: hosts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const NekoHero(size: 156),
                    const SizedBox(height: 12),
                    Text(
                      '还没有主机，添加一台开始吧',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const HostEditPage()),
                      ),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加主机'),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              itemCount: hosts.length,
              itemBuilder: (context, i) {
                final host = hosts[i];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ListTile(
                    leading: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.dns_outlined,
                          size: 16, color: theme.colorScheme.onPrimaryContainer),
                    ),
                    title: Text(host.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      host.token.isEmpty ? host.url : '${host.url} · 已设令牌',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert, size: 20),
                      tooltip: '更多操作',
                      onPressed: () => _showHostActions(context, ref, host),
                    ),
                    onTap: () => _enterHost(context, ref, host),
                  ),
                );
              },
            ),
    );
  }
}
