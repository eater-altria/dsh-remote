import 'package:flutter/widgets.dart';

/// 贴底跟随控制器：聊天列表的「滚到底」语义。
///
/// - 用户滚动（pixels 变化）更新贴底标志：底部附近 = 跟随，上翻 = 停止。
/// - 布局增长（图片异步加载、流式追加、量算变化）只改变 maxScrollExtent，
///   不触发滚动监听——Flutter 会派 ScrollMetricsNotification，由页面层
///   转发到 [onMetricsChanged]：贴底状态下重新跳到底。
///   （旧实现只有滚动监听：入口跳底发生在布局稳定前，之后的增长无人纠正，
///   表现为「进会话经常不滚到底」。）
class BottomStickController {
  final ScrollController scroll = ScrollController();

  /// 贴底状态：用户在底部附近时新内容自动跟随；上翻则停止跟随。
  bool stick = true;

  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!scroll.hasClients) return;
    final position = scroll.position;
    stick = position.pixels >= position.maxScrollExtent - 120;
  }

  /// ScrollMetricsNotification 入口：布局尺寸变化后若是贴底状态则重跳到底。
  void onMetricsChanged() {
    if (!stick || !scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (stick) jumpToEnd();
    });
  }

  void jumpToEnd() {
    if (!scroll.hasClients) return;
    scroll.jumpTo(scroll.position.maxScrollExtent);
  }

  void animateToEnd() {
    if (!scroll.hasClients) return;
    scroll.animateTo(
      scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void dispose() => scroll.dispose();
}
