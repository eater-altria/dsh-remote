import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../api/client.dart';
import '../api/download_service.dart';
import '../api/models.dart';
import '../api/push_dedupe.dart';
import '../state/app_settings.dart';
import '../state/providers.dart';
import 'chat_page.dart';
import 'inbox_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// Session roster: workspaces with their sessions, plus ungrouped sessions.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  StreamSubscription<Map<String, dynamic>>? _pushSub;
  // relay 每次 WS 连接会补发最近推送；已处理 id 持久化，重启 App 不再重复弹窗。
  final PushDedupe _pushDedupe = PushDedupe();

  @override
  void initState() {
    super.initState();
    // relay 文件推送：连上后订阅（connection 实例随重连更换，用 provider 监听）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _listenPushes());
  }

  void _listenPushes() {
    ref.listenManual(connectionProvider, (previous, connection) {
      _pushSub?.cancel();
      _pushSub = connection?.pushEvents.listen(_onPush);
    }, fireImmediately: true);
  }

  Future<void> _onPush(Map<String, dynamic> meta) async {
    final id = meta['id'] as String? ?? '';
    if (!await _pushDedupe.markIfNew(id)) return; // 补发/已处理去重
    if (!mounted) return;
    final s = ref.read(stringsProvider);
    final name = meta['name'] as String? ?? s.fileFallback;
    final bytes = (meta['bytes'] as num?)?.toInt() ?? 0;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.download_outlined),
        title: Text(s.fileReceived),
        content: Text(s.fileSavePrompt(name, _formatBytes(bytes))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.ignore)),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _download(meta);
            },
            child: Text(s.saveToPhone),
          ),
        ],
      ),
    );
  }

  Future<void> _download(Map<String, dynamic> meta) async {
    final s = ref.read(stringsProvider);
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final ok = await launchFileDownload(
      baseUrl: connection.baseUrl,
      token: connection.token,
      fileId: meta['id'] as String? ?? '',
      fileName: meta['name'] as String? ?? 'download',
      title: meta['title'] as String?,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? s.downloadStarted : s.downloadFailed)),
      );
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  void dispose() {
    _pushSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final s = ref.watch(stringsProvider);
    final roster = ref.watch(rosterProvider);
    final connection = ref.watch(connectionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.watch(activeHostProvider)?.name ?? 'DSH Remote'),
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
            tooltip: s.searchSessions,
            onPressed: () => showSearch(context: context, delegate: _SessionSearchDelegate(s: s)),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: s.refresh,
            onPressed: () => ref.read(rosterProvider.notifier).refresh(),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'hosts') {
                Navigator.of(context).pop();
              } else if (value == 'new_workspace') {
                await _createWorkspace(context, ref);
              } else if (value == 'settings') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                );
              } else if (value == 'inbox') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InboxPage()),
                );
              } else if (value == 'theme') {
                final current = ref.read(themeModeProvider);
                final chosen = await showModalBottomSheet<String>(
                  context: context,
                  showDragHandle: true,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (value, label, icon) in [
                          ('system', s.themeFollowSystem, Icons.brightness_auto),
                          ('light', s.themeLight, Icons.light_mode_outlined),
                          ('dark', s.themeDark, Icons.dark_mode_outlined),
                        ])
                          ListTile(
                            leading: Icon(icon),
                            title: Text(label),
                            trailing: current == value ? const Icon(Icons.check) : null,
                            onTap: () => Navigator.pop(context, value),
                          ),
                      ],
                    ),
                  ),
                );
                if (chosen != null) {
                  await ref.read(themeModeProvider.notifier).setMode(chosen);
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'new_workspace', child: Text(s.newWorkspace)),
              PopupMenuItem(value: 'inbox', child: Text(s.inboxTitle)),
              PopupMenuItem(value: 'theme', child: Text(s.appearance)),
              PopupMenuItem(value: 'settings', child: Text(s.settingsTitle)),
              PopupMenuItem(value: 'hosts', child: Text(s.backToHosts)),
            ],
          ),
        ],
      ),
      body: _buildBody(context, ref, s, roster, theme),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, S s, RosterState roster, ThemeData theme) {
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
              Text(s.loadFailed, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(roster.error!, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.read(rosterProvider.notifier).refresh(),
                child: Text(s.retry),
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
          child: Text(s.noSessions,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ));
      } else {
        sections.addAll(sessions.map((s) => _SessionTile(session: s)));
      }
    }

    final ungrouped = roster.sessions
        .where((s) =>
            !grouped.contains(s.sessionId) &&
            !s.blank &&
            !s.isSubagent &&
            !roster.archivedSessionIds.contains(s.sessionId))
        .toList();
    if (ungrouped.isNotEmpty) {
      sections.add(_SectionHeader(title: s.ungrouped));
      sections.addAll(ungrouped.map((s) => _SessionTile(session: s)));
    }

    if (sections.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NekoHero(size: 156),
            const SizedBox(height: 12),
            Text(s.emptyRoster),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _createSession(context, ref),
              icon: const PawIcon(size: 18),
              label: Text(s.newSession),
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
    final s = ref.read(stringsProvider);
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    // 有 preset 目录时让主人选择；'default' = 默认组合，null = 取消创建。
    String? preset;
    var cancelled = false;
    try {
      final presets = await ref.read(agentPresetListProvider.future);
      if (presets.length > 1 && context.mounted) {
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(s.chooseAgentPreset, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final p in presets)
                  ListTile(
                    dense: true,
                    leading: Icon(p.trust == 'system' ? Icons.verified_outlined : Icons.person_outline,
                        size: 18),
                    title: Text(p.name ?? p.id),
                    subtitle: p.description != null
                        ? Text(p.description!, maxLines: 1, overflow: TextOverflow.ellipsis)
                        : null,
                    trailing: p.isDefault ? Text(s.defaultLabel) : null,
                    enabled: p.brokenReason == null,
                    onTap: () => Navigator.pop(context, p.isDefault ? 'default' : p.id),
                  ),
              ],
            ),
          ),
        );
        if (chosen == null) {
          cancelled = true;
        } else if (chosen != 'default') {
          preset = chosen;
        }
      }
    } catch (_) {
      // preset 目录失败不阻塞创建
    }
    if (cancelled) return;
    try {
      final value = await connection.api.rpc('session/create', {
        'request': {
          'workspaceId': ?workspaceId,
          'agentPreset': ?preset,
        },
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.createSessionFailed(e))));
      }
    }
  }

  Future<void> _createWorkspace(BuildContext context, WidgetRef ref) async {
    final s = ref.read(stringsProvider);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => const _DirectoryPickerDialog(),
    );
    if (path == null || path.isEmpty) return;
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    try {
      await connection.api.rpc('workspace/create', {
        'request': {'path': path},
      });
      await ref.read(rosterProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.createWorkspaceFailed(e))));
      }
    }
  }
}

