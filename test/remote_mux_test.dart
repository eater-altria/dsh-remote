import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/api/client.dart';
import 'package:dsh_remote/api/wire.dart';
import 'package:flutter_test/flutter_test.dart';

/// RemoteMux / DshApi 传输层离线测试：本地假 mux 服务器，不依赖真实 dsh。
class _FakeMuxServer {
  _FakeMuxServer(this.server);

  final HttpServer server;
  final List<Map<String, dynamic>> receivedFrames = [];
  final List<Map<String, dynamic>> receivedRpc = [];
  final List<WebSocket> sockets = [];

  static Future<_FakeMuxServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeMuxServer(server);
    server.listen((req) async {
      if (req.uri.path == '/api/remote.mux' && WebSocketTransformer.isUpgradeRequest(req)) {
        final socket = await WebSocketTransformer.upgrade(req);
        fake.sockets.add(socket);
        socket.listen((data) {
          final frame = jsonDecode(data as String) as Map<String, dynamic>;
          fake.receivedFrames.add(frame);
          fake._onFrame(socket, frame);
        });
        return;
      }
      if (req.uri.path == '/api/session/list' && req.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        fake.receivedRpc.add(body);
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'type': 'server-response',
            'rpcId': body['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'items': [
                  {'sessionId': 's1', 'updatedAt': 1, 'running': false, 'blank': true},
                ],
              },
            },
          }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    return fake;
  }

  void _onFrame(WebSocket socket, Map<String, dynamic> frame) {
    if (frame['type'] != 'open') return;
    final streamId = frame['streamId'] as String;
    final endpoint = frame['endpoint'] as String;
    void send(Map<String, dynamic> out) => socket.add(jsonEncode(out));
    switch (endpoint) {
      case 'test/echo':
        send({'type': 'item', 'streamId': streamId, 'value': {'hello': 'world'}});
        send({'type': 'end', 'streamId': streamId});
      case 'test/fail':
        send({
          'type': 'error',
          'streamId': streamId,
          'error': {'code': 'gateway/internal', 'message': 'boom', 'details': {}},
        });
      case 'test/ticker':
        send({'type': 'item', 'streamId': streamId, 'value': 1});
        send({'type': 'item', 'streamId': streamId, 'value': 2});
      default:
        send({
          'type': 'error',
          'streamId': streamId,
          'error': {'code': 'gateway/bad-request', 'message': 'unknown endpoint', 'details': {}},
        });
    }
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

void main() {
  late _FakeMuxServer fake;
  late DshConnection connection;

  setUp(() async {
    fake = await _FakeMuxServer.start();
    connection = DshConnection(fake.baseUrl);
  });

  tearDown(() async {
    connection.dispose();
    await fake.close();
  });

  test('unary rpc：信封包装 + server-response 解包', () async {
    final api = DshApi(fake.baseUrl);
    addTearDown(api.dispose);
    final value = await api.rpc('session/list', {'_request': {}});
    expect((value as Map)['items'], hasLength(1));

    // 验证服务端收到的信封形状（payload 恰好一个 args 键，method 与端点一致）。
    expect(fake.receivedRpc, hasLength(1));
    final envelope = fake.receivedRpc.single;
    expect(envelope['type'], 'client-request');
    expect(envelope['method'], 'session/list');
    expect(envelope['payload'], {
      'args': {'_request': {}},
    });
  });

  test('mux 开流：item + end 帧路由', () async {
    final mux = RemoteMux.connect(Uri.parse('${fake.baseUrl.replaceFirst('http', 'ws')}/api/remote.mux'));
    mux.listen();
    addTearDown(mux.close);

    final items = await mux.openStream('test/echo').items.toList();
    expect(items, [
      {'hello': 'world'},
    ]);

    // 验证开流帧形状（exact-keys：type/streamId/endpoint/payload）。
    expect(fake.receivedFrames, hasLength(1));
    final open = fake.receivedFrames.single;
    expect(open.keys, containsAll(['type', 'streamId', 'endpoint', 'payload']));
    expect(open['type'], 'open');
    expect(open['endpoint'], 'test/echo');
    expect(open['payload'], {'args': {}});
  });

  test('mux 错误帧：透传 RpcException', () async {
    final mux = RemoteMux.connect(Uri.parse('${fake.baseUrl.replaceFirst('http', 'ws')}/api/remote.mux'));
    mux.listen();
    addTearDown(mux.close);

    await expectLater(
      mux.openStream('test/fail').items.toList(),
      throwsA(isA<RpcException>().having((e) => e.code, 'code', 'gateway/internal')),
    );
  });

  test('mux 取消：消费者取消订阅时发送 cancel 帧', () async {
    final mux = RemoteMux.connect(Uri.parse('${fake.baseUrl.replaceFirst('http', 'ws')}/api/remote.mux'));
    mux.listen();
    addTearDown(mux.close);

    final sub = mux.openStream('test/ticker').items.listen((_) {});
    // 等两条 item 到达后取消。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final cancels = fake.receivedFrames.where((f) => f['type'] == 'cancel').toList();
    expect(cancels, hasLength(1));
    expect(cancels.single.keys, containsAll(['type', 'streamId']));
  });

  test('物理 socket 关闭：所有活跃流收到错误并结束', () async {
    final mux = RemoteMux.connect(Uri.parse('${fake.baseUrl.replaceFirst('http', 'ws')}/api/remote.mux'));
    mux.listen();

    final done = Completer<void>();
    mux.openStream('test/ticker').items.listen((_) {}, onError: (_) {}, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await fake.sockets.last.close();
    await done.future.timeout(const Duration(seconds: 5));
    await mux.close();
  });
}
