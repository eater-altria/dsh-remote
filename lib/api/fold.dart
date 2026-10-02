library;

import 'dart:convert';

/// Session-event fold: turns the durable event log (`session.history`) and
/// live mux frames (`session/event`) into a renderable chat item list.
///
/// Mirrors the web client's core fold, simplified:
/// - `user/message` (append surface) -> user bubble
/// - `assistant/chunk` -> streaming partial assistant blocks (indexed)
/// - `assistant/message` (append surface) -> finalized assistant message
/// - `tool/call` / `tool/result` -> tool cards (paired by callId)
/// - `approval/asked` / `approval/decided` -> approval cards (paired by id, 常驻展示结果)
/// - `turn/start` / `turn/end` -> running flag
/// - `session/title` -> title
/// - `compaction/summary`, `command/run` -> system notices

/// One UI-classified assistant content block (mirrors the web client's
/// `toAssistantBlocks` classification).
sealed class AssistantBlock {
  const AssistantBlock();
}

class TextBlock extends AssistantBlock {
  const TextBlock(this.text);
  final String text;
}

class ReasoningBlock extends AssistantBlock {
  const ReasoningBlock(this.text);
  final String text;
}

class ToolCallBlock extends AssistantBlock {
  const ToolCallBlock({required this.callId, required this.name, required this.argsRaw});
  final String callId;
  final String name;
  final String argsRaw;
}

class ImageBlock extends AssistantBlock {
  const ImageBlock(this.attachment);

  /// 持久图片引用：{ attachmentId, mediaType, bytes, width, height, name? }
  final Map<String, dynamic> attachment;
}

class OtherBlock extends AssistantBlock {
  const OtherBlock(this.type);
  final String type;
}

AssistantBlock classifyBlock(Map<String, dynamic> block) {
  switch (block['type']) {
    case 'text':
      return TextBlock(block['text'] as String? ?? '');
    case 'reasoning':
      return ReasoningBlock(block['text'] as String? ?? '');
    case 'tool-call':
      return ToolCallBlock(
        callId: '${block['id'] ?? ''}',
        name: block['name'] as String? ?? '',
        argsRaw: block['arguments'] as String? ?? '',
      );
    case 'image':
      final attachment = block['attachment'];
      if (attachment is Map<String, dynamic>) return ImageBlock(attachment);
      return const OtherBlock('image');
    default:
      return OtherBlock('${block['type']}');
  }
}

AssistantBlock emptyBlock(String blockType) {
  switch (blockType) {
    case 'text':
      return const TextBlock('');
    case 'reasoning':
      return const ReasoningBlock('');
    case 'tool-call':
      return const ToolCallBlock(callId: '', name: '', argsRaw: '');
    default:
      // 未知类型保持 OtherBlock：不会被误判成可见的空工具气泡（健壮性 #3）。
      return OtherBlock(blockType);
  }
}

/// One renderable row in the chat list.
sealed class ChatItem {
  const ChatItem({required this.seq});
  final int seq;
}

class UserItem extends ChatItem {
  const UserItem({required super.seq, required this.text, this.images = const []});
  final String text;

  /// 图片附件引用列表（ImageAttachmentRef 形状）。
  final List<Map<String, dynamic>> images;
}

class AssistantItem extends ChatItem {
  const AssistantItem({required super.seq, required this.blocks, this.streaming = false, this.messageId});
  final List<AssistantBlock> blocks;

  /// True while chunks are still arriving for this message.
  final bool streaming;

  /// 持久消息 id（assistant/message 的 data.message.id），消息反馈的目标。
  final String? messageId;

  AssistantItem copyWith({List<AssistantBlock>? blocks, bool? streaming, String? messageId}) => AssistantItem(
      seq: seq,
      blocks: blocks ?? this.blocks,
      streaming: streaming ?? this.streaming,
      messageId: messageId ?? this.messageId);
}

class ToolItem extends ChatItem {
  const ToolItem({
    required super.seq,
    required this.callId,
    required this.name,
    this.tool = '',
    this.argsRaw = '',
    this.resultPreview,
    this.isError = false,
    this.finished = false,
  });
  final String callId;

  /// 展示名（宿主卡片标题优先，如 "Read lib/api/client.dart (1 - 90)"）。
  final String name;

  /// 原始工具名（read/write/edit/bash…），用于按工具类型分发卡片。
  final String tool;
  final String argsRaw;
  final String? resultPreview;
  final bool isError;
  final bool finished;

