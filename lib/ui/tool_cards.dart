/// 富文本工具卡片（design.md §4 卡片模式扩展）：
/// - bash：终端风面板（命令 + 输出），运行中给明确等待文案
/// - read：路径头部 + highlight.js 11.8（highlighting 包）真语法高亮
/// - write/edit：git 风行级 diff 面板（红删绿增 + +N/−M 徽标）
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_settings.dart';
import 'package:highlighting/highlighting.dart';

import '../api/fold.dart';
import 'theme.dart';

// ---------------------------------------------------------------------------
// 纯函数工具（可单测）
// ---------------------------------------------------------------------------

/// 语法高亮配色（全部取 NekoTheme 语义色，深浅色自动适配）。
class CodeColors {
  const CodeColors({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.plain,
  });

  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
  final Color plain;
}

/// 文件扩展名 → hljs 语言 id。
const _extToLanguage = {
  'dart': 'dart',
  'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript', 'jsx': 'javascript',
  'ts': 'typescript', 'tsx': 'typescript',
  'py': 'python', 'sh': 'bash', 'bash': 'bash', 'zsh': 'bash',
  'yaml': 'yaml', 'yml': 'yaml', 'json': 'json', 'md': 'markdown',
  'html': 'xml', 'xml': 'xml', 'vue': 'xml', 'css': 'css', 'scss': 'scss',
  'java': 'java', 'kt': 'kotlin', 'kts': 'kotlin', 'rs': 'rust', 'go': 'go',
  'c': 'c', 'h': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'hpp': 'cpp', 'cs': 'csharp',
  'rb': 'ruby', 'php': 'php', 'sql': 'sql', 'swift': 'swift',
  'toml': 'ini', 'ini': 'ini', 'diff': 'diff',
};

/// hljs 语义类 → 配色槽位。类名可能是点分嵌套（title.function_），按首段归类。
Color _colorFor(String? className, CodeColors colors) {
  if (className == null) return colors.plain;
  final head = className.split('.').first;
  return switch (head) {
    'keyword' || 'title' || 'built_in' || 'type' || 'selector-tag' || 'tag' => colors.keyword,
    'string' || 'regexp' || 'char' => colors.string,
    'comment' || 'meta' || 'quote' => colors.comment,
    'number' || 'literal' || 'attr' || 'attribute' || 'symbol' || 'name' => colors.number,
    _ => colors.plain,
  };
}

/// 整段代码高亮：hljs 全量解析后按行拆回（多行字符串/注释不断裂）。
/// 返回逐行的 TextSpan 列表；未知语言或解析失败退回纯文本。
List<List<TextSpan>> highlightCodeBlock(
  String code, {
  required String ext,
  required CodeColors colors,
  required TextStyle base,
}) {
  List<List<TextSpan>> plainLines() =>
      [for (final line in code.split('\n')) [TextSpan(text: line, style: base)]];

  final languageId = _extToLanguage[ext.toLowerCase()];
  if (languageId == null) return plainLines();

  // 拍平语法树为 (文本, 颜色) 段。
  final segments = <(String, Color)>[];
  void walk(Node node, Color inherited) {
    final color = node.className != null ? _colorFor(node.className, colors) : inherited;
    final value = node.value;
    if (value != null && value.isNotEmpty) segments.add((value, color));
    for (final child in node.children) {
      walk(child, color);
    }
  }

  try {
    final result = highlight.parse(code, languageId: languageId);
    final nodes = result.nodes;
    if (nodes == null) return plainLines();
    for (final node in nodes) {
      walk(node, colors.plain);
    }
  } catch (_) {
    return plainLines();
  }

  // 段按换行拆回逐行 spans。
  final lines = <List<TextSpan>>[[]];
  for (final (text, color) in segments) {
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add([]);
      if (parts[i].isEmpty) continue;
      lines.last.add(TextSpan(
        text: parts[i],
        style: color == colors.plain ? base : base.copyWith(color: color),
      ));
    }
  }
  return lines;
}

/// git 风 diff 行类别。
enum DiffKind { keep, add, del }

class DiffLine {
  const DiffLine(this.kind, this.text);
  final DiffKind kind;
  final String text;
}

