import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/fold.dart';
import '../api/models.dart';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../state/app_settings.dart';
import '../state/providers.dart';
import 'bottom_stick.dart';
import 'theme.dart';
import 'tool_cards.dart';
import 'package:url_launcher/url_launcher.dart';

/// Chat surface for one session: history, streaming replies, tool cards,
/// question / approval interactions, and the composer.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.sessionId, this.parentSessionId, this.subagentMode});

  /// 完整的聊天作用域（子代理路由带 parent/mode，chatProvider 的 family 键）。
  ChatScope get scope =>
      ChatScope(sessionId: sessionId, parentSessionId: parentSessionId, subagentMode: subagentMode);

  final String sessionId;

  /// 子代理路由：非空表示这是可续聊子代理，发送/停止走 subagent.* 方法。
  final String? parentSessionId;
  final String? subagentMode;

  bool get isContinuableSubagent => parentSessionId != null && subagentMode == 'continuable';

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _composer = TextEditingController();
  final _stick = BottomStickController();
  final List<XFile> _pendingImages = [];
  final Stopwatch _entryWatch = Stopwatch()..start();
  bool _entryLogged = false;

  ScrollController get _scroll => _stick.scroll;
  int _lastContentSignature = 0;
  bool _didInitialScroll = false;

  @override
  void initState() {
    super.initState();
    _stick.attach();
  }

  @override
  void dispose() {
    _composer.dispose();
    _stick.dispose();
    super.dispose();
  }

  /// 内容签名：条目数 + 最后一条的长度 + 流式 partial 长度
  ///（流式增长时条数不变但内容在变；partial 现在是列表最后一行，签名要覆盖它）。
  int _contentSignature(ChatState chat) {
    int blocksSize(List<AssistantBlock> blocks) => blocks.fold<int>(
        0,
        (sum, b) => sum + switch (b) {
              TextBlock() => b.text.length,
              ReasoningBlock() => b.text.length,
              ToolCallBlock() => b.argsRaw.length,
              ImageBlock() => 1,
              OtherBlock() => 0,
            });
    final partialSize = switch (chat.fold?.partial) {
      null => 0,
      final p => blocksSize(p.blocks),
    };
    final items = chat.items;
    if (items.isEmpty) return partialSize;
    final last = items.last;
    final lastSize = switch (last) {
      AssistantItem() => blocksSize(last.blocks),
      UserItem() => last.text.length,
      SystemItem() => last.text.length,
      ToolItem() => last.resultPreview?.length ?? 0,
      ApprovalItem() => last.reason?.length ?? 1,
      NoticeItem() => last.text.length,
    };
    return items.length * 1000000 + lastSize + partialSize;
  }

  void _maybeScrollToEnd(ChatState chat) {
    final signature = _contentSignature(chat);
    if (signature == _lastContentSignature) return;
    _lastContentSignature = signature;
    if (!_stick.stick) return;
    // 瞬时跳而不是动画：动画链会跟用户拖拽实时对抗（流式期间钉死底部）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _stick.jumpToEnd());
  }

  void _jumpToEnd() => _stick.jumpToEnd();

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final chat = ref.watch(chatProvider(widget.scope));
    final notifier = ref.read(chatProvider(widget.scope).notifier);
    _maybeScrollToEnd(chat);
    if (!_entryLogged && !chat.loadingHistory && chat.items.isNotEmpty) {
      _entryLogged = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('[perf] chat first content frame: ${_entryWatch.elapsedMilliseconds}ms since page create');
      });
    }

    // 尾部历史页加载完成 → 首次进入直接跳到底部（不等动画）。
    // 之后的布局增长（图片加载等）由 BottomStickController 的贴底重跳接管。
    // 注意：重连会产生新快照（scrollSignal 再次触发）——只有首次强制贴底；
    // 若用户已上翻阅读历史，重连快照不得把视野拽回底部。
    ref.listen(chatProvider(widget.scope).select((s) => s.scrollSignal), (_, _) {
      final isInitial = !_didInitialScroll;
      _didInitialScroll = true;
      if (isInitial) _stick.stick = true;
      if (!_stick.stick) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToEnd();
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
      });
    });

    // Surface pending interactions.
    ref.listen(chatProvider(widget.scope).select((s) => s.pendingQuestion), (_, next) {
      if (next != null) _showQuestionSheet(next);
    });
    // 审批不再弹窗：approval/asked 事件经 fold 落成消息列表里的常驻卡片。

    return ProviderScope(
      overrides: [
        currentSessionIdProvider.overrideWithValue(widget.sessionId),
        currentChatScopeProvider.overrideWithValue(widget.scope),
      ],
      child: Scaffold(
        appBar: AppBar(
          title: Text(chat.title ?? s.sessionTitleFallback),
          bottom: _ContextUsageBar.fromProjections(chat.projections),
        actions: [
          if (chat.running)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: widget.isContinuableSubagent ? s.interruptSubagent : s.stopTurn,
              onPressed: () => widget.isContinuableSubagent
                  ? notifier.interruptSubagent(widget.parentSessionId!)
                  : notifier.cancel(),
            ),
          IconButton(
            icon: const Icon(Icons.model_training),
            tooltip: s.chooseModel,
            onPressed: () => _showModelSheet(),
          ),
          PopupMenuButton<String>(
            onSelected: _onSessionMenu,
            itemBuilder: (context) => [
              PopupMenuItem(value: 'permission', child: Text(s.permissionMode)),
              PopupMenuItem(value: 'subagents', child: Text(s.subagents)),
              PopupMenuItem(value: 'rename', child: Text(s.rename)),
              PopupMenuItem(value: 'fork', child: Text(s.forkSession)),
              PopupMenuItem(value: 'export', child: Text(s.exportLog)),
              PopupMenuItem(value: 'archive', child: Text(s.archive)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (chat.goal != null && chat.goal!.exists) _GoalBanner(scope: widget.scope, goal: chat.goal!),
          _PlanBanner(projections: chat.projections),
          _TodoBar(projections: chat.projections),
          Expanded(child: _buildList(chat, notifier)),
          // 模型工作中 & 尚无流式输出时，底部给一个可爱的等待提示。
          if (chat.running && chat.fold?.partial == null) const _WorkingIndicator(),
          if (chat.jobs.isNotEmpty) _JobsStrip(jobs: chat.jobs),
          if (chat.queue.isNotEmpty) _QueueStrip(queue: chat.queue),
            _SkillSuggestions(
                sessionId: widget.parentSessionId ?? widget.sessionId, controller: _composer),
            _buildComposer(chat, notifier),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ChatState chat, ChatNotifier notifier) {
    final s = ref.watch(stringsProvider);
    final partial = chat.fold?.partial;
    if (chat.loadingHistory && chat.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (chat.historyError != null && chat.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(s.historyLoadFailed(chat.historyError ?? ''), textAlign: TextAlign.center),
        ),
      );
    }
    if (chat.items.isEmpty && partial == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NekoHero(size: 156),
            const SizedBox(height: 12),
            Text(s.emptyChat),
          ],
        ),
      );
    }
    // 兜底：pendingApproval 已到但 approval/asked 事件未落卡（乱序/旧 host）时，
    // 在列表尾部补一张可交互审批卡。
    final pending = chat.pendingApproval;
    final needsFallbackCard = pending != null &&
        !chat.items.any((i) => i is ApprovalItem && pending.matches(i.approvalId, i.toolName, i.callId));
    // 尾部行序：审批兜底卡 → 流式 partial（思考过程随对话流滚动，长内容不再挤掉输入框）。
    final tailRows = (needsFallbackCard ? 1 : 0) + (partial != null ? 1 : 0);
    final rowCount = chat.items.length + (chat.hasMore ? 1 : 0) + tailRows;
    return NotificationListener<UserScrollNotification>(
      // 用户一开始拖动就打断程序动画链——流式期间上翻逃逸的关键。
      onNotification: (n) {
        _stick.onUserScroll(n.direction);
        return false;
      },
      child: NotificationListener<ScrollMetricsNotification>(
      // 布局增长（图片加载/流式追加）时贴底重跳——这是「进会话不滚到底」的修复点。
      onNotification: (_) {
        _stick.onMetricsChanged();
        return false;
      },
      child: ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: rowCount,
      itemBuilder: (context, index) {
        if (chat.hasMore && index == 0) {
          return Center(
            child: TextButton(
              onPressed: () => notifier.loadOlder(),
              child: Text(s.loadEarlier),
            ),
          );
        }
        final itemIndex = chat.hasMore ? index - 1 : index;
        if (itemIndex >= chat.items.length) {
          final tail = itemIndex - chat.items.length;
          if (needsFallbackCard && tail == 0) {
            return RepaintBoundary(
              child: _ApprovalCard(
                item: ApprovalItem(
                  seq: -1,
                  approvalId: pending.eventId,
                  toolName: pending.toolName,
                  callId: pending.callId,
                  reason: pending.reason,
                ),
              ),
            );
          }
          // 流式 partial 作为列表最后一行：随对话流滚动。
          return RepaintBoundary(child: _AssistantRow(item: partial!));
        }
        final item = chat.items[itemIndex];
        return RepaintBoundary(
          child: switch (item) {
            UserItem() => _UserBubble(item: item),
            AssistantItem() => _AssistantRow(item: item),
            ToolItem() => _ToolCard(item: item),
            ApprovalItem() => _ApprovalCard(item: item),
            NoticeItem() => _NoticeRow(item: item),
            SystemItem() => _SystemCard(item: item),
          },
        );
      },
        ),
      ),
    );
  }

  Future<void> _pickImages() async {
    final s = ref.read(stringsProvider);
    try {
      final picked = await ImagePicker().pickMultiImage(maxWidth: 1600, imageQuality: 85);
      if (picked.isNotEmpty && mounted) setState(() => _pendingImages.addAll(picked));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.pickImagesFailed(e))));
      }
    }
  }

  String _mediaTypeOf(XFile file) {
    final ext = file.name.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
  }

  Widget _buildComposer(ChatState chat, ChatNotifier notifier) {
    final s = ref.watch(stringsProvider);
    final sendMode = ref.watch(sendModeProvider);
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingImages.isNotEmpty)
              SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pendingImages.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final file = _pendingImages[i];
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: FutureBuilder<Uint8List>(
                            future: file.readAsBytes(),
                            builder: (context, snap) => snap.hasData
                                ? Image.memory(snap.data!, width: 64, height: 64, fit: BoxFit.cover)
                                : const SizedBox(width: 64, height: 64),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => setState(() => _pendingImages.removeAt(i)),
                            child: Container(
                              decoration: BoxDecoration(
                                  color: theme.colorScheme.scrim.withValues(alpha: 0.5),
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  tooltip: s.addImage,
                  onPressed: _pickImages,
                ),
                Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: chat.running
                      ? (sendMode == 'steer' ? s.hintRunningSteer : s.hintRunningQueue)
                      : s.hintInput,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              // 长按 = 与设置相反的模式（默认设置排队，长按插队；反之亦然）
              onLongPress: chat.running && !chat.sending && !widget.isContinuableSubagent
                  ? () => _send(notifier, mode: sendMode == 'steer' ? 'queue' : 'steer')
                  : null,
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: theme.colorScheme.secondary),
                onPressed: chat.sending
                    ? null
                    : () => _send(notifier, mode: chat.running ? sendMode : 'queue'),
                icon: chat.sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const PawIcon(size: 20),
              ),
            ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send(ChatNotifier notifier, {String mode = 'queue'}) async {
    final text = _composer.text;
    if (text.trim().isEmpty && _pendingImages.isEmpty) return;
    _composer.clear();
    final images = _pendingImages.toList();
    setState(() => _pendingImages.clear());
    try {
      final payloads = [
        for (final f in images)
          <String, Object>{
            'bytes': await f.readAsBytes(),
            'mediaType': _mediaTypeOf(f),
            'name': f.name,
          },
      ];
      if (widget.isContinuableSubagent) {
        await notifier.sendSubagentPrompt(widget.parentSessionId!, text);
      } else {
        await notifier.sendPrompt(text, images: payloads, mode: mode);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ref.read(stringsProvider).sendFailed(e))));
        _composer.text = text;
      }
    }
  }

  /// 思考强度选择器：返回强度 id，'' = 恢复默认，null = 取消。
  Future<String?> _pickEffort(
      BuildContext context, S s, List<ModelEffort> efforts, String? current, String? defaultEffort) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(s.thinkingEffort, style: theme.textTheme.titleMedium),
              ),
              for (final e in efforts)
                ListTile(
                  dense: true,
                  title: Text(e.name),
                  subtitle: e.description != null
                      ? Text(e.description!, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  trailing: current == e.id ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, e.id),
                ),
              ListTile(
                dense: true,
                title: Text(s.defaultLabel),
                subtitle: Text(s.effortDefaultDesc(defaultEffort)),
                trailing: current == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, ''),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showModelSheet() async {
    final s = ref.read(stringsProvider);
    // 子代理会话的模型目录被 subagent routing 占用（agent-busy）——优雅提示。
    SessionModels? models;
    try {
      models = await ref.read(sessionModelsProvider(widget.sessionId).future);
    } catch (_) {
      models = null;
    }
    if (!mounted) return;
    if (models == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.modelNotSwitchable)));
      return;
    }
    final modelsData = models;
    models = null; // 释放可变量，后续统一用 modelsData
    final selected = await showModalBottomSheet<ModelCatalogModel>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        // 当前模型的思考强度元数据（用于顶部直达入口）。
        ModelCatalogModel? currentModel;
        for (final g in modelsData.groups) {
          if (g.id != modelsData.current.provider) continue;
          for (final m in g.models) {
            if (m.id == modelsData.current.model) currentModel = m;
          }
        }
        final currentEfforts = currentModel?.reasoning?.efforts ?? const <ModelEffort>[];
        return ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(s.currentModel(modelsData.current.provider, modelsData.current.model) +
                  (modelsData.routable ? '' : s.providerNotRoutable)),
            ),
            if (currentEfforts.isNotEmpty)
              ListTile(
                leading: Icon(Icons.psychology_outlined, color: theme.colorScheme.primary),
                title: Text(s.thinkingEffort),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      modelsData.current.reasoningEffort ??
                          currentModel?.reasoning?.defaultEffort ??
                          s.defaultLabel,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
                onTap: () async {
                  final effort = await _pickEffort(
                    context,
                    s,
                    currentEfforts,
                    modelsData.current.reasoningEffort,
                    currentModel?.reasoning?.defaultEffort,
                  );
                  if (effort == null) return; // 取消
                  if (!context.mounted) return;
                  Navigator.pop(context); // 关掉模型面板
                  try {
                    await selectModel(
                      ref,
                      widget.sessionId,
                      modelsData.current.provider,
                      modelsData.current.model,
                      reasoningEffort: effort.isEmpty ? null : effort,
                    );
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(s.setEffortFailed(e))));
                    }
                  }
                },
              ),
            const Divider(height: 1),
            for (final group in modelsData.groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(group.name, style: theme.textTheme.titleSmall),
              ),
              for (final m in group.models)
                ListTile(
                  dense: true,
                  title: Text(m.name),
                  subtitle: m.description != null
                      ? Text(m.description!, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  trailing: modelsData.current.provider == group.id && modelsData.current.model == m.id
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, m),
                ),
            ],
          ],
        );
      },
    );
    if (selected == null) return;
    final provider = modelsData.groups
        .firstWhere((g) => g.models.any((m) => m.id == selected.id),
            orElse: () => modelsData.groups.first)
        .id;
    // 支持思考强度的模型：点选后再选强度（取消 = 不切换）。
    String? effort;
    final efforts = selected.reasoning?.efforts ?? const <ModelEffort>[];
    if (efforts.isNotEmpty && mounted) {
      final chosen = await _pickEffort(
          context, s, efforts, modelsData.current.reasoningEffort, selected.reasoning?.defaultEffort);
      if (chosen == null) return;
      effort = chosen.isEmpty ? null : chosen;
    }
    try {
      await selectModel(ref, widget.sessionId, provider, selected.id, reasoningEffort: effort);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.setModelFailed(e))));
      }
    }
  }

  Future<void> _onSessionMenu(String value) async {
    final s = ref.read(stringsProvider);
    switch (value) {
      case 'permission':
        final permissions = ref.read(chatProvider(widget.scope)).projections['permissions'];
        if (permissions is! Map<String, dynamic>) return;
        var options = (permissions['options'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
        final current = permissions['currentValue'] as String?;
        // dsh ≥0.1.7 起，可选项从会话投影迁出，改由进程级 permissionPresets/catalog
        // 提供（投影只剩 currentValue）。投影里没有 options 时回退到该端点拉取。
        if (options.isEmpty) {
          final connection = ref.read(connectionProvider);
          if (connection == null) return;
          try {
            final catalog = await connection.api.rpc('permissionPresets/catalog');
            if (catalog is Map) {
              options = ((catalog)['options'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
            }
          } catch (_) {
            // 旧 host 没有该端点：保持空选项，下面统一返回。
          }
        }
        if (options.isEmpty || !mounted) return;
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in options)
                  ListTile(
                    title: Text('${option['name'] ?? option['value']}'),
                    subtitle: option['description'] != null ? Text('${option['description']}') : null,
                    trailing: option['value'] == current ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, '${option['value']}'),
                  ),
              ],
            ),
          ),
        );
        if (chosen != null && chosen != current) {
          try {
            await executeCommand(ref, widget.sessionId, '/permission $chosen');
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.setPermissionFailed(e))));
            }
          }
        }
      case 'subagents':
        await _showSubagentsSheet();
      case 'export':
        final connection = ref.read(connectionProvider);
        if (connection == null) return;
        final uri = Uri.parse(
            '${connection.baseUrl}/api/session.export?sessionId=${widget.sessionId}&includeDescendants=true');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.cannotOpenExport)));
          }
        }
      case 'rename':
        final controller = TextEditingController(text: ref.read(chatProvider(widget.scope)).title);
        final title = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.renameSessionTitle),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
              FilledButton(
                  onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(s.save)),
            ],
          ),
        );
        if (title != null && title.isNotEmpty) {
          await renameSession(ref, widget.sessionId, title);
        }
      case 'fork':
        try {
          final childId = await forkSession(ref, widget.sessionId);
          if (childId != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.forked)));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.forkFailed(e))));
          }
        }
      case 'archive':
        await archiveSession(ref, widget.sessionId);
        if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _showSubagentsSheet() async {
    final s = ref.read(stringsProvider);
    // refresh 强制重取——FutureProvider 会缓存上次结果，sheet 每次打开都要最新列表。
    final entries = await ref.refresh(subagentListProvider(widget.sessionId).future);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(s.noSubagents)),
          );
        }
        return ListView(
          shrinkWrap: true,
          children: [
            for (final entry in entries)
              if (entry.diagnosticReason != null)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.warning_amber, size: 18, color: theme.colorScheme.error),
                  title: Text(s.diagnostic(entry.diagnosticReason!)),
                  subtitle: Text(entry.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                )
              else
                ListTile(
                  dense: true,
                  leading: Icon(
                    entry.activity == 'running' ? Icons.play_circle_outline : Icons.smart_toy_outlined,
                    size: 18,
                    color: entry.activity == 'running' ? theme.colorScheme.tertiary : null,
                  ),
                  title: Text(entry.label ?? entry.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    (entry.mode == 'continuable' ? s.continuable : s.oneshot) +
                        (entry.hasChildren ? s.hasChildren : ''),
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatPage(
                          sessionId: entry.id,
                          parentSessionId:
                              entry.mode == 'continuable' ? widget.sessionId : null,
                          subagentMode: entry.mode,
                        ),
                      ),
                    );
                  },
                ),
          ],
        );
      },
    );
  }

  Future<void> _showQuestionSheet(PendingQuestion pending) async {
    final notifier = ref.read(chatProvider(widget.scope).notifier);
    final answers = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _QuestionSheet(questions: pending.questions),
    );
    if (answers != null) {
      await notifier.answerQuestion(answers);
    }
  }
}