  ToolItem copyWith({String? resultPreview, bool? isError, bool? finished}) => ToolItem(
        seq: seq,
        callId: callId,
        name: name,
        tool: tool,
        argsRaw: argsRaw,
        resultPreview: resultPreview ?? this.resultPreview,
        isError: isError ?? this.isError,
        finished: finished ?? this.finished,
      );
}

/// 系统注入的上下文消息（user/message 但 source.kind != 'user'）：
/// 子代理通报、审批回执、任务完成等——不是人类说的话，不按用户气泡渲染。
class SystemItem extends ChatItem {
  const SystemItem({required super.seq, required this.kind, required this.text});

  /// source.kind，如 subagent-report / subagent-settled。
  final String kind;
  final String text;
}

/// 工具审批卡片：approval/asked 落卡、approval/decided 按 id 回填结果。
/// 事件在会话日志里持久存在，卡片跨重进/重连常驻展示。
class ApprovalItem extends ChatItem {
  const ApprovalItem({
    required super.seq,
    required this.approvalId,
    required this.toolName,
    this.callId,
    this.reason,
    this.outcome,
  });

  final String approvalId;
  final String toolName;
  final String? callId;
  final String? reason;

  /// null = 待决；否则为 allowed-once / rejected / cancelled / unavailable。
  final String? outcome;

  ApprovalItem copyWith({String? outcome}) => ApprovalItem(
        seq: seq,
        approvalId: approvalId,
        toolName: toolName,
        callId: callId,
        reason: reason,
        outcome: outcome ?? this.outcome,
      );
}

class NoticeItem extends ChatItem {
  const NoticeItem({required super.seq, required this.text});
  final String text;
}

/// ChatFold 文案默认值（未注入本地化文案时使用；调用方应按当前语言覆盖）。
const kDefaultCompactionNotice = '⤬ 上下文已压缩（较早的对话已折叠为摘要）';
const kDefaultInterruptedSuffix = '\n\n*（回合中断，内容未完整）*';

/// The folded chat surface for one session.
class ChatFold {
  ChatFold({
    String? compactionNotice,
    String? interruptedSuffix,
  })  : compactionNotice = compactionNotice ?? kDefaultCompactionNotice,
        interruptedSuffix = interruptedSuffix ?? kDefaultInterruptedSuffix;

  /// 折叠时烘焙进 NoticeItem / AssistantItem 的本地化文案（由调用方按当前语言注入）。
  final String compactionNotice;
  final String interruptedSuffix;

  List<ChatItem> items = [];
  bool running = false;
  String? title;

  /// Partial streaming assistant blocks while chunks arrive.
  /// 独立于 items 暴露：流式区单独渲染，chunk 更新不再触发整表重建。
  AssistantItem? partial;

  /// 已渲染消息的 id 集合（按 message.id 去重，历史页与 live 帧重叠不重复落表）。
  final Set<String> _seenMessageIds = {};

  /// partial 的 seq 独立递增，避免与 items 追加撞号（健壮性 #2）。
  int _partialSeq = 1000000000;

  /// Index of tool items by callId for result pairing.
  final Map<String, int> _toolIndex = {};

  /// Index of approval items by approvalId for decided pairing.
  final Map<String, int> _approvalIndex = {};

  /// Whether the event is an append-surface event (durable replacement copies
  /// — e.g. compaction checkpoints — carry surfaceOp != 'append' and are not
  /// rendered a second time).
  static bool isAppend(Map<String, dynamic> event) {
    final op = event['surfaceOp'];
    return op == null || op == 'append';
  }

