import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_settings.dart';

/// 设置页（本地 App 设置，与 host 无关）：
/// - 工作时发送消息：排队 / 插队
/// - 语言：跟随系统 / 中文 / English
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final sendMode = ref.watch(sendModeProvider);
    final locale = ref.watch(localeSettingProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          _SectionHeader(title: s.sectionBehavior),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: Text(s.sendModeTitle),
              subtitle: Text(s.sendModeSubtitle),
              trailing: Text(
                sendMode == 'steer' ? s.sendModeSteer : s.sendModeQueue,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => _pickSendMode(context, ref, s, sendMode),
            ),
          ),
          _SectionHeader(title: s.sectionGeneral),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: const Icon(Icons.translate_outlined),
              title: Text(s.languageTitle),
              trailing: Text(
                _localeLabel(s, locale),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => _pickLocale(context, ref, s, locale),
            ),
          ),
        ],
      ),
    );
  }

  String _localeLabel(S s, String locale) => switch (locale) {
        'zh' => '中文',
        'en' => 'English',
        _ => s.langSystem,
      };

  Future<void> _pickSendMode(BuildContext context, WidgetRef ref, S s, String current) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _OptionTile(
              title: s.sendModeQueue,
              subtitle: s.sendModeQueueDesc,
              selected: current == 'queue',
              value: 'queue',
            ),
            _OptionTile(
              title: s.sendModeSteer,
              subtitle: s.sendModeSteerDesc,
              selected: current == 'steer',
              value: 'steer',
            ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != current) {
      await ref.read(sendModeProvider.notifier).setMode(chosen);
    }
  }

  Future<void> _pickLocale(BuildContext context, WidgetRef ref, S s, String current) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _OptionTile(title: s.langSystem, selected: current == 'system', value: 'system'),
            _OptionTile(title: '中文', selected: current == 'zh', value: 'zh'),
            _OptionTile(title: 'English', selected: current == 'en', value: 'en'),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != current) {
      await ref.read(localeSettingProvider.notifier).setLocale(chosen);
    }
  }
}

/// 底部弹层选项行（design.md §4 bottom sheet 模式）。
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.title,
    required this.selected,
    required this.value,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => Navigator.pop(context, value),
    );
  }
}

/// 分组节标题（design.md §4：titleSmall 灰蓝节标题）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
