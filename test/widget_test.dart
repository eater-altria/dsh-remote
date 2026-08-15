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
}
