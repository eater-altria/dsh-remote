import 'package:dsh_remote/state/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session/jobs 快照过滤掉已终结任务，只保留活动任务', () {
    final jobs = activeJobsFromSnapshot([
      {'id': 'bash-1', 'kind': 'bash', 'label': 'build', 'status': 'completed'},
      {'id': 'bash-2', 'kind': 'bash', 'label': 'test', 'status': 'running'},
      {'id': 'bash-3', 'kind': 'bash', 'label': 'deploy', 'status': 'failed'},
      {'id': 'bash-4', 'kind': 'bash', 'label': 'watch', 'status': 'stopping'},
      {'id': 'bash-5', 'kind': 'bash', 'label': 'old', 'status': 'killed'},
    ]);
    expect(jobs.map((j) => j['id']), ['bash-2', 'bash-4']);
  });

  test('空快照与脏数据安全返回空列表', () {
    expect(activeJobsFromSnapshot(null), isEmpty);
    expect(activeJobsFromSnapshot(const []), isEmpty);
    expect(
      activeJobsFromSnapshot(['junk', {'id': 'x', 'status': 'running'}]),
      hasLength(1),
    );
  });

  test('未知 status 视为活动任务（向前兼容）', () {
    final jobs = activeJobsFromSnapshot([
      {'id': 'bash-1', 'status': 'queued'},
    ]);
    expect(jobs, hasLength(1));
  });
}
