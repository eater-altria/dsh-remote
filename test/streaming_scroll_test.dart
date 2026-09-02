import 'dart:async';

import 'package:dsh_remote/ui/bottom_stick.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻聊天页的滚动接线：metrics 通知（布局增长）+ user-scroll 通知（拖动打断）
/// + build 驱动的签名跟随（_maybeScrollToEnd 同款），外加 40ms 流式追加。
class _StreamingChatHarness extends StatefulWidget {
  const _StreamingChatHarness({required this.stick, required this.ticker});

  final BottomStickController stick;

  /// 每 40ms 返回是否追加一条新内容（模拟流式 chunk）。
  final bool Function() ticker;

  @override
  State<_StreamingChatHarness> createState() => _StreamingChatHarnessState();
}

class _StreamingChatHarnessState extends State<_StreamingChatHarness> {
  int _count = 30;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.stick.attach();
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!widget.ticker()) return;
      setState(() => _count++);
      // 与页面一致：内容签名变化时若贴底则 animateToEnd。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.stick.stick) widget.stick.jumpToEnd();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: NotificationListener<UserScrollNotification>(
          onNotification: (n) {
            widget.stick.onUserScroll(n.direction);
            return false;
          },
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              widget.stick.onMetricsChanged();
              return false;
            },
            child: ListView.builder(
              controller: widget.stick.scroll,
              itemCount: _count,
              itemBuilder: (_, i) => SizedBox(height: 100, child: Text('item-$i')),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('流式期间用户上翻可以逃离底部（不被动画链钉住）', (tester) async {
    final stick = BottomStickController();
    addTearDown(stick.dispose);
    var streaming = true;

    await tester.pumpWidget(_StreamingChatHarness(stick: stick, ticker: () => streaming));
    stick.stick = true;
    stick.jumpToEnd();
    await tester.pump();

    // 流式增长一段，确认钉在底部。
    await tester.pump(const Duration(milliseconds: 500));
    expect(stick.scroll.position.pixels, stick.scroll.position.maxScrollExtent);
    expect(stick.stick, isTrue);

    // 用户快速上翻（拖拽 + 惯性）。
    await tester.fling(find.byType(ListView), const Offset(0, 600), 3000);
    await tester.pump();

    // 惯性滚动期间持续流式追加——若被动画链钉住，pixels 会被拽回底部。
    var escaped = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (stick.scroll.position.pixels < stick.scroll.position.maxScrollExtent - 120) {
        escaped = true;
      }
    }
    expect(escaped, isTrue, reason: '流式期间用户上翻应能离开底部');
    expect(stick.stick, isFalse);

    // 停止流式，用户回到底部恢复跟随。
    streaming = false;
    await tester.pumpAndSettle();
    stick.scroll.jumpTo(stick.scroll.position.maxScrollExtent);
    await tester.pump();
    expect(stick.stick, isTrue);
  });
}