/// 行级 LCS diff：old → new。old 为空时全部为新增（write 新建/全量写入）。
List<DiffLine> computeLineDiff(String oldText, String newText) {
  final oldLines = oldText.isEmpty ? const <String>[] : oldText.split('\n');
  final newLines = newText.isEmpty ? const <String>[] : newText.split('\n');
  final n = oldLines.length;
  final m = newLines.length;
  if (n == 0) return [for (final l in newLines) DiffLine(DiffKind.add, l)];
  if (m == 0) return [for (final l in oldLines) DiffLine(DiffKind.del, l)];

  // LCS 长度表（倒序 DP）。
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] == newLines[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      out.add(DiffLine(DiffKind.keep, newLines[j]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine(DiffKind.del, oldLines[i]));
      i++;
    } else {
      out.add(DiffLine(DiffKind.add, newLines[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(DiffKind.del, oldLines[i++]));
  }
  while (j < m) {
    out.add(DiffLine(DiffKind.add, newLines[j++]));
  }
  return out;
}

/// 工具参数 JSON 解析（失败安全返回空表）。
Map<String, dynamic> parseToolArgs(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return const {};
}

/// read 结果信封剥离：`<path>…</path>` `<type>…</type>` `<content>…</content>`。
String stripReadEnvelope(String preview) {
  var text = preview;
  final start = text.indexOf('<content>');
  if (start >= 0) text = text.substring(start + '<content>'.length);
  final end = text.lastIndexOf('</content>');
  if (end >= 0 && end <= text.length) text = text.substring(0, end);
  return text.replaceAll(RegExp(r'^\n+|\n+$'), '');
}

// ---------------------------------------------------------------------------
// 卡片骨架：头部（图标 + 标题 + 徽标 + 展开箭头）+ 可展开正文
// ---------------------------------------------------------------------------

class ToolCardFrame extends StatefulWidget {
  const ToolCardFrame({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.chips = const [],
    required this.child,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final List<Widget> chips;
  final Widget child;

  @override
  State<ToolCardFrame> createState() => _ToolCardFrameState();
}

class _ToolCardFrameState extends State<ToolCardFrame> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: widget.iconColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...widget.chips,
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// 状态色：完成=薄荷、失败=西瓜红、运行中=樱粉（design.md §4 状态语义）。
(Color, IconData) _statusOf(ToolItem item, ThemeData theme) {
  if (!item.finished) return (theme.colorScheme.secondary, Icons.hourglass_top);
  if (item.isError) return (theme.colorScheme.error, Icons.error_outline);
  return (theme.colorScheme.tertiary, Icons.check_circle_outline);
}

// ---------------------------------------------------------------------------
// bash：终端风面板
// ---------------------------------------------------------------------------

class BashToolCard extends ConsumerWidget {
  const BashToolCard({super.key, required this.item});

  final ToolItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final args = parseToolArgs(item.argsRaw);
    final command = (args['command'] as String? ?? '').trim();
    final title = command.isEmpty ? item.name : command.split('\n').first;
    final (color, icon) = _statusOf(item, theme);
    final output = item.resultPreview;

    return ToolCardFrame(
      icon: icon,
      iconColor: color,
      title: title,
      chips: [
        _Chip(
          label: !item.finished ? s.statusRunning : (item.isError ? s.statusFailedBadge : s.statusDone),
          color: color,
        ),
      ],
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: NekoColors.nightBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (command.isNotEmpty)
              Text(
                '\$ $command',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: NekoColors.nightBlue,
                ),
              ),
            if (output != null && output.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                output,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: NekoColors.nightInk.withValues(alpha: 0.85),
                  height: 1.4,
                ),
              ),
            ] else if (!item.finished) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.bashWaiting,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: NekoColors.nightInk.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// read：路径 + 语法高亮内容
// ---------------------------------------------------------------------------

class ReadToolCard extends ConsumerWidget {
  const ReadToolCard({super.key, required this.item});

  final ToolItem item;

  static final _lineNumber = RegExp(r'^(\d+):\s?(.*)$');
  static const _maxLines = 60;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final args = parseToolArgs(item.argsRaw);
    final path = args['file_path'] as String? ?? '';
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final (color, icon) = _statusOf(item, theme);

    final colors = CodeColors(
      keyword: scheme.primary,
      string: scheme.tertiary,
      comment: scheme.onSurfaceVariant,
      number: scheme.secondary,
      plain: scheme.onSurface,
    );
    final base = theme.textTheme.bodySmall!.copyWith(fontFamily: 'monospace', height: 1.45);

    final rows = <Widget>[];
    final preview = item.resultPreview;
    if (preview != null) {
      final lines = stripReadEnvelope(preview).split('\n');
      final shown = lines.length > _maxLines ? lines.sublist(0, _maxLines) : lines;
      // 先剥行号前缀，对纯代码块整段解析（行号会污染语法树）。
      final numbers = <String?>[];
      final codeLines = <String>[];
      for (final raw in shown) {
        final match = _lineNumber.firstMatch(raw);
        numbers.add(match?.group(1));
        codeLines.add(match?.group(2) ?? raw);
      }
      final highlighted = highlightCodeBlock(codeLines.join('\n'), ext: ext, colors: colors, base: base);
      for (var i = 0; i < shown.length; i++) {
        final number = numbers[i];
        rows.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (number != null)
              SizedBox(
                width: 34,
                child: Text(
                  number,
                  textAlign: TextAlign.right,
                  style: base.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
                ),
              ),
            if (number != null) const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: highlighted[i]),
                softWrap: true,
              ),
            ),
          ],
        ));
      }
      if (lines.length > _maxLines) {
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(s.remainingLines(lines.length - _maxLines),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ));
      }
    }

    return ToolCardFrame(
      icon: icon,
      iconColor: color,
      title: item.name,
      child: rows.isEmpty
          ? Text(s.readingFile,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: rows),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// write / edit：git 风 diff 面板
// ---------------------------------------------------------------------------

class WriteToolCard extends ConsumerWidget {
  const WriteToolCard({super.key, required this.item});

  final ToolItem item;

  static const _maxRows = 120;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final args = parseToolArgs(item.argsRaw);
    final path = args['file_path'] as String? ?? '';
    final name = path.split('/').last;
    final (color, icon) = _statusOf(item, theme);

    final oldText = args['old_string'] as String? ?? '';
    final newText = (args['new_string'] ?? args['content']) as String? ?? '';
    var diff = computeLineDiff(oldText, newText);
    // edit 全替换之外，纯新增时 old 为空 → 全是 add；去掉全 keep 的噪音行不需要。
    final added = diff.where((l) => l.kind == DiffKind.add).length;
    final removed = diff.where((l) => l.kind == DiffKind.del).length;

    var truncated = 0;
    if (diff.length > _maxRows) {
      truncated = diff.length - _maxRows;
      diff = [...diff.take(80), ...diff.skip(diff.length - 40)];
    }

    final mono = theme.textTheme.bodySmall!.copyWith(fontFamily: 'monospace', height: 1.4);
    Widget row(DiffLine line) {
      final (bg, fg, prefix) = switch (line.kind) {
        DiffKind.add => (
            scheme.tertiary.withValues(alpha: 0.14),
            scheme.onSurface,
            '+'
          ),
        DiffKind.del => (
            scheme.error.withValues(alpha: 0.12),
            scheme.onSurface,
            '−'
          ),
        DiffKind.keep => (
            Colors.transparent,
            scheme.onSurfaceVariant,
            ' '
          ),
      };
      return Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 12, child: Text(prefix, style: mono.copyWith(color: fg))),
            Expanded(child: Text(line.text, style: mono.copyWith(color: fg), softWrap: true)),
          ],
        ),
      );
    }

    return ToolCardFrame(
      icon: icon,
      iconColor: color,
      title: name.isEmpty ? item.name : s.writeTitle(name),
      chips: [
        if (added > 0) _Chip(label: '+$added', color: scheme.tertiary),
        if (removed > 0) _Chip(label: '−$removed', color: scheme.error),
      ],
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in diff) row(line),
            if (truncated > 0)
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(s.middleLinesOmitted(truncated),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }
}
