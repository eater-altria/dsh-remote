import 'package:dsh_remote/api/fold.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('approval/asked 落待决卡，approval/decided 按 id 回填结果', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'approval/asked',
      'seq': 1,
      'data': {'id': 'ap1', 'toolName': 'bash', 'reason': '需要写入工作区外目录', 'callId': 'c1'},
    });

    var item = fold.items.single as ApprovalItem;
    expect(item.approvalId, 'ap1');
    expect(item.toolName, 'bash');
    expect(item.reason, '需要写入工作区外目录');
    expect(item.outcome, isNull);

    fold.applyEvent({
      'type': 'approval/decided',
      'seq': 2,
      'data': {'id': 'ap1', 'outcome': 'allowed-once'},
    });
    expect(fold.items, hasLength(1)); // 原地更新，不追加新卡
    item = fold.items.single as ApprovalItem;
    expect(item.outcome, 'allowed-once');
  });

  test('多个审批各自配对，互不误填', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'approval/asked',
      'seq': 1,
      'data': {'id': 'ap1', 'toolName': 'bash'},
    });
    fold.applyEvent({
      'type': 'approval/asked',
      'seq': 2,
      'data': {'id': 'ap2', 'toolName': 'write'},
    });
    fold.applyEvent({
      'type': 'approval/decided',
      'seq': 3,
      'data': {'id': 'ap2', 'outcome': 'rejected'},
    });

    final items = fold.items.whereType<ApprovalItem>().toList();
    expect(items, hasLength(2));
    expect(items[0].outcome, isNull);
    expect(items[1].outcome, 'rejected');
  });

  test('重复的 asked 不落第二张卡；孤儿 decided 补一张已决卡', () {
    final fold = ChatFold();
    for (var i = 0; i < 2; i++) {
      fold.applyEvent({
        'type': 'approval/asked',
        'seq': i + 1,
        'data': {'id': 'ap1', 'toolName': 'bash'},
      });
    }
    expect(fold.items.whereType<ApprovalItem>(), hasLength(1));

    fold.applyEvent({
      'type': 'approval/decided',
      'seq': 10,
      'data': {'id': 'ap-orphan', 'outcome': 'cancelled'},
    });
    final orphan = fold.items.whereType<ApprovalItem>().last;
    expect(orphan.approvalId, 'ap-orphan');
    expect(orphan.outcome, 'cancelled');
  });

  test('审批事件出现在历史页（live: false）也能落卡', () {
    final fold = ChatFold();
    fold.applyEvent({
      'type': 'approval/asked',
      'seq': 1,
      'data': {'id': 'ap1', 'toolName': 'bash'},
    }, live: false);
    fold.applyEvent({
      'type': 'approval/decided',
      'seq': 2,
      'data': {'id': 'ap1', 'outcome': 'allowed-once'},
    }, live: false);
    final item = fold.items.single as ApprovalItem;
    expect(item.outcome, 'allowed-once');
  });
}