class _UserBubble extends ConsumerWidget {
  const _UserBubble({required this.item});

  final UserItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        // 给头顶的猫耳留出空间
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          decoration: ShapeDecoration(
            color: theme.colorScheme.secondaryContainer,
            shape: CatEarBubbleShape(borderRadius: BorderRadius.circular(18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final attachment in item.images)
                        SessionImage(
                          sessionId: ref.watch(currentSessionIdProvider),
                          attachment: attachment,
                          size: 96,
                          borderRadius: 10,
                        ),
                    ],
                  ),
                ),
              Text(item.text, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantRow extends ConsumerWidget {
  const _AssistantRow({required this.item});

  final AssistantItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sessionId = ref.watch(currentSessionIdProvider);
    final isDark = theme.brightness == Brightness.dark;
    final messageId = item.messageId;
    final rating = messageId == null
        ? null
        : ref.watch(messageFeedbackProvider(sessionId)).valueOrNull?[messageId];
    final bubble = Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.92),
        decoration: BoxDecoration(
          color: isDark ? theme.colorScheme.surfaceContainer : NekoColors.bubbleBlue,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final block in item.blocks) ..._renderBlock(block, theme, sessionId, ref.watch(stringsProvider)),
            if (item.streaming)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            if (rating != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(
                  rating == 'positive' ? Icons.thumb_up_alt : Icons.thumb_down_alt,
                  size: 12,
                  color: rating == 'positive' ? theme.colorScheme.tertiary : theme.colorScheme.error,
                ),
              ),
          ],
        ),
      );
    return Align(
      alignment: Alignment.centerLeft,
      child: messageId == null || item.streaming
          ? bubble
          : GestureDetector(
              onLongPress: () => _showMessageActions(context, ref, sessionId, messageId, rating),
              child: bubble,
            ),
    );
  }

  List<Widget> _renderBlock(AssistantBlock block, ThemeData theme, String sessionId, S s) {
    switch (block) {
      case TextBlock(text: final text):
        if (text.trim().isEmpty) return const [];
        // 流式中的 partial 不开启 selectable，降低每帧重建成本。
        return [MarkdownBody(data: text, selectable: !item.streaming)];
      case ReasoningBlock(text: final text):
        if (text.trim().isEmpty) return const [];
        return [
          _Collapsible(
            icon: Icons.psychology_alt_outlined,
            label: s.thinking,
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ];
      case ToolCallBlock(name: final name, argsRaw: final args):
        return [
          _Collapsible(
            icon: Icons.build_outlined,
            label: s.callTool(name),
            child: Text(args, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ),
        ];
      case ImageBlock(attachment: final attachment):
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SessionImage(
              sessionId: sessionId,
              attachment: attachment,
              size: 200,
              borderRadius: 12,
            ),
          ),
        ];
      case OtherBlock():
        return const [];
    }
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.item});

  final ToolItem item;

  @override
  Widget build(BuildContext context) {
    // read / write / edit / bash 走富文本卡片（diff 面板、语法高亮、终端风输出）。
    switch (item.tool) {
      case 'bash':
        return BashToolCard(item: item);
      case 'read':
        return ReadToolCard(item: item);
      case 'write':
      case 'edit':
        return WriteToolCard(item: item);
    }
    final theme = Theme.of(context);
    final color = !item.finished
        ? theme.colorScheme.onSurfaceVariant
        : item.isError
            ? theme.colorScheme.error
            : theme.colorScheme.tertiary;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: _Collapsible(
        icon: !item.finished
            ? Icons.hourglass_top
            : item.isError
                ? Icons.error_outline
                : Icons.check_circle_outline,
        iconColor: color,
        label: item.name,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.argsRaw.isNotEmpty)
              Text(item.argsRaw,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
            if (item.resultPreview != null) ...[
              const Divider(),
              Text(item.resultPreview!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// 审批卡片（design.md §4 卡片模式）：像一条消息留在列表里。
/// 待决且仍是 host 侧 pending 时显示 批准/拒绝 按钮；已决定的常驻展示结果徽标。
class _ApprovalCard extends ConsumerWidget {
  const _ApprovalCard({required this.item});

  final ApprovalItem item;

  Future<void> _answer(WidgetRef ref, ChatScope scope, bool approved) async {
    await ref.read(chatProvider(scope).notifier).answerApproval(approved);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final outcomeLabels = {
      'allowed-once': s.approved,
      'rejected': s.rejected,
      'cancelled': s.cancelled,
      'unavailable': s.expired,
    };
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scope = ref.watch(currentChatScopeProvider);
    final pending = ref.watch(chatProvider(scope).select((s) => s.pendingApproval));
    // waterfall 请求不带 approvalId，用 toolName+callId 与折叠卡片近似匹配。
    final interactive = pending != null && pending.matches(item.approvalId, item.toolName, item.callId);
    final outcome = item.outcome;

    final (chipLabel, chipColor) = switch (outcome) {
      'allowed-once' => (outcomeLabels[outcome]!, scheme.tertiary),
      'rejected' => (outcomeLabels[outcome]!, scheme.error),
      null => ('', scheme.onSurfaceVariant),
      _ => (outcomeLabels[outcome] ?? outcome, scheme.onSurfaceVariant),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    outcome == null ? s.approveToolQ(item.toolName) : s.approvalOf(item.toolName),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (outcome != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: chipColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: chipColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(chipLabel, style: TextStyle(fontSize: 11, color: chipColor)),
                  ),
              ],
            ),
            if (item.reason != null && item.reason!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(item.reason!, style: theme.textTheme.bodySmall),
            ],
            if (interactive) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _answer(ref, scope, false),
                    child: Text(s.reject),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _answer(ref, scope, true),
                    child: Text(s.approve),
                  ),
                ],
              ),
            ] else if (outcome == null) ...[
              const SizedBox(height: 6),
              Text(
                s.waitingHost,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.item});

  final NoticeItem item;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(item.text, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}

class _Collapsible extends StatefulWidget {
  const _Collapsible({required this.icon, required this.label, required this.child, this.iconColor});

  final IconData icon;
  final Color? iconColor;
  final String label;
  final Widget child;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 14, color: widget.iconColor ?? theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 4),
            child: widget.child,
          ),
      ],
    );
  }
}

