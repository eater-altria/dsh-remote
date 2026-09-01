import 'dart:io';

import 'package:dsh_remote/api/fold.dart';
import 'package:flutter_test/flutter_test.dart';

/// 性能基准：用真实 host 抓取（session/follow snapshot 与 session/page，
/// 新协议 records 形状，含 chunkrow 压缩行）验证解析+折叠的开销量级。
void main() {
  late String snapshotBody;
  late String pageBody;

  setUpAll(() {
    snapshotBody = File('test/fixtures/history_snapshot.json').readAsStringSync();
    pageBody = File('test/fixtures/history_page.json').readAsStringSync();
  });

  test('fold follow snapshot（尾部页 + 投影基线）', () {
    final sw = Stopwatch()..start();
    final result = parseAndFoldHistory(HistoryFoldTask(body: snapshotBody, isTail: true));
    sw.stop();
    // ignore: avoid_print
    print('snapshot: ${snapshotBody.length} bytes -> ${result.fold.items.length} items in ${sw.elapsedMilliseconds}ms');
    expect(result.fold.items, isNotEmpty);
    expect(result.projections, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('fold session/page（更早的历史页）', () {
    final sw = Stopwatch()..start();
    final result = parseAndFoldHistory(HistoryFoldTask(body: pageBody, isTail: false));
    sw.stop();
    // ignore: avoid_print
    print('page: ${pageBody.length} bytes -> ${result.fold.items.length} items in ${sw.elapsedMilliseconds}ms');
    expect(result.fold.items, isNotEmpty);
    expect(result.hasMore, isTrue);
  });
}
