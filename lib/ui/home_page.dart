import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/providers.dart';
import 'chat_page.dart';

/// Session roster: workspaces with their sessions, plus ungrouped sessions.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roster = ref.watch(rosterProvider);
    final connection = ref.watch(connectionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('DSH Remote'),
        actions: [
          if (connection != null)
            ListenableBuilder(
              listenable: connection,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(child: _StatusChip(connection: connection)),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => ref.read(rosterProvider.notifier).refresh(),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'disconnect') {
                await ref.read(connectionProvider.notifier).disconnect();
              } else if (value == 'new_workspace') {
                await _createWorkspace(context, ref);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'new_workspace', child: Text('新建 Workspace')),
              PopupMenuItem(value: 'disconnect', child: Text('断开连接')),
            ],
          ),
        ],
      ),
      body: _buildBody(context, ref, roster, theme),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, RosterState roster, ThemeData theme) {
    if (roster.loading && roster.sessions.isEmpty && roster.workspaces.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (roster.error != null && roster.sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(roster.error!, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.read(rosterProvider.notifier).refresh(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final sessionsById = {for (final s in roster.sessions) s.sessionId: s};
    final grouped = <String>{};
    final sections = <Widget>[];

    for (final workspace in roster.workspaces) {
      final sessions = workspace.sessionIds
          .map((id) => sessionsById[id])
          .whereType<SessionSummary>()
          .where((s) => !s.blank && !s.isSubagent && !roster.archivedSessionIds.contains(s.sessionId))
          .toList();
      grouped.addAll(workspace.sessionIds);
      sections.add(_WorkspaceHeader(
        workspace: workspace,
        onNewSession: () => _createSession(context, ref, workspaceId: workspace.workspaceId),
      ));
      if (sessions.isEmpty) {
        sections.add(const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 8),
          child: Text('（无会话）', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ));
      } else {
        sections.addAll(sessions.map((s) => _SessionTile(session: s)));
      }
    }

    final ungrouped = roster.sessions
        .where((s) => !grouped.contains(s.sessionId) && !s.blank && !s.isSubagent)
        .toList();
    if (ungrouped.isNotEmpty) {
      sections.add(const _SectionHeader(title: '未分组'));
      sections.addAll(ungrouped.map((s) => _SessionTile(session: s)));
    }

    if (sections.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('还没有会话'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _createSession(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('新建会话'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(rosterProvider.notifier).refresh(),
      child: ListView(children: sections),
    );
  }

  Future<void> _createSession(BuildContext context, WidgetRef ref, {String? workspaceId}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    try {
      final value = await connection.api.rpc('session.create', {
        'workspaceId': ?workspaceId,
      });
      final sessionId = (value as Map)['sessionId'] as String?;
      if (sessionId != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ChatPage(sessionId: sessionId)),
        );
        await ref.read(rosterProvider.notifier).refresh();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建会话失败: $e')));
      }
    }
  }

  Future<void> _createWorkspace(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建 Workspace'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '目录路径（主机上的绝对路径）',
            hintText: '/Users/you/projects/demo',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    try {
      await connection.api.rpc('workspace.create', {'path': path});
      await ref.read(rosterProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建 Workspace 失败: $e')));
      }
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.connection});

  final DshConnection connection;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (connection.status) {
      ConnStatus.connected => (Colors.greenAccent, '已连接'),
      ConnStatus.connecting => (Colors.orangeAccent, '连接中'),
      ConnStatus.reconnecting => (Colors.orangeAccent, '重连中'),
      ConnStatus.failed => (Colors.redAccent, '失败'),
      ConnStatus.disconnected => (Colors.grey, '离线'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({required this.workspace, required this.onNewSession});

  final WorkspaceView workspace;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              workspace.title,
              style: Theme.of(context).textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: '在此 Workspace 新建会话',
            onPressed: onNewSession,
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = session.title?.isNotEmpty == true
        ? session.title!
        : (session.cwd != null ? session.cwd!.split('/').last : session.sessionId);
    final updated = DateTime.fromMillisecondsSinceEpoch(session.updatedAt.toInt());
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.chat_bubble_outline,
        size: 18,
        color: session.running ? Colors.greenAccent : null,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${updated.month}/${updated.day} ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}'
        '${session.running ? ' · 运行中' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatPage(sessionId: session.sessionId)),
      ),
    );
  }
}
