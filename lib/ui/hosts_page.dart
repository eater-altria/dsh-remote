import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../state/app_settings.dart';
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
    final s = ref.read(stringsProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(s.editHost),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: Text(s.restartDsh),
              subtitle: Text(s.restartDshDesc),
              onTap: () => Navigator.pop(context, 'restart'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(s.deleteHost, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
    } else if (action == 'restart') {
      await _restartDsh(context, ref, host);
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(s.deleteHost),
          content: Text(s.deleteHostQ(host.name)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.delete)),
          ],
        ),
      );
      if (confirmed == true) {
        await ref.read(hostsProvider.notifier).remove(host.id);
      }
    }
  }

  /// 重启该主机上的 dsh（relay 代劳：杀旧进程 → `dsh web --no-open` 拉起）。
  Future<void> _restartDsh(BuildContext context, WidgetRef ref, HostProfile host) async {
    final s = ref.read(stringsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.restartDshQ),
        content: Text(s.restartDshBody(host.name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.restartDsh)),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(s.restartingDsh)));
    final api = DshApi(host.url, token: host.token.isEmpty ? null : host.token);
    try {
      final result = await api.restartDsh();
      messenger.showSnackBar(SnackBar(
        content: Text(result['ready'] == true ? s.dshRestarted : s.dshRestartWaiting),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.restartFailed(e))));
    } finally {
      api.dispose();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final hosts = ref.watch(hostsProvider) ?? const <HostProfile>[];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.chooseHost),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: s.addHost,
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
                      s.emptyHosts,
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
                      label: Text(s.addHost),
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
                      [
                        host.url,
                        if (host.token.isNotEmpty) s.tokenSet,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert, size: 20),
                      tooltip: s.moreActions,
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