  /// Apply one raw session event (`{type, seq, time, data, ...}`).
  ///
  /// - [live]: true for mux-stream frames. History pages skip `assistant/chunk`
  ///   entirely (a 30-message page can carry 24k+ chunk events; the final
  ///   `assistant/message` already holds the full content).
  /// - [view]: the host-computed ToolEventView (`{for, view: {card, ...}}`)
  ///   attached to history entries / mux frames.
  void applyEvent(Map<String, dynamic> event, {bool live = false, Map<String, dynamic>? view}) {
    final type = event['type'] as String? ?? '';
    final seq = (event['seq'] as num?)?.toInt() ?? 0;
    final data = event['data'];
    final map = data is Map<String, dynamic> ? data : const <String, dynamic>{};

    switch (type) {
      case 'user/message':
        if (!isAppend(event)) return;
        // 真实结构：data 本身就是 message（{role, content, source, id}）。
        final content =
            map['content'] ?? (map['message'] is Map<String, dynamic> ? (map['message'] as Map)['content'] : null);
        if (content is! List) return;
        final texts = <String>[];
        final images = <Map<String, dynamic>>[];
        for (final block in content) {
          if (block is Map<String, dynamic>) {
            if (block['type'] == 'text') texts.add(block['text'] as String? ?? '');
            if (block['type'] == 'image') {
              final attachment = block['attachment'];
              if (attachment is Map<String, dynamic>) images.add(attachment);
            }
          }
        }
        final text = texts.join('\n').trim();
        if (text.isEmpty && images.isEmpty) return;
        // 按 message.id 去重：历史页与 live 帧重叠时不重复落表（健壮性 #4）。
        final msgId = map['id'] as String?;
        if (msgId != null && !_seenMessageIds.add(msgId)) return;
        // source.kind 区分真用户与系统注入（subagent-report/-settled 等）。
        final source = map['source'];
        final kind = source is Map<String, dynamic> ? source['kind'] as String? : null;
        if (kind != null && kind != 'user') {
          items.add(SystemItem(seq: seq, kind: kind, text: text));
          return;
        }
        items.add(UserItem(seq: seq, text: text, images: images));
      case 'assistant/chunk':
        if (!live) return; // 历史折叠跳过流式中间态（性能关键路径）
        _applyChunk(map['chunk']);
      case 'assistant/message':
        if (!isAppend(event)) return;
        final message = map['message'];
        if (message is! Map<String, dynamic>) return;
        final content = message['content'];
        if (content is! List) return;
        final blocks = content
            .whereType<Map<String, dynamic>>()
            .map(classifyBlock)
            // 工具调用块由独立的 tool/call → ToolItem 卡片呈现，消息内不再重复渲染。
            .where((b) => b is! OtherBlock && b is! ToolCallBlock)
            .toList();
        _finalizePartial();
        final msgId = message['id'] as String?;
        if (msgId != null && !_seenMessageIds.add(msgId)) return;
        if (blocks.isNotEmpty) {
          items.add(AssistantItem(seq: seq, blocks: blocks, messageId: msgId));
        }
      case 'tool/call':
        final callId = '${map['callId'] ?? map['id'] ?? ''}';
        final name = '${map['name'] ?? map['tool'] ?? 'tool'}';
        final args = map['arguments'];
        // 宿主算好的卡片视图提供人类可读标题（如终端命令本身）。
        final viewBody = view?['view'];
        final title = viewBody is Map<String, dynamic> ? viewBody['title'] as String? : null;
        _finalizePartial();
        final argsText = args is String ? args : (args == null ? '' : '$args');
        final existing = _toolIndex[callId];
        if (existing != null && existing >= 0 && existing < items.length) {
          // 重放/乱序：原地更新而不是追加第二张卡（健壮性 #4）。
          final old = items[existing];
          if (old is ToolItem && !old.finished) {
            items[existing] =
                ToolItem(seq: old.seq, callId: callId, name: title ?? name, tool: name, argsRaw: argsText);
          }
          return;
        }
        _toolIndex[callId] = items.length;
        items.add(ToolItem(
          seq: seq,
          callId: callId,
          name: title ?? name,
          tool: name,
          argsRaw: argsText,
        ));
      case 'tool/result':
        // 真实结构（dsh ≥0.1.7）：data.message = {role:'tool', toolCallId,
        // source:{kind:'tool', callId}, content:[{type:'text', text}], isError}；
        // 更旧的 host 把 toolCallId 放在 content 的 tool-result 块里。
        String callId = '${map['callId'] ?? map['id'] ?? ''}';
        String? preview;
        var isError = map['isError'] == true || map['error'] != null;
        final message = map['message'];
        if (message is Map<String, dynamic>) {
          isError = isError || message['isError'] == true;
          if (callId.isEmpty) {
            final source = message['source'];
            callId = '${message['toolCallId'] ?? (source is Map<String, dynamic> ? source['callId'] : null) ?? ''}';
          }
        }
        final resultContent = message is Map<String, dynamic> ? message['content'] : map['content'];
        if (resultContent is List) {
          for (final block in resultContent.whereType<Map<String, dynamic>>()) {
            if (block['type'] == 'tool-result') {
              callId = '${block['toolCallId'] ?? callId}';
              isError = isError || block['isError'] == true;
              preview ??= _blocksText(block['content']);
            } else if (block['type'] == 'text') {
              preview ??= block['text'] as String?;
            }
          }
        }
        // 宿主卡片视图（terminal 卡带 output）是更好的预览来源。
        final viewBody = view?['view'];
        if (viewBody is Map<String, dynamic> && viewBody['output'] is String) {
          preview = viewBody['output'] as String;
        }
        // 富文本卡片（read 全文 / bash 输出 / diff）需要更大余量；超出部分截断。
        if (preview != null && preview.length > 4000) preview = '${preview.substring(0, 4000)}…';
        final idx = _toolIndex[callId];
        if (idx != null && idx >= 0 && idx < items.length) {
          final item = items[idx];
          if (item is ToolItem) {
            items[idx] = item.copyWith(resultPreview: preview, isError: isError, finished: true);
          }
        } else {
          items.add(ToolItem(
            seq: seq,
            callId: callId,
            name: 'result',
            resultPreview: preview,
            isError: isError,
            finished: true,
          ));
        }
      case 'approval/asked':
        // { id, toolName, callId?, reason? } —— 落一张待决审批卡。
        _finalizePartial();
        final id = '${map['id'] ?? ''}';
        if (id.isEmpty || _approvalIndex.containsKey(id)) return;
        _approvalIndex[id] = items.length;
        items.add(ApprovalItem(
          seq: seq,
          approvalId: id,
          toolName: map['toolName'] as String? ?? 'tool',
          callId: map['callId'] as String?,
          reason: map['reason'] as String?,
        ));
      case 'approval/decided':
        // { id, outcome } —— 回填结果；asked 缺失（跨页/乱序）时补一张已决卡。
        final id = '${map['id'] ?? ''}';
        final outcome = map['outcome'] as String? ?? 'unavailable';
        final idx = _approvalIndex[id];
        if (idx != null && idx >= 0 && idx < items.length) {
          final item = items[idx];
          if (item is ApprovalItem) {
            items[idx] = item.copyWith(outcome: outcome);
          }
        } else if (id.isNotEmpty) {
          _approvalIndex[id] = items.length;
          items.add(ApprovalItem(
              seq: seq, approvalId: id, toolName: 'tool', outcome: outcome));
        }
      case 'turn/start':
        running = true;
      case 'turn/end':
        running = false;
        _dropPartialAsInterrupted(seq);
      case 'session/title':
        final t = map['title'];
        if (t is String && t.isNotEmpty) title = t;
      case 'compaction/summary':
        items.add(NoticeItem(seq: seq, text: compactionNotice));
      case 'command/run':
        // 真实结构：{ commandId, name, args?, source }
        final name = map['name'];
        if (name is String) {
          final args = map['args'];
          items.add(NoticeItem(
              seq: seq, text: '/$name${args is String && args.isNotEmpty ? ' $args' : ''}'));
        }
      case 'command/done':
        // { commandId, kind: 'success'|'error', text? }
        final text = map['text'];
        if (text is String && text.isNotEmpty) {
          final kind = map['kind'];
          items.add(NoticeItem(
              seq: seq, text: kind == 'error' ? '⚠ $text' : text));
        }
      default:
        // Unknown / merge-extended event types are ignored by design.
        break;
    }
  }

