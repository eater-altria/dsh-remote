import 'package:dsh_remote/api/push_dedupe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首次见到的推送返回 true，重复 id 返回 false', () async {
    SharedPreferences.setMockInitialValues({});
    final dedupe = PushDedupe();
    expect(await dedupe.markIfNew('a'), isTrue);
    expect(await dedupe.markIfNew('a'), isFalse);
    expect(await dedupe.markIfNew('a'), isFalse);
  });

  test('App 重启（新实例）后已处理的推送不再弹', () async {
    SharedPreferences.setMockInitialValues({});
    final first = PushDedupe();
    expect(await first.markIfNew('a'), isTrue);
    expect(await first.markIfNew('b'), isTrue);

    // 模拟冷启动：全新实例从 SharedPreferences 恢复。
    final second = PushDedupe();
    expect(await second.markIfNew('a'), isFalse);
    expect(await second.markIfNew('b'), isFalse);
    expect(await second.markIfNew('c'), isTrue);
  });

  test('空 id 直接丢弃且不写入持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final dedupe = PushDedupe();
    expect(await dedupe.markIfNew(''), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('dsh.handledPushIds'), isNull);
  });

  test('超出上限时裁剪最旧的 id', () async {
    SharedPreferences.setMockInitialValues({});
    final dedupe = PushDedupe(maxEntries: 3);
    for (final id in ['a', 'b', 'c', 'd']) {
      expect(await dedupe.markIfNew(id), isTrue);
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('dsh.handledPushIds'), ['b', 'c', 'd']);

    // 最旧的 a 已被裁剪，重启后会被当作新推送（可接受的边界行为）。
    final restarted = PushDedupe(maxEntries: 3);
    expect(await restarted.markIfNew('d'), isFalse);
    expect(await restarted.markIfNew('a'), isTrue);
  });

  test('并发 markIfNew 共享同一次加载，不会互相覆盖', () async {
    SharedPreferences.setMockInitialValues({});
    final dedupe = PushDedupe();
    final results = await Future.wait([
      dedupe.markIfNew('a'),
      dedupe.markIfNew('b'),
      dedupe.markIfNew('a'),
    ]);
    expect(results, [isTrue, isTrue, isFalse]);

    final restarted = PushDedupe();
    expect(await restarted.markIfNew('a'), isFalse);
    expect(await restarted.markIfNew('b'), isFalse);
  });
}
