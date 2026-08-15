import 'package:dsh_remote/api/fold.dart';
import 'package:dsh_remote/api/wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wire envelope round-trips a success response', () {
    final rpcId = mintRpcId();
    final request = clientRequest(rpcId, 'host.describe', const {});
    expect(request['type'], 'client-request');
    expect(request['rpcId'], rpcId);

    final body =
        '{"type":"server-response","rpcId":"$rpcId","result":{"ok":true,"value":{"version":"1.0"}}}';
    final value = decodeServerResponse(body, rpcId);
    expect((value as Map)['version'], '1.0');
  });

  test('wire envelope surfaces business errors as RpcException', () {
    final rpcId = mintRpcId();
    final body =
        '{"type":"server-response","rpcId":"$rpcId","result":{"ok":false,"error":{"code":"session-not-found","message":"gone","details":{"sessionId":"s1"}}}}';
    expect(
      () => decodeServerResponse(body, rpcId),
      throwsA(isA<RpcException>().having((e) => e.code, 'code', 'session-not-found')),
    );
  });

  test('fold builds user and assistant items from events', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'user/message',
      'seq': 0,
      'time': 0,
      'data': {
        'message': {
          'content': [
            {'type': 'text', 'text': '你好'}
          ]
        }
      },
    });
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 1,
      'time': 0,
      'data': {
        'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'text'}
      },
    });
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 2,
      'time': 0,
      'data': {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '你好呀'}
      },
    });
    fold.applyEvent({
      'type': 'assistant/message',
      'seq': 3,
      'time': 0,
      'data': {
        'message': {
          'content': [
            {'type': 'text', 'text': '你好呀'}
          ]
        }
      },
    });
    expect(fold.items, hasLength(2));
    expect(fold.items[0], isA<UserItem>());
    final assistant = fold.items[1] as AssistantItem;
    expect(assistant.blocks.first, isA<TextBlock>());
    expect((assistant.blocks.first as TextBlock).text, '你好呀');
  });

  test('fold pairs tool results with calls (real wire shapes)', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'tool/call',
      'seq': 1,
      'time': 0,
      'data': {'callId': 'tool_1', 'name': 'bash', 'arguments': '{"command":"ls"}'},
    }, view: {
      'for': 'call',
      'view': {'card': 'terminal', 'title': 'ls'},
    });
    fold.applyEvent({
      'type': 'tool/result',
      'seq': 2,
      'time': 0,
      'data': {
        'message': {
          'source': {'kind': 'tool', 'callId': 'tool_1'},
          'content': [
            {
              'type': 'tool-result',
              'toolCallId': 'tool_1',
              'content': [
                {'type': 'text', 'text': 'ok'}
              ]
            }
          ]
        }
      },
    });
    expect(fold.items, hasLength(1));
    final tool = fold.items.first as ToolItem;
    expect(tool.name, 'ls'); // 宿主卡片视图的 title 优先
    expect(tool.finished, isTrue);
    expect(tool.resultPreview, 'ok');
  });

  test('history mode skips assistant/chunk events', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 1,
      'time': 0,
      'data': {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '不应出现'}
      },
    });
    expect(fold.items, isEmpty);
    // live 模式才会折叠 chunk（进入独立的 partial 流式区，不进 items）
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 2,
      'time': 0,
      'data': {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '流式'}
      },
    }, live: true);
    expect(fold.items, isEmpty);
    expect(fold.partial, isNotNull);
    expect((fold.partial!.blocks.first as TextBlock).text, '流式');
  });

  foldRobustnessTests();

  test('系统注入消息（source.kind != user）不按用户气泡渲染', () {
    final fold = ChatFold();
    // 真用户消息
    fold.applyEvent({
      'type': 'user/message',
      'seq': 1,
      'time': 0,
      'data': {
        'id': 'u1',
        'source': {'kind': 'user', 'rpcId': 'r1'},
        'content': [
          {'type': 'text', 'text': '主人说的话'}
        ]
      },
    });
    // 子代理通报
    fold.applyEvent({
      'type': 'user/message',
      'seq': 2,
      'time': 0,
      'data': {
        'id': 's1',
        'source': {'kind': 'subagent-report'},
        'content': [
          {'type': 'text', 'text': 'Background subagent xxx reported: ...'}
        ]
      },
    });
    expect(fold.items[0], isA<UserItem>());
    expect(fold.items[1], isA<SystemItem>());
    expect((fold.items[1] as SystemItem).kind, 'subagent-report');
  });
}

void foldRobustnessTests() {
  test('chunk index 超上限被忽略（防 OOM）', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 1,
      'time': 0,
      'data': {
        'chunk': {'type': 'text-delta', 'index': 1000000000, 'text': 'boom'}
      },
    }, live: true);
    expect(fold.partial, isNull);
  });

  test('未知 blockType 不产生可见气泡', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 1,
      'time': 0,
      'data': {
        'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'alien-tech'}
      },
    }, live: true);
    expect(fold.partial, isNull);
  });

  test('turn/end 无收尾消息时 partial 落表为中断项', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'assistant/chunk',
      'seq': 1,
      'time': 0,
      'data': {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '说了一半'}
      },
    }, live: true);
    fold.applyEvent({'type': 'turn/end', 'seq': 2, 'time': 0, 'data': {}});
    expect(fold.partial, isNull);
    expect(fold.items, hasLength(1));
    final item = fold.items.first as AssistantItem;
    expect((item.blocks.last as TextBlock).text, contains('中断'));
  });

  test('重复消息按 id 去重，tool/call 重放不产生第二张卡', () {
    final fold = ChatFold();
    final msg = {
      'type': 'assistant/message',
      'seq': 1,
      'time': 0,
      'data': {
        'message': {
          'id': 'm1',
          'content': [
            {'type': 'text', 'text': '你好'}
          ]
        }
      },
    };
    fold.applyEvent(msg);
    fold.applyEvent(msg); // 重放
    expect(fold.items, hasLength(1));

    final call = {
      'type': 'tool/call',
      'seq': 2,
      'time': 0,
      'data': {'callId': 'c1', 'name': 'bash', 'arguments': '{}'},
    };
    fold.applyEvent(call);
    fold.applyEvent(call); // 重放
    expect(fold.items.whereType<ToolItem>(), hasLength(1));
  });
}
