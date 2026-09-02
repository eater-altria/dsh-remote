import 'package:dsh_remote/ui/bottom_stick.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// BottomStickController 回归：进会话不滚到底的根因是「入口跳底发生在布局
/// 稳定前，之后的布局增长（图片加载/流式追加）无人纠正」。修复后：布局增长
/// 经 ScrollMetricsNotification 贴底重跳；用户上翻停止跟随；回底恢复。
void main() {
  testWidgets('布局增长保持贴底；用户上翻停止跟随；回到底部恢复跟随', (tester) async {
    final stick = BottomStickController()..attach();
    addTearDown(stick.dispose);
    var itemCount = 30;

    Widget buildApp() => MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                stick.onMetricsChanged();
                return false;
              },
              child: ListView.builder(
                controller: stick.scroll,
                itemCount: itemCount,
                itemBuilder: (_, i) => SizedBox(height: 100, child: Text('item-$i')),
              ),
            ),
          ),
        );

    await tester.pumpWidget(buildApp());
    double end() => stick.scroll.position.maxScrollExtent;

    // 初始贴底并跳到底部（模拟 scrollSignal 落地）。
    stick.stick = true;
    stick.jumpToEnd();
    await tester.pumpAndSettle();
    expect(stick.scroll.position.pixels, end());
    expect(stick.stick, isTrue);

    // 布局增长（追加 5 条；pixels 不动 extent 变）→ 贴底重跳。
    itemCount = 35;
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(stick.scroll.position.pixels, end(), reason: '布局增长后应保持贴底');
    expect(stick.stick, isTrue);

    // 用户上翻（pixels 变化）→ 停止跟随。
    stick.scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(stick.stick, isFalse);

    // 上翻状态下内容再增长 → 不跟随。
    itemCount = 40;
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(stick.scroll.position.pixels, 0);

    // 用户回到底部附近 → 恢复跟随，下一次增长重新贴底。
    stick.scroll.jumpTo(end());
    await tester.pumpAndSettle();
    expect(stick.stick, isTrue);
    itemCount = 45;
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(stick.scroll.position.pixels, end(), reason: '恢复跟随后增长应重新贴底');
  });
}
