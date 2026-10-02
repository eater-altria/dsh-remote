/// 本地通知：会话回合结束（running true→false）时提醒。
///
/// 监听 `$events` 的 `api-session/status` emit，跟踪每个会话的运行态；
/// 仅在 App 处于后台时发通知（前台时用户已经看得到）。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_settings.dart';
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

    // 监听连接生命周期：连上后订阅事件流。
    _ref.listen(connectionProvider, (_, connection) {
      if (connection == null) return;
      connection.emits.listen(_onEmit);
      // session/control 的 title 投影用于让通知文案带上会话标题。
      connection.followStream('session/control').listen(_onControlFrame, onError: (_) {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
  }

  void _onControlFrame(dynamic frame) {
    if (frame is! Map<String, dynamic>) return;
    if (frame['type'] == 'projection' && frame['key'] == 'title') {
      final sessionId = frame['sessionId'] as String?;
      final title = frame['value'];
      if (sessionId != null && title is String && title.isNotEmpty) {
        _titles[sessionId] = title;
      }
    } else if (frame['type'] == 'baseline') {
      final value = (frame['value'] as Map?)?.cast<String, dynamic>() ?? const {};
      final projections = (value['projections'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final entry in projections.entries) {
        final block = entry.value;
        if (block is Map<String, dynamic>) {
          final values = block['values'];
          if (values is Map<String, dynamic>) {
            final t = values['title'];
            if (t is String && t.isNotEmpty) _titles[entry.key] = t;
          }
        }
      }
    }
  }

  void _onEmit(Map<String, dynamic> frame) {
    if (frame['event'] != 'api-session/status') return;
    final args = frame['args'] as List? ?? const [];
    if (args.length < 2) return;
    final sessionId = args[0] as String?;
    final running = args[1] as bool?;
    if (sessionId == null || running == null) return;
    final was = _running[sessionId] ?? false;
    _running[sessionId] = running;
    // running true→false = 一个回合结束。
    if (was && !running && !_inForeground && _initialized) {
      final s = _ref.read(stringsProvider);
      final title = _titles[sessionId] ?? s.notifSessionFallback;
      _plugin.show(
        sessionId.hashCode,
        s.notifTurnDoneTitle,
        s.notifTurnDoneBody(title),
        NotificationDetails(
          android: AndroidNotificationDetails(_channelId, s.notifChannelName,
              importance: Importance.defaultImportance),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    }
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService(ref);
  return service;
});