class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.connection});

  final DshConnection connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (connection.status) {
      ConnStatus.connected => (scheme.tertiary, s.statusConnected),
      ConnStatus.connecting => (scheme.secondary, s.statusConnecting),
      ConnStatus.reconnecting => (scheme.secondary, s.statusReconnecting),
      ConnStatus.failed => (scheme.error, s.statusFailed),
      ConnStatus.disconnected => (scheme.outline, s.statusOffline),
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

class _WorkspaceHeader extends ConsumerWidget {
  const _WorkspaceHeader({required this.workspace, required this.onNewSession});

  final WorkspaceView workspace;
  final VoidCallback onNewSession;

  Future<void> _onLongPress(BuildContext context, WidgetRef ref) async {
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
              title: Text(s.renameWorkspace),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(s.deleteWorkspaceKeepData),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    try {
      if (action == 'rename') {
        if (!context.mounted) return;
        final controller = TextEditingController(text: workspace.title);
        final title = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.renameWorkspace),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
              FilledButton(
                  onPressed: () => Navigator.pop(context, controller.text.trim()),
                  child: Text(s.save)),
            ],
          ),
        );
        if (title != null && title.isNotEmpty) {
          await connection.api.rpc('workspace/rename', {
            'request': {'workspaceId': workspace.workspaceId, 'title': title},
          });
        }
      } else if (action == 'delete') {
        if (!context.mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.deleteWorkspaceTitle),
            content: Text(s.deleteWorkspaceBody),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.cancel)),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true), child: Text(s.delete)),
            ],
          ),
        );
        if (confirmed == true) {
          await connection.api.rpc('workspace/delete', {
            'request': {'workspaceId': workspace.workspaceId},
          });
        }
      }
      await ref.read(rosterProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.opFailed(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPress: () => _onLongPress(context, ref),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Row(
          children: [
            // design.md §4：节标题用 titleSmall；图标用主色淡底圆角徽章
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.folder_outlined, size: 14, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                workspace.title,
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: ref.watch(stringsProvider).newSessionInWorkspace,
              onPressed: onNewSession,
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final title = session.title?.isNotEmpty == true
        ? session.title!
        : (session.cwd != null ? session.cwd!.split('/').last : session.sessionId);
    final updated = DateTime.fromMillisecondsSinceEpoch(session.updatedAt.toInt());
    final scheme = Theme.of(context).colorScheme;
    // design.md §4：列表项用零阴影卡片 + 描边，水平 12 外边距
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: session.running ? scheme.tertiaryContainer : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.chat_bubble_outline,
            size: 15,
            color: session.running ? scheme.onTertiaryContainer : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${updated.month}/${updated.day} ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}'
          '${session.running ? s.runningSuffix : ''}',
          style: TextStyle(
            fontSize: 12,
            color: session.running ? scheme.tertiary : scheme.onSurfaceVariant,
          ),
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
                    title: Text(s.rename),
                    onTap: () => Navigator.pop(context, 'rename')),
                ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: Text(s.archive),
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
              title: Text(s.renameSessionTitle),
              content: TextField(controller: controller, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text.trim()),
                    child: Text(s.save)),
              ],
            ),
          );
          if (title != null && title.isNotEmpty) {
            await renameSession(ref, session.sessionId, title);
          }
        } else if (action == 'archive') {
          await archiveSession(ref, session.sessionId);
        }
      },
      ),
    );
  }
}

