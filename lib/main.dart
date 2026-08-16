import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/notifications.dart';
import 'state/providers.dart';
import 'ui/hosts_page.dart';
import 'ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // release 下构建期异常默认渲染为空白——换成可见错误卡片 + 日志，便于诊断。
  ErrorWidget.builder = (details) {
    debugPrint('[error] \${details.exceptionAsString()}\n\${details.stack}');
    return Material(
      color: const Color(0xFFF9E3E3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '渲染出错：\${details.exceptionAsString()}',
          style: const TextStyle(color: Color(0xFF6B2B2B), fontSize: 12),
        ),
      ),
    );
  };
  final container = ProviderContainer();
  await container.read(notificationServiceProvider).init();
  runApp(UncontrolledProviderScope(container: container, child: const DshRemoteApp()));
}

class DshRemoteApp extends ConsumerWidget {
  const DshRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      theme: NekoTheme.light(),
      darkTheme: NekoTheme.dark(),
      themeMode: switch (mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      // null = 主机列表尚未从磁盘恢复，先渲染加载态避免闪空页。
      home: hosts == null
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : const HostsPage(),
    );
  }
}
