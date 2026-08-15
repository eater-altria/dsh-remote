/// 本地通知：会话回合结束（running true→false）时提醒。
///
/// 监听 host downlink 的 `host/session-status` 帧，跟踪每个会话的运行态；
/// 仅在 App 处于后台时发通知（前台时用户已经看得到）。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'wire.dart';
import '../state/providers.dart';

class NotificationService with WidgetsBindingObserver {
  NotificationService(this._ref);

  final Ref _ref;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _running = <String, bool>{};
  final _titles = <String, String>{};
  bool _inForeground = true;
  bool _initialized = false;

  static const _channelId = 'dsh_turn_done';
  static const _channelName = '回合完成';

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: DarwinInitializationSettings()),
    );
    // Android 13+ 需要运行时权限。
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;

    // 监听连接生命周期：连上后订阅 host 帧。
    _ref.listen(connectionProvider, (_, connection) {
      if (connection == null) return;
      connection.hostFrames.listen(_onHostFrame);
      // mux 的 session/projection(title) 用于让通知文案带上会话标题。
      connection.muxFrames.listen(_onMuxFrame);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
  }

  void _onMuxFrame(ServerRequestFrame frame) {
    final payload = frame.payload;
    if (payload['type'] == 'session/projection' && payload['key'] == 'title') {
      final sessionId = payload['sessionId'] as String?;
      final title = payload['value'];
      if (sessionId != null && title is String && title.isNotEmpty) {
        _titles[sessionId] = title;
      }
    }
  }

  void _onHostFrame(ServerRequestFrame frame) {
    final payload = frame.payload;
    if (payload['type'] != 'host/session-status') return;
    final sessionId = payload['sessionId'] as String?;
    final running = payload['running'] as bool?;
    if (sessionId == null || running == null) return;
    final was = _running[sessionId] ?? false;
    _running[sessionId] = running;
    // running true→false = 一个回合结束。
    if (was && !running && !_inForeground && _initialized) {
      final title = _titles[sessionId] ?? '会话';
      _plugin.show(
        sessionId.hashCode,
        '回合完成',
        '「$title」的回答已完成',
        const NotificationDetails(
          android: AndroidNotificationDetails(_channelId, _channelName, importance: Importance.defaultImportance),
          iOS: DarwinNotificationDetails(),
        ),
      );
    }
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService(ref);
  return service;
});
