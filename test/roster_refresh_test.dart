import 'dart:io';

import 'package:dsh_remote/api/client.dart';
import 'package:dsh_remote/state/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// roster 自动刷新回归测试（连真实 relay 127.0.0.1:3081）：
/// 连接中与预连接两种进入时序下，会话列表都应自动加载完成。
class _RealNetwork extends HttpOverrides {}

void main() {
  HttpOverrides.global = _RealNetwork();

  testWidgets('连接过程中进入会话列表：connected 后自动加载完成', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = _RealNetwork();
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(hostsProvider.notifier).ready;
      await container.read(activeHostIdProvider.notifier).ready;

      final host = await container
          .read(hostsProvider.notifier)
          .add(url: 'http://127.0.0.1:3081', name: 'local', token: '');
      await container.read(activeHostIdProvider.notifier).select(host.id);

      // 监听 roster 状态迁移。
      final transitions = <String>[];
      container.listen(rosterProvider, (prev, next) {
        transitions.add('loading=${next.loading} sessions=${next.sessions.length} err=${next.error}');
      }, fireImmediately: true);

      final connection = container.read(connectionProvider);
      expect(connection, isNotNull);
      debugPrint('[diag] connection status at t0: ${connection!.status}');

      // 等待 roster 脱离 loading（最多 20 秒）。
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (container.read(rosterProvider).loading && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      debugPrint('[diag] final connection status: ${connection.status}');
      for (final t in transitions) {
        debugPrint('[diag] $t');
      }
      expect(container.read(rosterProvider).loading, isFalse,
          reason: 'roster 20 秒内未完成自动加载');
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('回归：连接已就绪后首次进入会话列表（build 内同步 refresh 曾抛 StateError 致首刷丢失）', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = _RealNetwork();
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(hostsProvider.notifier).ready;
      await container.read(activeHostIdProvider.notifier).ready;

      final host = await container
          .read(hostsProvider.notifier)
          .add(url: 'http://127.0.0.1:3081', name: 'local', token: '');
      await container.read(activeHostIdProvider.notifier).select(host.id);

      // 关键差异：等连接达到 connected 之后才首次读 rosterProvider
      // （模拟冷启动时 activeHostId 已持久化，连接在主机列表页就提前建好了）。
      final connection = container.read(connectionProvider)!;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (connection.status != ConnStatus.connected && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      debugPrint('[diag2] connection status before roster read: ${connection.status}');

      final transitions = <String>[];
      container.listen(rosterProvider, (prev, next) {
        transitions.add('loading=${next.loading} sessions=${next.sessions.length} err=${next.error}');
      }, fireImmediately: true);

      final deadline2 = DateTime.now().add(const Duration(seconds: 10));
      while (container.read(rosterProvider).loading && DateTime.now().isBefore(deadline2)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      for (final t in transitions) {
        debugPrint('[diag2] $t');
      }
      debugPrint('[diag2] final: loading=${container.read(rosterProvider).loading} '
          'sessions=${container.read(rosterProvider).sessions.length}');
      expect(container.read(rosterProvider).loading, isFalse,
          reason: '预连接场景下 roster 10 秒内未完成自动加载');
    });
  }, timeout: const Timeout(Duration(seconds: 30)));
}
