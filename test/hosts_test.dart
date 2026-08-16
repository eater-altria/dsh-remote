import 'package:dsh_remote/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _makeContainer() async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(hostsProvider.notifier).ready;
  await container.read(activeHostIdProvider.notifier).ready;
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('无历史配置时主机列表为空', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await _makeContainer();
    expect(container.read(hostsProvider), isEmpty);
    expect(container.read(activeHostProvider), isNull);
  });

  test('单主机遗留配置自动迁移为第一台主机并清除旧键', () async {
    SharedPreferences.setMockInitialValues({
      'dsh.serverUrl': 'http://192.168.1.5:3081',
      'dsh.relayToken': 'tok',
    });
    final container = await _makeContainer();

    final hosts = container.read(hostsProvider)!;
    expect(hosts, hasLength(1));
    expect(hosts.single.url, 'http://192.168.1.5:3081');
    expect(hosts.single.name, '192.168.1.5:3081');
    expect(hosts.single.token, 'tok');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dsh.serverUrl'), isNull);
    expect(prefs.getString('dsh.relayToken'), isNull);
    expect(prefs.getString('dsh.hostProfiles'), isNotNull);
  });

  test('新增 / 编辑 / 删除主机并跨重启（新容器）持久化', () async {
    SharedPreferences.setMockInitialValues({});
    var container = await _makeContainer();
    final added = await container
        .read(hostsProvider.notifier)
        .add(url: 'http://a.local:3081', name: '', token: 't1');
    expect(added.name, 'a.local:3081'); // 默认名取 host:port

    await container.read(hostsProvider.notifier).add(
        url: 'http://b.local:3081', name: '备用机', token: '');
    await container.read(hostsProvider.notifier).update(
          added.copyWith(name: '主力机'),
        );

    // 模拟重启：新容器从磁盘恢复。
    container.dispose();
    container = await _makeContainer();
    final hosts = container.read(hostsProvider)!;
    expect(hosts, hasLength(2));
    expect(hosts[0].name, '主力机');
    expect(hosts[0].token, 't1');
    expect(hosts[1].name, '备用机');

    await container.read(hostsProvider.notifier).remove(hosts[0].id);
    expect(container.read(hostsProvider), hasLength(1));
  });

  test('选中主机后 activeHostProvider 解析出完整配置；删除选中主机会清除选择', () async {    SharedPreferences.setMockInitialValues({});
    final container = await _makeContainer();
    final host = await container
        .read(hostsProvider.notifier)
        .add(url: 'http://a.local:3081');

    await container.read(activeHostIdProvider.notifier).select(host.id);
    expect(container.read(activeHostProvider)?.url, 'http://a.local:3081');

    // 模拟重启：选择也持久化。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dsh.activeHostId'), host.id);

    await container.read(hostsProvider.notifier).remove(host.id);
    expect(container.read(activeHostIdProvider), isNull);
    expect(container.read(activeHostProvider), isNull);
  });
}
