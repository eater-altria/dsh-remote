import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/providers.dart';
import 'chat_page.dart';
import 'theme.dart';

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
            icon: const Icon(Icons.search),
            tooltip: '搜索会话内容',
            onPressed: () => showSearch(context: context, delegate: _SessionSearchDelegate()),
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
        sections.add(Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text('（无会话）',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
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
            const NekoMascot(size: 88),
            const SizedBox(height: 12),
            const Text('还没有会话，去发起第一段对话吧'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _createSession(context, ref),
              icon: const PawIcon(size: 18),
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
    final path = await showDialog<String>(
      context: context,
      builder: (context) => const _DirectoryPickerDialog(),
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
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (connection.status) {
      ConnStatus.connected => (scheme.tertiary, '已连接'),
      ConnStatus.connecting => (scheme.secondary, '连接中'),
      ConnStatus.reconnecting => (scheme.secondary, '重连中'),
      ConnStatus.failed => (scheme.error, '失败'),
      ConnStatus.disconnected => (scheme.outline, '离线'),
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
        color: session.running ? Theme.of(context).colorScheme.tertiary : null,
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
      onLongPress: () async {
        final action = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('重命名'),
                    onTap: () => Navigator.pop(context, 'rename')),
                ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: const Text('归档'),
                    onTap: () => Navigator.pop(context, 'archive')),
              ],
            ),
          ),
        );
        if (action == 'rename' && context.mounted) {
          final controller = TextEditingController(text: session.title);
          final title = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('重命名会话'),
              content: TextField(controller: controller, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text.trim()),
                    child: const Text('保存')),
              ],
            ),
          );
          if (title != null && title.isNotEmpty) {
            await renameSession(ref, session.sessionId, title);
          }
        } else if (action == 'archive') {
          await archiveSession(ref, session.sessionId, archived: true);
        }
      },
    );
  }
}

/// 主机目录浏览器（host.listDirectory 逐级导航），用于新建 Workspace。
class _DirectoryPickerDialog extends ConsumerStatefulWidget {
  const _DirectoryPickerDialog();

  @override
  ConsumerState<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends ConsumerState<_DirectoryPickerDialog> {
  String? _currentPath;

  @override
  Widget build(BuildContext context) {
    final listing = ref.watch(directoryListingProvider(_currentPath));
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('选择 Workspace 目录'),
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: listing.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('读取失败: $e')),
          data: (data) => Column(
            children: [
              // 面包屑
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final crumb in data.crumbs)
                      TextButton(
                        onPressed: () => setState(() => _currentPath = crumb.path),
                        child: Text(crumb.name.isEmpty ? '/' : crumb.name),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    for (final entry in data.entries.where((e) => !e.hidden))
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder_outlined, size: 18),
                        title: Text(entry.name),
                        onTap: () => setState(() => _currentPath = entry.path),
                      ),
                  ],
                ),
              ),
              Text('当前：${data.path}', style: theme.textTheme.bodySmall,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final data = listing.value;
            Navigator.pop(context, data?.path);
          },
          child: const Text('选择此目录'),
        ),
      ],
    );
  }
}

/// 会话内容搜索（session.search）。
class _SessionSearchDelegate extends SearchDelegate<String?> {
  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget? buildLeading(BuildContext context) =>
      IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => _SearchResults(query: query);

  @override
  Widget buildSuggestions(BuildContext context) => query.trim().isEmpty
      ? const Center(child: Text('输入关键词搜索会话内容'))
      : _SearchResults(query: query);
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(sessionSearchProvider(query));
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('搜索失败: $e')),
      data: (items) {
        if (items.isEmpty) return const Center(child: Text('没有匹配的会话'));
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.notes, size: 18),
              title: Text(item.snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatPage(sessionId: item.sessionId)),
                );
              },
            );
          },
        );
      },
    );
  }
}
