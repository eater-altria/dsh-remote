import 'dart:io';

import 'package:dsh_remote/api/client.dart';
import 'package:dsh_remote/state/providers.dart';
import 'package:dsh_remote/ui/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 活集成测试：连真实 relay，渲染子代理聊天页。
/// 需要 relay 运行中（127.0.0.1:3081）。这两个 id 是开发会话与其文档子代理。
///
/// 放行真实网络（flutter_test 默认把 HttpClient 替换为 400 mock）。
class _RealNetwork extends HttpOverrides {}

const kParentSession = 'session-d55d8330-5051-4149-88bc-adc8409d50c3';
const kChildSession = 'ebaf2242-de6c-457c-ac52-2cdf597c978a';

class _FixedConnection extends ConnectionNotifier {
  _FixedConnection(this.conn);

  final DshConnection conn;

  @override
  DshConnection? build() => conn;
}

void main() {
  HttpOverrides.global = _RealNetwork();

  testWidgets('subagent chat page renders without build exceptions', (tester) async {
    await tester.runAsync(() async {
      // 绑定在每个测试里重装 mock，必须在 runAsync 内再覆盖一次。
      HttpOverrides.global = _RealNetwork();
      final connection = DshConnection('http://127.0.0.1:3081');
      await connection.connect();
      expect(connection.status, ConnStatus.connected);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [connectionProvider.overrideWith(() => _FixedConnection(connection))],
          child: const MaterialApp(
            home: ChatPage(
              sessionId: kChildSession,
              parentSessionId: kParentSession,
              subagentMode: 'continuable',
            ),
          ),
        ),
      );
      // 等待历史加载与渲染稳定（runAsync 内 pump 不消耗真实时间，需真实 delay）。
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      }
      // 诊断：输出 chat 状态机快照。
      final container = ProviderScope.containerOf(
          tester.element(find.byType(ChatPage)));
      final chat = container.read(chatProvider(kChildSession));
      debugPrint('[diag] loading=${chat.loadingHistory} items=${chat.items.length} '
          'error=${chat.historyError} title=${chat.title}');
      // 若构建期有异常，ErrorWidget 会出现在树里。
      expect(find.textContaining('渲染出错'), findsNothing);
      // 应渲染出聊天列表。
      expect(find.byType(ListView), findsWidgets);

    });
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('model sheet exposes reasoning effort entry (parent session)', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = _RealNetwork();
      final connection = DshConnection('http://127.0.0.1:3081');
      await connection.connect();
      expect(connection.status, ConnStatus.connected);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [connectionProvider.overrideWith(() => _FixedConnection(connection))],
          child: const MaterialApp(home: ChatPage(sessionId: kParentSession)),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      }
      // 打开模型面板：思考强度入口必须存在（回归：曾因补丁静默丢失）。
      await tester.tap(find.byIcon(Icons.model_training));
      for (var i = 0; i < 15; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      }
      expect(find.text('思考强度'), findsWidgets);
      expect(find.textContaining('当前：kimi-coding / k3'), findsWidgets);
    });
  }, timeout: const Timeout(Duration(seconds: 60)));
}
