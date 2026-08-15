import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/fold.dart';
import '../api/models.dart';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../state/providers.dart';
import 'theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Chat surface for one session: history, streaming replies, tool cards,
/// question / approval interactions, and the composer.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.sessionId, this.parentSessionId, this.subagentMode});

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
  final _scroll = ScrollController();
  final List<XFile> _pendingImages = [];
  final Stopwatch _entryWatch = Stopwatch()..start();
  bool _entryLogged = false;

  /// 贴底状态：用户在底部附近时，新内容到达自动跟随；往上翻则停止跟随。
  bool _stickToBottom = true;
  int _lastContentSignature = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _stickToBottom = position.pixels >= position.maxScrollExtent - 120;
  }

  /// 内容签名：条目数 + 最后一条的长度（流式增长时条数不变但内容在变）。
  int _contentSignature(ChatState chat) {
    final items = chat.items;
    if (items.isEmpty) return 0;
    final last = items.last;
    final lastSize = switch (last) {
      AssistantItem() => last.blocks.fold<int>(0, (sum, b) => sum + switch (b) {
            TextBlock() => b.text.length,
            ReasoningBlock() => b.text.length,
            ToolCallBlock() => b.argsRaw.length,
            ImageBlock() => 1,
            OtherBlock() => 0,
          }),
      UserItem() => last.text.length,
      SystemItem() => last.text.length,
      ToolItem() => last.resultPreview?.length ?? 0,
      NoticeItem() => last.text.length,
    };
    return items.length * 1000000 + lastSize;
  }

  void _maybeScrollToEnd(ChatState chat) {
    final signature = _contentSignature(chat);
    if (signature == _lastContentSignature) return;
    _lastContentSignature = signature;
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd(animate: true));
  }

  void _jumpToEnd({bool animate = false}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider(widget.sessionId));
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);
    _maybeScrollToEnd(chat);
    if (!_entryLogged && !chat.loadingHistory && chat.items.isNotEmpty) {
      _entryLogged = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('[perf] chat first content frame: ${_entryWatch.elapsedMilliseconds}ms since page create');
      });
    }

    // 尾部历史页加载完成 → 直接跳到底部（不等动画）。
    ref.listen(chatProvider(widget.sessionId).select((s) => s.scrollSignal), (_, _) {
      _stickToBottom = true;
      // 两帧后列表已完成布局，maxScrollExtent 才是终值。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToEnd();
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
      });
    });

    // Surface pending interactions.
    ref.listen(chatProvider(widget.sessionId).select((s) => s.pendingQuestion), (_, next) {
      if (next != null) _showQuestionSheet(next);
    });
    ref.listen(chatProvider(widget.sessionId).select((s) => s.pendingApproval), (_, next) {
      if (next != null) _showApprovalDialog(next);
    });

    return ProviderScope(
      overrides: [currentSessionIdProvider.overrideWithValue(widget.sessionId)],
      child: Scaffold(
        appBar: AppBar(
          title: Text(chat.title ?? '会话'),
        actions: [
          if (chat.running)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: widget.isContinuableSubagent ? '打断子代理' : '停止当前回合',
              onPressed: () => widget.isContinuableSubagent
                  ? notifier.interruptSubagent(widget.parentSessionId!)
                  : notifier.cancel(),
            ),
          IconButton(
            icon: const Icon(Icons.model_training),
            tooltip: '选择模型',
            onPressed: () => _showModelSheet(),
          ),
          PopupMenuButton<String>(
            onSelected: _onSessionMenu,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'permission', child: Text('权限模式')),
              PopupMenuItem(value: 'subagents', child: Text('子代理')),
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'fork', child: Text('分叉会话')),
              PopupMenuItem(value: 'export', child: Text('导出会话日志')),
              PopupMenuItem(value: 'archive', child: Text('归档')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (chat.goal != null && chat.goal!.exists) _GoalBanner(sessionId: widget.sessionId, goal: chat.goal!),
          _PlanBanner(projections: chat.projections),
          _TodoBar(projections: chat.projections),
          Expanded(child: _buildList(chat, notifier)),
          // 流式区独立于消息列表（kimi-remote 模式）：chunk 更新只重建这一块，
          // 不再触碰上方整表。
          if (chat.fold?.partial != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _AssistantRow(item: chat.fold!.partial!),
            ),
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
    if (chat.loadingHistory && chat.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (chat.historyError != null && chat.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('历史加载失败\n${chat.historyError}', textAlign: TextAlign.center),
        ),
      );
    }
    if (chat.items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NekoMascot(size: 72),
            SizedBox(height: 12),
            Text('开始新的对话吧'),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: chat.items.length + (chat.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (chat.hasMore && index == 0) {
          return Center(
            child: TextButton(
              onPressed: () => notifier.loadOlder(),
              child: const Text('加载更早的消息'),
            ),
          );
        }
        final item = chat.items[chat.hasMore ? index - 1 : index];
        return RepaintBoundary(
          child: switch (item) {
            UserItem() => _UserBubble(item: item),
            AssistantItem() => _AssistantRow(item: item),
            ToolItem() => _ToolCard(item: item),
            NoticeItem() => _NoticeRow(item: item),
            SystemItem() => _SystemCard(item: item),
          },
        );
      },
    );
  }

  Future<void> _pickImages() async {
    try {
      final picked = await ImagePicker().pickMultiImage(maxWidth: 1600, imageQuality: 85);
      if (picked.isNotEmpty && mounted) setState(() => _pendingImages.addAll(picked));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择图片失败: $e')));
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
                  tooltip: '添加图片',
                  onPressed: _pickImages,
                ),
                Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: chat.running ? '发送将排队；长按 🐾 立即插队（steer）' : '输入消息…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              // 运行中长按 = steering：立即插入当前回合，而不是排队
              onLongPress: chat.running && !chat.sending && !widget.isContinuableSubagent
                  ? () => _send(notifier, mode: 'steer')
                  : null,
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: theme.colorScheme.secondary),
                onPressed: chat.sending ? null : () => _send(notifier),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
        _composer.text = text;
      }
    }
  }

  /// 思考强度选择器：返回强度 id，'' = 恢复默认，null = 取消。
  Future<String?> _pickEffort(
      BuildContext context, List<ModelEffort> efforts, String? current, String? defaultEffort) {
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
                child: Text('思考强度', style: theme.textTheme.titleMedium),
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
                title: const Text('默认'),
                subtitle: Text('使用适配器默认（${defaultEffort ?? "适配器决定"}）'),
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
          .showSnackBar(const SnackBar(content: Text('该会话不支持切换模型（子代理的组合由父会话决定）')));
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
              child: Text('当前：${modelsData.current.provider} / ${modelsData.current.model}'
                  '${modelsData.routable ? '' : '（当前 provider 不可路由）'}'),
            ),
            if (currentEfforts.isNotEmpty)
              ListTile(
                leading: Icon(Icons.psychology_outlined, color: theme.colorScheme.primary),
                title: const Text('思考强度'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      modelsData.current.reasoningEffort ??
                          currentModel?.reasoning?.defaultEffort ??
                          '默认',
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
                          .showSnackBar(SnackBar(content: Text('切换思考强度失败: $e')));
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
          context, efforts, modelsData.current.reasoningEffort, selected.reasoning?.defaultEffort);
      if (chosen == null) return;
      effort = chosen.isEmpty ? null : chosen;
    }
    try {
      await selectModel(ref, widget.sessionId, provider, selected.id, reasoningEffort: effort);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切换模型失败: $e')));
      }
    }
  }

  Future<void> _onSessionMenu(String value) async {
    switch (value) {
      case 'permission':
        final permissions = ref.read(chatProvider(widget.sessionId)).projections['permissions'];
        if (permissions is! Map<String, dynamic>) return;
        final options = (permissions['options'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
        final current = permissions['currentValue'] as String?;
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
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切换权限模式失败: $e')));
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法打开导出链接')));
          }
        }
      case 'rename':
        final controller = TextEditingController(text: ref.read(chatProvider(widget.sessionId)).title);
        final title = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重命名会话'),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('保存')),
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已分叉为新会话')));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分叉失败: $e')));
          }
        }
      case 'archive':
        await archiveSession(ref, widget.sessionId, archived: true);
        if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _showSubagentsSheet() async {
    // refresh 强制重取——FutureProvider 会缓存上次结果，sheet 每次打开都要最新列表。
    final entries = await ref.refresh(subagentListProvider(widget.sessionId).future);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        if (entries.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('这个会话还没有子代理')),
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
                  title: Text('诊断：${entry.diagnosticReason}'),
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
                    '${entry.mode == 'continuable' ? '可续聊' : '一次性'}'
                    '${entry.hasChildren ? ' · 有子级' : ''}',
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
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);
    final answers = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _QuestionSheet(questions: pending.questions),
    );
    if (answers != null) {
      await notifier.answerQuestion(answers);
    }
  }

  Future<void> _showApprovalDialog(PendingApproval pending) async {
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.shield_outlined),
        title: Text('批准 ${pending.toolName} ?'),
        content: Text(pending.reason ?? '该工具调用需要你的批准。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('拒绝')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('批准')),
        ],
      ),
    );
    if (approved != null) {
      await notifier.answerApproval(approved);
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
            for (final block in item.blocks) ..._renderBlock(block, theme, sessionId),
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

  List<Widget> _renderBlock(AssistantBlock block, ThemeData theme, String sessionId) {
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
            label: '思考过程',
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ];
      case ToolCallBlock(name: final name, argsRaw: final args):
        return [
          _Collapsible(
            icon: Icons.build_outlined,
            label: '调用 $name',
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
    final sessionId = container.read(currentSessionIdProvider);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('从队列移除'),
          onTap: () {
            Navigator.pop(context);
            container.read(chatProvider(sessionId).notifier).updateQueueItem(item.id, remove: true);
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

class _QuestionSheet extends StatefulWidget {
  const _QuestionSheet({required this.questions});

  final List<QuestionItem> questions;

  @override
  State<_QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<_QuestionSheet> {
  /// question id -> selected labels
  final Map<String, Set<String>> _selected = {};

  /// question id -> custom text
  final Map<String, String> _custom = {};

  @override
  Widget build(BuildContext context) {
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
                decoration: const InputDecoration(
                  labelText: '自定义回答（可选）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => _custom[q.id] = value,
              ),
              const SizedBox(height: 20),
            ],
            FilledButton(
              onPressed: _canSubmit() ? _submit : null,
              child: const Text('提交'),
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
  const _GoalBanner({required this.sessionId, required this.goal});

  final String sessionId;
  final GoalView goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (icon, label, color) = switch (goal.phase) {
      'active' => (Icons.flag, '进行中', theme.colorScheme.tertiary),
      'paused' => (Icons.pause_circle_outline, '已暂停', theme.colorScheme.secondary),
      'blocked' => (Icons.error_outline, '受阻', theme.colorScheme.error),
      'complete' => (Icons.check_circle_outline, '已完成', theme.colorScheme.primary),
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
              '${goal.objective}${goal.maxGoalRounds > 0 ? '（${goal.roundsStarted}/${goal.maxGoalRounds} 轮）' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (goal.phase == 'active')
            IconButton(
              icon: const Icon(Icons.pause, size: 18),
              tooltip: '暂停目标',
              onPressed: () => ref.read(chatProvider(sessionId).notifier).goalAction('pause'),
            ),
          if (goal.phase == 'paused' || goal.phase == 'blocked')
            IconButton(
              icon: const Icon(Icons.play_arrow, size: 18),
              tooltip: '恢复目标',
              onPressed: () => ref.read(chatProvider(sessionId).notifier).goalAction('resume'),
            ),
          if (goal.phase == 'active' || goal.phase == 'paused')
            IconButton(
              icon: const Icon(Icons.check, size: 18),
              tooltip: '标记完成',
              onPressed: () => ref.read(chatProvider(sessionId).notifier).goalAction('complete'),
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
    if (connection == null) throw StateError('未连接');
    final value = await connection.api.rpc('session.attachment', {
      'sessionId': sessionId,
      'attachmentId': _id,
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
            Text('这条回答怎么样？', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _RatingButton(
                    icon: Icons.thumb_up_alt_outlined,
                    label: '有帮助',
                    selected: _rating == 'positive',
                    color: theme.colorScheme.tertiary,
                    onTap: () => setState(() => _rating = 'positive'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _RatingButton(
                    icon: Icons.thumb_down_alt_outlined,
                    label: '有问题',
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
              decoration: const InputDecoration(labelText: '备注（可选）'),
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
                            .showSnackBar(SnackBar(content: Text('提交失败: $e')));
                      }
                    },
              child: const Text('提交反馈'),
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
class _TodoBar extends StatefulWidget {
  const _TodoBar({required this.projections});

  final Map<String, dynamic> projections;

  @override
  State<_TodoBar> createState() => _TodoBarState();
}

class _TodoBarState extends State<_TodoBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
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
                  Expanded(child: Text('任务清单 $done/${todos.length}', style: theme.textTheme.bodySmall)),
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
class _PlanBanner extends StatelessWidget {
  const _PlanBanner({required this.projections});

  final Map<String, dynamic> projections;

  @override
  Widget build(BuildContext context) {
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
              pending ? '计划模式（等待生效）' : '计划模式：先出方案再动手',
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
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('复制全文'),
            onTap: () async {
              final chat = ref.read(chatProvider(sessionId));
              final item = chat.items.whereType<AssistantItem>().where((i) => i.messageId == messageId).firstOrNull;
              if (item != null) {
                final text = item.blocks
                    .map((b) => switch (b) {
                          TextBlock() => b.text,
                          ReasoningBlock() => b.text,
                          ToolCallBlock() => '[工具调用 \${b.name}]',
                          ImageBlock() => '[图片]',
                          OtherBlock() => '',
                        })
                    .where((t) => t.isNotEmpty)
                    .join('\n\n');
                await Clipboard.setData(ClipboardData(text: text));
              }
              if (sheetContext.mounted) {
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.thumbs_up_down_outlined),
            title: const Text('反馈（赞/踩）'),
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
class _SystemCard extends StatefulWidget {
  const _SystemCard({required this.item});

  final SystemItem item;

  @override
  State<_SystemCard> createState() => _SystemCardState();
}

class _SystemCardState extends State<_SystemCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = switch (widget.item.kind) {
      'subagent-report' => (Icons.smart_toy_outlined, '子代理汇报'),
      'subagent-settled' => (Icons.check_circle_outline, '子代理完成'),
      _ => (Icons.info_outline, '系统'),
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
