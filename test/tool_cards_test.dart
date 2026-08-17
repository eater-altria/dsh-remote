import 'package:dsh_remote/api/fold.dart';
import 'package:dsh_remote/ui/theme.dart';
import 'package:dsh_remote/ui/tool_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = CodeColors(
  keyword: Color(0xFF000001),
  string: Color(0xFF000002),
  comment: Color(0xFF000003),
  number: Color(0xFF000004),
  plain: Color(0xFF000005),
);
const _base = TextStyle(color: Color(0xFF000005), fontSize: 12);

void main() {
  group('highlightCodeBlock（highlight.js 11.8 引擎）', () {
    TextSpan? findSpan(List<List<TextSpan>> lines, String text) {
      for (final line in lines) {
        for (final span in line) {
          if (span.text == text) return span;
        }
      }
      return null;
    }

    test('dart：关键字 / 字符串 / 注释 / 数字各归其色', () {
      final lines = highlightCodeBlock(
        'final x = "hi"; // 注释\nfinal y = 42;',
        ext: 'dart',
        colors: _colors,
        base: _base,
      );
      expect(lines, hasLength(2));
      expect(findSpan(lines, 'final')!.style!.color, _colors.keyword);
      expect(findSpan(lines, '"hi"')!.style!.color, _colors.string);
      expect(findSpan(lines, '// 注释')!.style!.color, _colors.comment);
      expect(findSpan(lines, '42')!.style!.color, _colors.number);
    });

    test('注释风格按语言区分：py 的 # 是注释，dart 的 # 不是', () {
      final py = highlightCodeBlock('x = 1 # 注释', ext: 'py', colors: _colors, base: _base);
      expect(findSpan(py, '# 注释')!.style!.color, _colors.comment);
      // dart 里没有 # 注释语法，不应出现注释色。
      final dart = highlightCodeBlock('final x = 1;', ext: 'dart', colors: _colors, base: _base);
      final hasCommentColor = dart
          .expand((l) => l)
          .any((s) => s.style?.color == _colors.comment);
      expect(hasCommentColor, isFalse);
    });

    test('多行字符串跨行不断裂；未知扩展名退回纯文本', () {
      final lines = highlightCodeBlock(
        "final s = '''\n跨行字符串\n''';",
        ext: 'dart',
        colors: _colors,
        base: _base,
      );
      expect(lines, hasLength(3));
      expect(findSpan(lines, '跨行字符串')!.style!.color, _colors.string);

      final plain = highlightCodeBlock('whatever # else', ext: 'xyz', colors: _colors, base: _base);
      expect(plain.single.single.style!.color, _colors.plain);
    });
  });

  group('computeLineDiff', () {
    test('old 为空 → 全部新增（write 新建）', () {
      final diff = computeLineDiff('', 'a\nb');
      expect(diff.every((l) => l.kind == DiffKind.add), isTrue);
      expect(diff.map((l) => l.text), ['a', 'b']);
    });

    test('替换中间行：保留行 + 删旧增新', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nB\nc');
      expect(diff.map((l) => (l.kind, l.text)), [
        (DiffKind.keep, 'a'),
        (DiffKind.del, 'b'),
        (DiffKind.add, 'B'),
        (DiffKind.keep, 'c'),
      ]);
    });

    test('完全相同 → 全 keep；全新内容 → 全 add', () {
      expect(computeLineDiff('x', 'x').single.kind, DiffKind.keep);
      expect(computeLineDiff('x', '').single.kind, DiffKind.del);
    });
  });

  group('parseToolArgs / stripReadEnvelope', () {
    test('非法 JSON 安全返回空表', () {
      expect(parseToolArgs('not json'), isEmpty);
      expect(parseToolArgs('{"a": 1}')['a'], 1);
    });

    test('read 信封剥离出正文', () {
      const preview = '<path>/x/y.dart</path>\n<type>file</type>\n<content>\n1: a\n2: b\n</content>';
      expect(stripReadEnvelope(preview), '1: a\n2: b');
    });
  });

  testWidgets('bash 运行中卡片显示等待文案与运行中徽标', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NekoTheme.light(),
        home: Scaffold(
          body: BashToolCard(
            item: ToolItem(
              seq: 1,
              callId: 'c1',
              name: 'bash',
              tool: 'bash',
              argsRaw: '{"command": "flutter test"}',
            ),
          ),
        ),
      ),
    );
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    // 等待文案在展开后可见（运行中有无限动画的指示器，用 pump 而非 pumpAndSettle）。
    await tester.tap(find.text('flutter test'));
    await tester.pump();
    expect(find.textContaining('命令还在终端里奔跑'), findsOneWidget);
  });

  testWidgets('write 卡片渲染 git 风新增/删除徽标与 diff 行', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NekoTheme.light(),
        home: Scaffold(
          body: WriteToolCard(
            item: ToolItem(
              seq: 1,
              callId: 'c2',
              name: 'edit',
              tool: 'edit',
              argsRaw: '{"file_path": "lib/a.dart", "old_string": "old line", "new_string": "new line"}',
              finished: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('写入 a.dart'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
    await tester.tap(find.text('写入 a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('old line'), findsOneWidget);
    expect(find.text('new line'), findsOneWidget);
  });
}
