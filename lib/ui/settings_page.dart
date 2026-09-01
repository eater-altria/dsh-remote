import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../state/providers.dart';

/// 一个设置命名空间的视图模型（settings.describe 行）。
class SettingsNamespace {
  SettingsNamespace({
    required this.ns,
    required this.schema,
    required this.value,
    this.base,
    this.user,
    required this.applies,
    required this.secrets,
    required this.revision,
  });

  final String ns;
  final Map<String, dynamic> schema;
  final dynamic value;
  final dynamic base;
  final dynamic user;
  final String applies; // live | restart
  final List<String> secrets; // 点分路径
  final int revision;

  factory SettingsNamespace.fromJson(Map<String, dynamic> json) => SettingsNamespace(
        ns: json['ns'] as String? ?? '',
        schema: (json['schema'] as Map?)?.cast<String, dynamic>() ?? const {},
        value: json['value'],
        base: json['base'],
        user: json['user'],
        applies: json['applies'] as String? ?? 'live',
        secrets: [
          for (final s in (json['secrets'] as List?) ?? const [])
            if (s is Map<String, dynamic>) ((s['path'] as List?)?.join('.')) ?? '',
        ],
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );
}

final settingsDescribeProvider = FutureProvider<List<SettingsNamespace>>((ref) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const [];
  final value = await connection.api.rpc('settings/describe');
  final map = (value as Map).cast<String, dynamic>();
  return (map['namespaces'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(SettingsNamespace.fromJson)
          .toList() ??
      const [];
});

/// 设置页：命名空间列表 → 详情编辑（基础类型字段直接改，复杂结构只读展示）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final namespaces = ref.watch(settingsDescribeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: namespaces.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('读取设置失败：\n$e', textAlign: TextAlign.center),
        )),
        data: (items) => ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            for (final ns in items)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.tune,
                        size: 16, color: Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                  title: Text(ns.ns, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _NsBadge(label: '${(ns.schema['properties'] as Map?)?.length ?? 0} 字段'),
                        if (ns.applies == 'restart') const _NsBadge(label: '重启生效', warn: true),
                        if (ns.secrets.isNotEmpty) _NsBadge(label: '${ns.secrets.length} 密钥'),
                      ],
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => _NamespacePage(namespace: ns)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NamespacePage extends ConsumerWidget {
  const _NamespacePage({required this.namespace});

  final SettingsNamespace namespace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final properties = (namespace.schema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    final current = namespace.value is Map<String, dynamic> ? namespace.value as Map<String, dynamic> : const {};
    return Scaffold(
      appBar: AppBar(title: Text(namespace.ns)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // design.md §4：同组字段收进一张卡片，分隔线连接
          Card(
            child: Column(
              children: [
                for (var i = 0; i < properties.entries.length; i++) ...[
                  () {
                    final entry = properties.entries.elementAt(i);
                    return _FieldTile(
                      ns: namespace.ns,
                      path: entry.key,
                      fieldSchema: (entry.value as Map?)?.cast<String, dynamic>() ?? const {},
                      value: current[entry.key],
                      isSecret: namespace.secrets
                          .any((s) => s == entry.key || s.startsWith('${entry.key}.')),
                      isUserOverridden: namespace.user is Map<String, dynamic> &&
                          (namespace.user as Map<String, dynamic>).containsKey(entry.key),
                      revision: namespace.revision,
                    );
                  }(),
                  if (i < properties.entries.length - 1)
                    Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: Theme.of(context).colorScheme.outlineVariant),
                ],
              ],
            ),
          ),
          if (properties.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('此命名空间没有可编辑字段',
                    style:
                        theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
        ],
      ),
    );
  }
}

class _FieldTile extends ConsumerWidget {
  const _FieldTile({
    required this.ns,
    required this.path,
    required this.fieldSchema,
    required this.value,
    required this.isSecret,
    required this.isUserOverridden,
    required this.revision,
  });

  final String ns;
  final String path;
  final Map<String, dynamic> fieldSchema;
  final dynamic value;
  final bool isSecret;
  final bool isUserOverridden;
  final int revision;

  String get _type => fieldSchema['type'] as String? ?? '';
  String? get _description => fieldSchema['description'] as String?;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = Row(
      children: [
        Flexible(child: Text(path, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (isUserOverridden)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.edit, size: 12, color: theme.colorScheme.primary),
          ),
        if (isSecret)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.key, size: 12, color: theme.colorScheme.secondary),
          ),
      ],
    );
    final subtitle = _description != null
        ? Text(_description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)
        : null;

    switch (_type) {
      case 'boolean':
        return SwitchListTile(
          title: title,
          subtitle: subtitle,
          value: value == true,
          onChanged: (v) => _write(context, ref, {path: v}),
        );
      case 'string':
        final enumValues = (fieldSchema['enum'] as List?)?.whereType<Object>().toList();
        return ListTile(
          title: title,
          subtitle: subtitle,
          trailing: Text(
            isSecret ? (value != null ? '••••••' : '未设置') : '${value ?? '—'}',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _editText(context, ref, enumValues: enumValues),
        );
      case 'number':
      case 'integer':
        return ListTile(
          title: title,
          subtitle: subtitle,
          trailing: Text('${value ?? '—'}', style: theme.textTheme.bodySmall),
          onTap: () => _editText(context, ref, numeric: true),
        );
      default:
        // 复杂结构（object/array/unknown）只读展示。
        return ListTile(
          title: title,
          subtitle: subtitle,
          trailing: Text(
            _preview(value),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            overflow: TextOverflow.ellipsis,
          ),
        );
    }
  }

  String _preview(dynamic v) {
    if (v == null) return '—';
    final s = v is String ? v : '$v';
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }

  Future<void> _editText(BuildContext context, WidgetRef ref,
      {bool numeric = false, List<Object?>? enumValues}) async {
    dynamic newValue;
    if (enumValues != null && enumValues.isNotEmpty) {
      newValue = await showModalBottomSheet<dynamic>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in enumValues)
                ListTile(
                  title: Text('$option'),
                  trailing: option == value ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, option),
                ),
            ],
          ),
        ),
      );
    } else {
      final controller = TextEditingController(text: isSecret ? '' : '${value ?? ''}');
      newValue = await showDialog<dynamic>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(path),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: isSecret,
            keyboardType: numeric ? TextInputType.number : TextInputType.text,
            decoration: InputDecoration(hintText: isSecret ? '输入新值（不会显示当前值）' : null),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final text = controller.text;
                if (numeric) {
                  Navigator.pop(context, num.tryParse(text));
                } else {
                  Navigator.pop(context, text);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
    }
    if (newValue == null) return;
    if (!context.mounted) return;
    await _write(context, ref, {path: newValue});
  }

  Future<void> _write(BuildContext context, WidgetRef ref, Map<String, dynamic> patch) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    try {
      await connection.api.rpc('settings.update', {
        'ns': ns,
        'patch': patch,
        'expectedRevision': revision,
      });
      ref.invalidate(settingsDescribeProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }
}

/// 命名空间属性徽标（design.md §4：chip 全圆角、outlineVariant 描边）。
class _NsBadge extends StatelessWidget {
  const _NsBadge({required this.label, this.warn = false});

  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: warn ? scheme.errorContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: warn ? scheme.error.withValues(alpha: 0.4) : scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: warn ? scheme.onErrorContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