class _QueueStrip extends ConsumerWidget {
  const _QueueStrip({required this.queue});

  final List<QueueItem> queue;

  void _removeQueueItem(BuildContext context, QueueItem item) {
    // 从最近的 ProviderScope 读取 sessionId 与 notifier。
    final container = ProviderScope.containerOf(context);
    final scope = container.read(currentChatScopeProvider);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(container.read(stringsProvider).removeFromQueue),
          onTap: () {
            Navigator.pop(context);
            container.read(chatProvider(scope).notifier).updateQueueItem(item.id, remove: true);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final item in queue)
            GestureDetector(
              onLongPress: () => _removeQueueItem(context, item),
              child: Chip(
                avatar: Icon(
                  item.placement == 'steering' ? Icons.alt_route : Icons.schedule,
                  size: 14,
                ),
                label: Text(item.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

class _QuestionSheet extends ConsumerStatefulWidget {
  const _QuestionSheet({required this.questions});

  final List<QuestionItem> questions;

  @override
  ConsumerState<_QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends ConsumerState<_QuestionSheet> {
  /// question id -> selected labels
  final Map<String, Set<String>> _selected = {};

  /// question id -> custom text
  final Map<String, String> _custom = {};

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final q in widget.questions) ...[
              if (q.header != null)
                Text(q.header!, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
              Text(q.question, style: theme.textTheme.titleMedium),
              if (q.detail != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(q.detail!, style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 8),
              for (final option in q.options)
                _OptionTile(
                  option: option,
                  selected: _selected[q.id]?.contains(option.label) ?? false,
                  onTap: () => setState(() {
                    final set = _selected.putIfAbsent(q.id, () => {});
                    if (q.multiSelect) {
                      set.contains(option.label) ? set.remove(option.label) : set.add(option.label);
                    } else {
                      set
                        ..clear()
                        ..add(option.label);
                    }
                  }),
                ),
              TextField(
                decoration: InputDecoration(
                  labelText: s.customAnswer,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => _custom[q.id] = value,
              ),
              const SizedBox(height: 20),
            ],
            FilledButton(
              onPressed: _canSubmit() ? _submit : null,
              child: Text(s.submit),
            ),
          ],
        ),
      ),
    );
  }

  bool _canSubmit() {
    for (final q in widget.questions) {
      final hasSelection = (_selected[q.id]?.isNotEmpty ?? false);
      final hasCustom = (_custom[q.id]?.trim().isNotEmpty ?? false);
      if (!hasSelection && !hasCustom) return false;
    }
    return true;
  }

  void _submit() {
    final answers = [
      for (final q in widget.questions)
        {
          'id': q.id,
          'selected': (_selected[q.id] ?? const <String>{}).toList(),
          if ((_custom[q.id]?.trim().isNotEmpty ?? false)) 'custom': _custom[q.id]!.trim(),
        },
    ];
    Navigator.pop(context, answers);
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.option, required this.selected, required this.onTap});

  final QuestionOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: selected ? theme.colorScheme.secondaryContainer : null,
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.label),
                    if (option.description != null)
                      Text(option.description!, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `/` 前缀技能自动补全条（输入以 / 开头且不含空格时出现）。
class _SkillSuggestions extends ConsumerWidget {
  const _SkillSuggestions({required this.sessionId, required this.controller});

  /// 传「代理会话」id：子代理页应传父会话（子代理 id 会被 skill.list /
  /// commands.list 的 resolver 拒绝）。
  final String sessionId;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // valueOrNull：AsyncError.value 会重新抛错，直接把整棵 Column 炸掉。
    final skills = ref.watch(skillListProvider(sessionId)).valueOrNull ?? const <SkillEntry>[];
    final commands = ref.watch(commandListProvider(sessionId)).valueOrNull ?? const <CommandEntry>[];
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        var text = value.text;
        if (text.startsWith('／')) text = '/${text.substring(1)}';
        if (!text.startsWith('/') || text.contains(' ') || text.isEmpty) {
          return const SizedBox.shrink();
        }
        final query = text.substring(1).toLowerCase();
        // 技能与斜杠命令合并成一个面板。
        final entries = <({String name, String description, IconData icon})>[
          for (final c in commands)
            if (query.isEmpty || c.name.toLowerCase().contains(query))
              (name: c.name, description: c.description, icon: Icons.bolt),
          for (final sk in skills)
            if (query.isEmpty || sk.name.toLowerCase().contains(query))
              (name: sk.name, description: sk.description, icon: Icons.auto_awesome),
        ].take(8).toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Container(
          constraints: const BoxConstraints(maxHeight: 200),
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final entry = entries[i];
              return InkWell(
                onTap: () {
                  controller.text = '/${entry.name} ';
                  controller.selection = TextSelection.collapsed(offset: controller.text.length);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(entry.icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('/${entry.name}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                            Text(entry.description,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 进行中的目标横幅（goal 投影驱动）。
class _GoalBanner extends ConsumerWidget {
  const _GoalBanner({required this.scope, required this.goal});

  final ChatScope scope;
  final GoalView goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final (icon, label, color) = switch (goal.phase) {
      'active' => (Icons.flag, s.goalInProgress, theme.colorScheme.tertiary),
      'paused' => (Icons.pause_circle_outline, s.goalPaused, theme.colorScheme.secondary),
      'blocked' => (Icons.error_outline, s.goalBlocked, theme.colorScheme.error),
      'complete' => (Icons.check_circle_outline, s.goalComplete, theme.colorScheme.primary),
      _ => (Icons.flag_outlined, goal.phase, theme.colorScheme.outline),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${goal.objective}${goal.maxGoalRounds > 0 ? s.goalRounds(goal.roundsStarted, goal.maxGoalRounds) : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (goal.phase == 'active')
            IconButton(
              icon: const Icon(Icons.pause, size: 18),
              tooltip: s.pauseGoal,
              onPressed: () => ref.read(chatProvider(scope).notifier).goalAction('pause'),
            ),
          if (goal.phase == 'paused' || goal.phase == 'blocked')
            IconButton(
              icon: const Icon(Icons.play_arrow, size: 18),
              tooltip: s.resumeGoal,
              onPressed: () => ref.read(chatProvider(scope).notifier).goalAction('resume'),
            ),
          if (goal.phase == 'active' || goal.phase == 'paused')
            IconButton(
              icon: const Icon(Icons.check, size: 18),
              tooltip: s.completeGoal,
              onPressed: () => ref.read(chatProvider(scope).notifier).goalAction('complete'),
            ),
          if (goal.phase == 'complete' || goal.phase == 'blocked')
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: s.dismissGoalBanner,
              onPressed: () => ref.read(chatProvider(scope).notifier).goalAction('clear'),
            ),
        ],
      ),
    );
  }
}

/// 历史图片：`session.attachment` 按引用取 base64 并缓存渲染。
class SessionImage extends ConsumerWidget {
  const SessionImage({
    super.key,
    required this.sessionId,
    required this.attachment,
    this.size = 96,
    this.borderRadius = 10,
  });

  final String sessionId;
  final Map<String, dynamic> attachment;
  final double size;
  final double borderRadius;

  static final Map<String, Uint8List> _cache = {};

  String get _id => attachment['attachmentId'] as String? ?? '';

  Future<Uint8List> _load(WidgetRef ref) async {
    final cached = _cache[_id];
    if (cached != null) return cached;
    final connection = ref.read(connectionProvider);
    if (connection == null) throw StateError(ref.read(stringsProvider).notConnected);
    final value = await connection.api.rpc('session/attachment', {
      'request': {'sessionId': sessionId, 'attachmentId': _id},
    });
    final data = (value as Map)['data'] as String;
    final bytes = base64Decode(data);
    _cache[_id] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () async {
        final bytes = _cache[_id] ?? await _load(ref);
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            child: InteractiveViewer(child: Image.memory(bytes)),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: FutureBuilder<Uint8List>(
          future: _cache[_id] != null ? Future.value(_cache[_id]) : _load(ref),
          builder: (context, snap) {
            if (snap.hasError) {
              return Container(
                width: size,
                height: size,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(Icons.broken_image_outlined, color: theme.colorScheme.outline),
              );
            }
            if (!snap.hasData) {
              return Container(
                width: size,
                height: size,
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
              );
            }
            return Image.memory(snap.data!, width: size, height: size, fit: BoxFit.cover);
          },
        ),
      ),
    );
  }
}

/// 助手消息长按 → 反馈（赞/踩 + 备注），messageFeedback/put。
class _FeedbackSheet extends ConsumerStatefulWidget {
  const _FeedbackSheet({required this.sessionId, required this.messageId, this.current});

  final String sessionId;
  final String messageId;
  final String? current;

  @override
  ConsumerState<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends ConsumerState<_FeedbackSheet> {
  String? _rating;
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _rating = widget.current;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.feedbackQuestion, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _RatingButton(
                    icon: Icons.thumb_up_alt_outlined,
                    label: s.helpful,
                    selected: _rating == 'positive',
                    color: theme.colorScheme.tertiary,
                    onTap: () => setState(() => _rating = 'positive'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _RatingButton(
                    icon: Icons.thumb_down_alt_outlined,
                    label: s.problematic,
                    selected: _rating == 'negative',
                    color: theme.colorScheme.error,
                    onTap: () => setState(() => _rating = 'negative'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: InputDecoration(labelText: s.feedbackNote),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _rating == null
                  ? null
                  : () async {
                      try {
                        await putFeedback(ref, widget.sessionId, widget.messageId, _rating!,
                            note: _note.text.trim().isEmpty ? null : _note.text.trim());
                        if (!context.mounted) return;
                        Navigator.pop(context);
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(s.feedbackFailed(e))));
                      }
                    },
              child: Text(s.feedbackSubmit),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingButton extends StatelessWidget {
  const _RatingButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: selected ? color : null),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: selected ? color : Theme.of(context).colorScheme.outlineVariant),
        backgroundColor: selected ? color.withValues(alpha: 0.12) : null,
      ),
    );
  }
}

/// 待办条：`todos` 投影（todo/write 的最新整表，turn/start 清空）。
/// 折叠显示进度，点击展开每项状态。
class _TodoBar extends ConsumerStatefulWidget {
  const _TodoBar({required this.projections});

  final Map<String, dynamic> projections;

  @override
  ConsumerState<_TodoBar> createState() => _TodoBarState();
}

class _TodoBarState extends ConsumerState<_TodoBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final raw = widget.projections['todos'];
    if (raw is! List) return const SizedBox.shrink();
    final todos = raw.whereType<Map<String, dynamic>>().toList();
    if (todos.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final done = todos.where((t) => t['status'] == 'completed').length;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.task_alt, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s.todoProgress(done, todos.length), style: theme.textTheme.bodySmall)),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (_expanded)
            for (final todo in todos)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(
                  children: [
                    Icon(
                      switch (todo['status']) {
                        'completed' => Icons.check_circle,
                        'in_progress' => Icons.timelapse,
                        _ => Icons.radio_button_unchecked,
                      },
                      size: 14,
                      color: switch (todo['status']) {
                        'completed' => theme.colorScheme.tertiary,
                        'in_progress' => theme.colorScheme.secondary,
                        _ => theme.colorScheme.onSurfaceVariant,
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${todo['content'] ?? ''}',
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// 计划模式横幅：`plan` 投影 {active, pending}。
class _PlanBanner extends ConsumerWidget {
  const _PlanBanner({required this.projections});

  final Map<String, dynamic> projections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final raw = projections['plan'];
    if (raw is! Map<String, dynamic>) return const SizedBox.shrink();
    final active = raw['active'] == true;
    final pending = raw['pending'] == true;
    if (!active && !pending) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.assignment_outlined, size: 16, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pending ? s.planModePending : s.planModeActive,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// 后台任务条（session/jobs 快照）：运行中的 bash 任务等。
class _JobsStrip extends StatelessWidget {
  const _JobsStrip({required this.jobs});

  final List<Map<String, dynamic>> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final job in jobs)
            Chip(
              avatar: Icon(
                switch (job['kind']) {
                  'bash' => Icons.terminal,
                  'subagent' => Icons.account_tree_outlined,
                  _ => Icons.work_outline,
                },
                size: 14,
              ),
              label: Text('${job['label'] ?? job['id']} · ${job['status']}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// 助手消息长按操作菜单：复制全文 / 反馈。
void _showMessageActions(
    BuildContext context, WidgetRef ref, String sessionId, String messageId, String? rating) {
  final s = ref.read(stringsProvider);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: Text(s.copyAll),
            onTap: () async {
              final chat = ref.read(chatProvider(ref.watch(currentChatScopeProvider)));
              final item = chat.items.whereType<AssistantItem>().where((i) => i.messageId == messageId).firstOrNull;
              if (item != null) {
                final text = item.blocks
                    .map((b) => switch (b) {
                          TextBlock() => b.text,
                          ReasoningBlock() => b.text,
                          ToolCallBlock() => s.toolCallSnippet(b.name),
                          ImageBlock() => s.imageSnippet,
                          OtherBlock() => '',
                        })
                    .where((t) => t.isNotEmpty)
                    .join('\n\n');
                await Clipboard.setData(ClipboardData(text: text));
              }
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(s.copiedToClipboard), duration: const Duration(seconds: 1)),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.thumbs_up_down_outlined),
            title: Text(s.feedbackTooltip),
            onTap: () {
              Navigator.pop(sheetContext);
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) =>
                    _FeedbackSheet(sessionId: sessionId, messageId: messageId, current: rating),
              );
            },
          ),
        ],
      ),
    ),
  );
}

/// 系统注入消息卡片（子代理通报等）：左侧小图标 + 灰底，长文可折叠。
class _SystemCard extends ConsumerStatefulWidget {
  const _SystemCard({required this.item});

  final SystemItem item;

  @override
  ConsumerState<_SystemCard> createState() => _SystemCardState();
}

class _SystemCardState extends ConsumerState<_SystemCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final (icon, label) = switch (widget.item.kind) {
      'subagent-report' => (Icons.smart_toy_outlined, s.subagentReport),
      'subagent-settled' => (Icons.check_circle_outline, s.subagentDone),
      _ => (Icons.info_outline, s.systemKind),
    };
    final long = widget.item.text.length > 160;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(label,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
              if (long) ...[
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.item.text,
            maxLines: _expanded || !long ? null : 4,
            overflow: _expanded || !long ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 模型工作中的等待提示：思考中的猫娘插图 + 俏皮文案 + 省略号动画。
class _WorkingIndicator extends ConsumerStatefulWidget {
  const _WorkingIndicator();

  @override
  ConsumerState<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends ConsumerState<_WorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dots;

  @override
  void initState() {
    super.initState();
    _dots = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = ref.watch(stringsProvider).workingHints;
    final theme = Theme.of(context);
    // 按时间轮播文案（每 3 秒一条）
    final line = copy[(DateTime.now().millisecondsSinceEpoch ~/ 3000) % copy.length];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset(
              'assets/illustrations/neko_thinking.png',
              width: 36,
              height: 36,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          AnimatedBuilder(
            animation: _dots,
            builder: (context, _) {
              final n = (_dots.value * 3).floor() % 3 + 1;
              return Text(
                '· ' * n,
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 上下文占用进度条（design.md：薄荷→奶蓝→西瓜红三档语义色）。
/// 数据源：`contextPressure` 投影（token-meter 包）：projectedTokens ?? pressureTokens
/// 是近似占用（last-wins 参考值），contextWindow 为模型窗口容量。
class _ContextUsageBar extends StatelessWidget implements PreferredSizeWidget {
  const _ContextUsageBar({required this.usedTokens, required this.contextWindow});

  final int usedTokens;
  final int contextWindow;

  /// 从会话投影构建；数据不足时不占位。
  static PreferredSizeWidget? fromProjections(Map<String, dynamic> projections) {
    final raw = projections['contextPressure'];
    if (raw is! Map<String, dynamic>) return null;
    final used = (raw['projectedTokens'] as num?)?.toInt() ?? (raw['pressureTokens'] as num?)?.toInt();
    final window = (raw['contextWindow'] as num?)?.toInt();
    if (used == null || window == null || window <= 0) return null;
    return _ContextUsageBar(usedTokens: used, contextWindow: window);
  }

  static String _fmt(int tokens) {
    if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
    return '$tokens';
  }

  @override
  Size get preferredSize => const Size.fromHeight(18);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = (usedTokens / contextWindow).clamp(0.0, 1.0);
    final percent = (ratio * 100).round();
    final color = percent < 60
        ? scheme.tertiary
        : percent < 85
            ? scheme.primary
            : scheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 5,
                backgroundColor: scheme.surfaceContainerHigh,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_fmt(usedTokens)}/${_fmt(contextWindow)} · $percent%',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
