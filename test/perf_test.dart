import 'dart:io';

import 'package:dsh_remote/api/fold.dart';
import 'package:flutter_test/flutter_test.dart';

/// 性能基准：用真实 host 抓包（含 40k chunk 事件的 9.5MB 历史页 vs relay
/// slim 后的 1.6MB 页）验证解析+折叠的开销量级。
void main() {
  late String fullBody;
  late String slimBody;

  setUpAll(() {
    fullBody = File('test/fixtures/history_full.json').readAsStringSync();
    slimBody = File('test/fixtures/history_slim.json').readAsStringSync();
  });

  test('fold slim page (relay 瘦身后的真实数据)', () {
    final sw = Stopwatch()..start();
    final result = parseAndFoldHistory(HistoryFoldTask(body: slimBody, isTail: true));
    sw.stop();
    // ignore: avoid_print
    print('slim: ${slimBody.length} bytes -> ${result.fold.items.length} items in ${sw.elapsedMilliseconds}ms');
    expect(result.fold.items, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('fold full page (未瘦身的 9.5MB / 40k chunk 事件)', () {
    final sw = Stopwatch()..start();
    final result = parseAndFoldHistory(HistoryFoldTask(body: fullBody, isTail: true));
    sw.stop();
    // ignore: avoid_print
    print('full: ${fullBody.length} bytes -> ${result.fold.items.length} items in ${sw.elapsedMilliseconds}ms');
    expect(result.fold.items, isNotEmpty);
  });
}