  void _applyChunk(dynamic rawChunk) {
    if (rawChunk is! Map<String, dynamic>) return;
    final type = rawChunk['type'] as String? ?? '';
    final index = (rawChunk['index'] as num?)?.toInt() ?? 0;
    // 网络来源的 index 无信任基础：无上限填充会把内存打爆（健壮性 #1）。
    if (index < 0 || index > 256) return;
    final blocks = List<AssistantBlock>.from(partial?.blocks ?? const <AssistantBlock>[]);

    switch (type) {
      case 'block-start':
        _ensureLength(blocks, index);
        blocks[index] = emptyBlock(rawChunk['blockType'] as String? ?? 'text');
      case 'text-delta':
        _ensureLength(blocks, index);
        final prev = blocks[index];
        blocks[index] = TextBlock((prev is TextBlock ? prev.text : '') + (rawChunk['text'] as String? ?? ''));
      case 'reasoning-delta':
        _ensureLength(blocks, index);
        final prev = blocks[index];
        blocks[index] =
            ReasoningBlock((prev is ReasoningBlock ? prev.text : '') + (rawChunk['text'] as String? ?? ''));
      case 'tool-call-delta':
        _ensureLength(blocks, index);
        final prev = blocks[index];
        final base = prev is ToolCallBlock ? prev : const ToolCallBlock(callId: '', name: '', argsRaw: '');
        blocks[index] = ToolCallBlock(
          callId: base.callId.isNotEmpty ? base.callId : '${rawChunk['id'] ?? ''}',
          name: (rawChunk['name'] as String?) ?? base.name,
          argsRaw: base.argsRaw + (rawChunk['argumentsDelta'] as String? ?? ''),
        );
      case 'block-end':
        final block = rawChunk['block'];
        if (block is Map<String, dynamic>) {
          _ensureLength(blocks, index);
          blocks[index] = classifyBlock(block);
        }
      default:
        return; // usage etc. — not rendered
    }
    _upsertPartial(blocks);
  }

