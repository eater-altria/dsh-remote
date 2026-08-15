import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/fold.dart';
import '../api/models.dart';
import '../state/providers.dart';
import 'theme.dart';

/// Chat surface for one session: history, streaming replies, tool cards,
/// question / approval interactions, and the composer.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

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
            OtherBlock() => 0,
          }),
      UserItem() => last.text.length,
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

    return Scaffold(
      appBar: AppBar(
        title: Text(chat.title ?? '会话'),
        actions: [
          if (chat.running)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '停止当前回合',
              onPressed: () => notifier.cancel(),
            ),
          IconButton(
            icon: const Icon(Icons.model_training),
            tooltip: '选择模型',
            onPressed: () => _showModelSheet(),
          ),
          PopupMenuButton<String>(
            onSelected: _onSessionMenu,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'fork', child: Text('分叉会话')),
              PopupMenuItem(value: 'archive', child: Text('归档')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (chat.goal != null && chat.goal!.exists) _GoalBanner(sessionId: widget.sessionId, goal: chat.goal!),
          Expanded(child: _buildList(chat, notifier)),
          if (chat.queue.isNotEmpty) _QueueStrip(queue: chat.queue),
          _SkillSuggestions(sessionId: widget.sessionId, controller: _composer),
          _buildComposer(chat, notifier),
        ],
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
        return switch (item) {
          UserItem() => _UserBubble(item: item),
          AssistantItem() => _AssistantRow(item: item),
          ToolItem() => _ToolCard(item: item),
          NoticeItem() => _NoticeRow(item: item),
        };
      },
    );
  }

  Widget _buildComposer(ChatState chat, ChatNotifier notifier) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: chat.running ? '发送将排队等待当前回合…' : '输入消息…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: theme.colorScheme.secondary),
              onPressed: chat.sending
                  ? null
                  : () async {
                      final text = _composer.text;
                      if (text.trim().isEmpty) return;
                      _composer.clear();
                      try {
                        await notifier.sendPrompt(text);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('发送失败: $e')));
                          _composer.text = text;
                        }
                      }
                    },
              icon: chat.sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const PawIcon(size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showModelSheet() async {
    final models = await ref.read(sessionModelsProvider(widget.sessionId).future);
    if (!mounted) return;
    final selected = await showModalBottomSheet<ModelCatalogModel>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('当前：${models.current.provider} / ${models.current.model}'
                  '${models.routable ? '' : '（当前 provider 不可路由）'}'),
            ),
            for (final group in models.groups) ...[
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
                  trailing: models.current.provider == group.id && models.current.model == m.id
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, m),
                ),
            ],
          ],
        );
      },
    );
    if (selected != null) {
      final provider = models.groups
          .firstWhere((g) => g.models.any((m) => m.id == selected.id),
              orElse: () => models.groups.first)
          .id;
      try {
        await selectModel(ref, widget.sessionId, provider, selected.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切换模型失败: $e')));
        }
      }
    }
  }

  Future<void> _onSessionMenu(String value) async {
    switch (value) {
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

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.item});

  final UserItem item;

  @override
  Widget build(BuildContext context) {
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
              if (item.imageCount > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('📷 ×${item.imageCount}', style: theme.textTheme.bodySmall),
                ),
              Text(item.text, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantRow extends StatelessWidget {
  const _AssistantRow({required this.item});

  final AssistantItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
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
            for (final block in item.blocks) ..._renderBlock(block, theme),
            if (item.streaming)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _renderBlock(AssistantBlock block, ThemeData theme) {
    switch (block) {
      case TextBlock(text: final text):
        if (text.trim().isEmpty) return const [];
        return [MarkdownBody(data: text, selectable: true)];
      case ReasoningBlock(text: final text):
        if (text.trim().isEmpty) return const [];
        return [
          _Collapsible(
            icon: Icons.psychology_alt_outlined,
            label: '思考过程',
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
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
        ? theme.colorScheme.outline
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
                Icon(widget.icon, size: 14, color: widget.iconColor ?? theme.colorScheme.outline),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.label,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14, color: theme.colorScheme.outline),
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

class _QueueStrip extends StatelessWidget {
  const _QueueStrip({required this.queue});

  final List<QueueItem> queue;

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
          for (final item in queue)
            Chip(
              avatar: Icon(
                item.placement == 'steering' ? Icons.alt_route : Icons.schedule,
                size: 14,
              ),
              label: Text(item.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              visualDensity: VisualDensity.compact,
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

  final String sessionId;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skills = ref.watch(skillListProvider(sessionId)).value ?? const <SkillEntry>[];
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        var text = value.text;
        if (text.startsWith('／')) text = '/${text.substring(1)}';
        if (!text.startsWith('/') || text.contains(' ') || text.length < 2) {
          return const SizedBox.shrink();
        }
        final query = text.substring(1).toLowerCase();
        final matches = skills.where((s) => s.name.toLowerCase().contains(query)).take(6).toList();
        if (matches.isEmpty) return const SizedBox.shrink();
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
            itemCount: matches.length,
            itemBuilder: (context, i) {
              final skill = matches[i];
              return InkWell(
                onTap: () {
                  controller.text = '/${skill.name} ';
                  controller.selection = TextSelection.collapsed(offset: controller.text.length);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('/${skill.name}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                      Text(skill.description,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
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
