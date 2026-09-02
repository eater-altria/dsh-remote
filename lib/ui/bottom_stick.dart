import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// 贴底跟随控制器：聊天列表的「滚到底」语义。
///
/// 核心设计（流式 + 实测迭代定稿）：
/// - **用户手指持有列表期间（_userActive），程序 jump 全部静默**——jumpTo
///   会掐断进行中的拖拽，流式期间 40ms 一跳等于用户永远抢不到列表。
/// - **上翻（reverse）立即停止跟随**，不等 120px 阈值——流式增长会让 extent
///   追着 pixels 跑，阈值判定可能永远追不上。
/// - 松手（idle）按落点重估：接近底部（120px 内）恢复跟随。
/// - 布局增长（图片加载/流式追加）不触发滚动监听，走 ScrollMetricsNotification
///   → [onMetricsChanged] 贴底重跳。
class BottomStickController {
  final ScrollController scroll = ScrollController();

  /// 贴底状态：跟随内容增长；用户上翻即脱离。
  bool stick = true;

  /// 用户手指持有列表（UserScrollNotification 非 idle → idle 之间）。
  bool _userActive = false;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!scroll.hasClients) return;
    final position = scroll.position;
    // 明显离开底部（120px+）即停止跟随——拖动期间也生效（jump 已被
    // _userActive 抑制，extent 追不上手指，阈值可靠）。
    if (position.pixels <= position.maxScrollExtent - 120) {
      stick = false;
    } else if (!_userActive && position.pixels >= position.maxScrollExtent - 4) {
      stick = true; // 非拖动期间真正落地底部才恢复
    }
  }

  /// UserScrollNotification 入口（仅用户驱动滚动触发，程序 jump 不会进这里）。
  /// 方向标签在跳动争抢下不可靠，只用来感知「用户持有/松手」；贴底状态由
  /// _onScroll 的滞回阈值和松手落点决定。
  void onUserScroll(ScrollDirection direction) {
    if (!scroll.hasClients) return;
    _userActive = direction != ScrollDirection.idle;
    if (direction == ScrollDirection.idle) {
      // 松手后按落点重估：接近底部即恢复跟随。
      final position = scroll.position;
      stick = position.pixels >= position.maxScrollExtent - 120;
    }
  }

  /// ScrollMetricsNotification 入口：布局尺寸变化后若贴底则重跳到底。
  void onMetricsChanged() {
    if (!stick || _userActive || !scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (stick && !_userActive) jumpToEnd();
    });
  }

  void jumpToEnd() {
    if (!scroll.hasClients || _userActive) return; // 用户手里有列表时不抢
    scroll.jumpTo(scroll.position.maxScrollExtent);
  }

  /// 一次性平滑滚底（发送消息等主动作场景；逐 chunk 跟随请用 jumpToEnd）。
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