  void _ensureLength(List<AssistantBlock> blocks, int index) {
    while (blocks.length <= index) {
      blocks.add(const TextBlock(''));
    }
  }

  void _upsertPartial(List<AssistantBlock> blocks) {
    final visible = blocks.any((b) =>
        (b is TextBlock && b.text.trim().isNotEmpty) ||
        (b is ReasoningBlock && b.text.trim().isNotEmpty) ||
        // 空壳 tool-call（id/name/args 全空）不算可见内容。
        (b is ToolCallBlock && (b.name.isNotEmpty || b.argsRaw.isNotEmpty)) ||
        b is ImageBlock);
    if (!visible) return;
    partial = AssistantItem(seq: partial?.seq ?? _partialSeq++, blocks: blocks, streaming: true);
  }

  void _finalizePartial() {
    partial = null;
  }

  /// 流中断（turn/end 无 assistant/message 收尾）：partial 落表保留已生成内容，
  /// 末尾附中断标记，而不是静默丢弃（健壮性 #2）。
  void _dropPartialAsInterrupted(int seq) {
    final p = partial;
    if (p == null) return;
    partial = null;
    items.add(AssistantItem(
      seq: p.seq,
      blocks: [...p.blocks, TextBlock(interruptedSuffix)],
      messageId: p.messageId,
    ));
  }
}

String? _blocksText(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String? ?? '')
        .join('\n');
    return text.isEmpty ? null : text;
  }
  return content == null ? null : '$content';
}

/// 历史页解析+折叠的隔离任务输入/输出（后台 isolate 执行，避免 UI 线程
/// 同步解码数 MB JSON 造成卡顿）。
class HistoryFoldTask {
  const HistoryFoldTask({
    required this.body,
    required this.isTail,
    this.compactionNotice,
    this.interruptedSuffix,
  });

  /// session/page 的 value JSON 字符串（或 session/follow snapshot 帧）。
  final String body;
  final bool isTail;

  /// 本地化文案（不传则用 ChatFold 默认）。
  final String? compactionNotice;
  final String? interruptedSuffix;
}

class HistoryFoldResult {
  const HistoryFoldResult({
    required this.fold,
    required this.hasMore,
    this.goalValue,
    this.projections = const {},
  });

  final ChatFold fold;
  final bool hasMore;

  /// `goal` 投影的原始 JSON 值（仅尾部页）。
  final dynamic goalValue;

  /// 尾部页投影基线的全部原始值（todos/plan/permissions/imageLimits 等）。
  final Map<String, dynamic> projections;
}

/// 在后台 isolate 中运行：jsonDecode + 全量 fold。
///
/// 新版历史形状（session/page value / follow snapshot）：
/// `{records: [{type:'event', event} | {type:'chunks', event: ChunkRowEvent}], hasMore}`。
/// chunkrow 压缩行跳过（流式中间态；最终内容由 assistant/message 携带），
/// 与旧版 slim history 丢 assistant/chunk 同理。
HistoryFoldResult parseAndFoldHistory(HistoryFoldTask task) {
  final decoded = jsonDecode(task.body);
  final map = decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
  final fold = ChatFold(
    compactionNotice: task.compactionNotice,
    interruptedSuffix: task.interruptedSuffix,
  );
  final records = (map['records'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
  for (final entry in records) {
    if (entry['type'] != 'event') continue; // 跳过 chunkrow 压缩行
    final event = entry['event'];
    if (event is Map<String, dynamic>) {
      fold.applyEvent(event);
    }
  }
  dynamic goalValue;
  var projections = const <String, dynamic>{};
  if (task.isTail) {
    final block = map['projections'];
    if (block is Map<String, dynamic>) {
      final values = block['values'];
      if (values is Map<String, dynamic>) {
        projections = values;
        final t = values['title'];
        if (t is String && t.isNotEmpty) fold.title = t;
        goalValue = values['goal'];
      }
    }
  }
  return HistoryFoldResult(
      fold: fold, hasMore: map['hasMore'] == true, goalValue: goalValue, projections: projections);
}
