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

  test('fold pairs tool results with calls', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'tool/call',
      'seq': 1,
      'time': 0,
      'data': {'callId': 'c1', 'name': 'bash', 'arguments': '{"command":"ls"}'},
    });
    fold.applyEvent({
      'type': 'tool/result',
      'seq': 2,
      'time': 0,
      'data': {'callId': 'c1', 'content': 'ok'},
    });
    expect(fold.items, hasLength(1));
    final tool = fold.items.first as ToolItem;
    expect(tool.name, 'bash');
    expect(tool.finished, isTrue);
    expect(tool.resultPreview, 'ok');
  });
}