/// 主机目录浏览器（relay listDir / directoryPicker 逐级导航），用于新建 Workspace。
class _DirectoryPickerDialog extends ConsumerStatefulWidget {
  const _DirectoryPickerDialog();

  @override
  ConsumerState<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends ConsumerState<_DirectoryPickerDialog> {
  String? _currentPath;
  bool _manual = false; // browse 能力不可用时降级为手动输入
  final _manualController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final listing = ref.watch(directoryListingProvider(_currentPath));
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(s.chooseWorkspaceDir),
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: listing.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) {
            // host 只组合了 native 选择器时 listDirectory 不可用 → 降级手动输入
            if (_manual || '$e'.contains('directory-picker-unavailable')) {
              return _ManualPathInput(controller: _manualController);
            }
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s.readFailed(e), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => setState(() => _manual = true),
                      child: Text(s.manualPathInstead),
                    ),
                  ],
                ),
              ),
            );
          },
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
              Text(s.currentPath(data.path), style: theme.textTheme.bodySmall,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(
          onPressed: () {
            if (_manual || listing.hasError) {
              Navigator.pop(context, _manualController.text.trim());
            } else {
              Navigator.pop(context, listing.valueOrNull?.path);
            }
          },
          child: Text(_manual || listing.hasError ? s.useThisPath : s.chooseThisDir),
        ),
      ],
    );
  }
}

/// 会话内容搜索（session.search）。
class _SessionSearchDelegate extends SearchDelegate<String?> {
  _SessionSearchDelegate({required this.s});

  final S s;

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
  Widget buildSuggestions(BuildContext context) =>
      query.trim().isEmpty ? Center(child: Text(s.searchHint)) : _SearchResults(query: query);
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final results = ref.watch(sessionSearchProvider(query));
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(s.searchFailed(e))),
      data: (items) {
        if (items.isEmpty) return Center(child: Text(s.noMatchingSessions));
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

/// 目录浏览器降级：手动输入绝对路径。
class _ManualPathInput extends ConsumerWidget {
  const _ManualPathInput({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.nativePickerOnlyHint, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: s.dirPathLabel,
            hintText: '/Users/you/projects/demo',
          ),
        ),
      ],
    );
  }
}
