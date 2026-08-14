/// Session-event fold: turns the durable event log (`session.history`) and
/// live mux frames (`session/event`) into a renderable chat item list.
///
/// Mirrors the web client's core fold, simplified:
/// - `user/message` (append surface) -> user bubble
/// - `assistant/chunk` -> streaming partial assistant blocks (indexed)
/// - `assistant/message` (append surface) -> finalized assistant message
/// - `tool/call` / `tool/result` -> tool cards (paired by callId)
/// - `turn/start` / `turn/end` -> running flag
/// - `session/title` -> title
/// - `compaction/summary`, `command/run` -> system notices
library;

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
    default:
      return const ToolCallBlock(callId: '', name: '', argsRaw: '');
  }
}

/// One renderable row in the chat list.
sealed class ChatItem {
  const ChatItem({required this.seq});
  final int seq;
}

class UserItem extends ChatItem {
  const UserItem({required super.seq, required this.text, this.imageCount = 0});
  final String text;
  final int imageCount;
}

class AssistantItem extends ChatItem {
  const AssistantItem({required super.seq, required this.blocks, this.streaming = false});
  final List<AssistantBlock> blocks;

  /// True while chunks are still arriving for this message.
  final bool streaming;

  AssistantItem copyWith({List<AssistantBlock>? blocks, bool? streaming}) =>
      AssistantItem(seq: seq, blocks: blocks ?? this.blocks, streaming: streaming ?? this.streaming);
}

class ToolItem extends ChatItem {
  const ToolItem({
    required super.seq,
    required this.callId,
    required this.name,
    this.argsRaw = '',
    this.resultPreview,
    this.isError = false,
    this.finished = false,
  });
  final String callId;
  final String name;
  final String argsRaw;
  final String? resultPreview;
  final bool isError;
  final bool finished;

  ToolItem copyWith({String? resultPreview, bool? isError, bool? finished}) => ToolItem(
        seq: seq,
        callId: callId,
        name: name,
        argsRaw: argsRaw,
        resultPreview: resultPreview ?? this.resultPreview,
        isError: isError ?? this.isError,
        finished: finished ?? this.finished,
      );
}

class NoticeItem extends ChatItem {
  const NoticeItem({required super.seq, required this.text});
  final String text;
}

/// The folded chat surface for one session.
class ChatFold {
  List<ChatItem> items = [];
  bool running = false;
  String? title;

  /// Partial streaming assistant blocks while chunks arrive.
  AssistantItem? _partial;

  /// Index of tool items by callId for result pairing.
  final Map<String, int> _toolIndex = {};

  /// Whether the event is an append-surface event (durable replacement copies
  /// — e.g. compaction checkpoints — carry surfaceOp != 'append' and are not
  /// rendered a second time).
  static bool isAppend(Map<String, dynamic> event) {
    final op = event['surfaceOp'];
    return op == null || op == 'append';
  }

  /// Apply one raw session event (`{type, seq, time, data, ...}`).
  void applyEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    final seq = (event['seq'] as num?)?.toInt() ?? 0;
    final data = event['data'];
    final map = data is Map<String, dynamic> ? data : const <String, dynamic>{};

    switch (type) {
      case 'user/message':
        if (!isAppend(event)) return;
        final message = map['message'];
        if (message is! Map<String, dynamic>) return;
        final content = message['content'];
        if (content is! List) return;
        final texts = <String>[];
        var images = 0;
        for (final block in content) {
          if (block is Map<String, dynamic>) {
            if (block['type'] == 'text') texts.add(block['text'] as String? ?? '');
            if (block['type'] == 'image') images++;
          }
        }
        final text = texts.join('\n').trim();
        if (text.isEmpty && images == 0) return;
        items.add(UserItem(seq: seq, text: text, imageCount: images));
      case 'assistant/chunk':
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
            .where((b) => b is! OtherBlock)
            .toList();
        _finalizePartial();
        items.add(AssistantItem(seq: seq, blocks: blocks));
        for (var i = 0; i < blocks.length; i++) {
          final b = blocks[i];
          if (b is ToolCallBlock && b.callId.isNotEmpty) {
            // Tool blocks embedded in the final message pair with tool items.
            _toolIndex.putIfAbsent(b.callId, () => -1);
          }
        }
      case 'tool/call':
        final callId = '${map['callId'] ?? map['id'] ?? ''}';
        final name = '${map['name'] ?? map['tool'] ?? 'tool'}';
        final args = map['arguments'];
        _finalizePartial();
        _toolIndex[callId] = items.length;
        items.add(ToolItem(
          seq: seq,
          callId: callId,
          name: name,
          argsRaw: args is String ? args : (args == null ? '' : '$args'),
        ));
      case 'tool/result':
        final callId = '${map['callId'] ?? map['id'] ?? ''}';
        final preview = _resultPreview(map);
        final isError = map['isError'] == true || map['error'] != null;
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
      case 'turn/start':
        running = true;
      case 'turn/end':
        running = false;
        _finalizePartial();
      case 'session/title':
        final t = map['title'];
        if (t is String && t.isNotEmpty) title = t;
      case 'compaction/summary':
        items.add(NoticeItem(seq: seq, text: '⤬ 上下文已压缩（较早的对话已折叠为摘要）'));
      case 'command/run':
        final line = map['line'] ?? map['command'];
        if (line is String) items.add(NoticeItem(seq: seq, text: line));
      default:
        // Unknown / merge-extended event types are ignored by design.
        break;
    }
  }

  void _applyChunk(dynamic rawChunk) {
    if (rawChunk is! Map<String, dynamic>) return;
    final type = rawChunk['type'] as String? ?? '';
    final index = (rawChunk['index'] as num?)?.toInt() ?? 0;
    final blocks = List<AssistantBlock>.from(_partial?.blocks ?? const <AssistantBlock>[]);

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
        b is ToolCallBlock);
    if (!visible) return;
    final seq = (items.isNotEmpty ? items.last.seq : 0) + 1;
    if (_partial == null) {
      _partial = AssistantItem(seq: seq, blocks: blocks, streaming: true);
      items.add(_partial!);
    } else {
      final idx = items.indexOf(_partial!);
      _partial = AssistantItem(seq: _partial!.seq, blocks: blocks, streaming: true);
      if (idx >= 0) items[idx] = _partial!;
    }
  }

  void _finalizePartial() {
    final partial = _partial;
    if (partial == null) return;
    _partial = null;
    final idx = items.indexOf(partial);
    if (idx >= 0) items.removeAt(idx);
  }
}

String? _resultPreview(Map<String, dynamic> map) {
  final content = map['content'] ?? map['result'] ?? map['output'];
  String text;
  if (content is String) {
    text = content;
  } else if (content is List) {
    text = content
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String? ?? '')
        .join('\n');
  } else if (content != null) {
    text = '$content';
  } else {
    return null;
  }
  const max = 500;
  if (text.length > max) return '${text.substring(0, max)}…';
  return text;
}
