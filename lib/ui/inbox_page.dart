import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/client.dart';
import '../api/download_service.dart';
import '../state/providers.dart';
import 'theme.dart';

/// relay 推送收件箱（GET /__relay/outbox），支持删除暂存文件。
class InboxPage extends ConsumerStatefulWidget {
  const InboxPage({super.key});

  @override
  ConsumerState<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends ConsumerState<InboxPage> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final connection = ref.read(connectionProvider);
    setState(() => _future = connection == null ? null : _fetch(connection));
  }

  Map<String, String> get _headers {
    final token = ref.read(connectionProvider)?.token;
    return {
      if (token != null && token.isNotEmpty) 'x-relay-token': token,
    };
  }

  Future<List<Map<String, dynamic>>> _fetch(DshConnection connection) async {
    final uri = Uri.parse('${connection.baseUrl}/__relay/outbox');
    final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw StateError('HTTP ${response.statusCode}');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return ((decoded as Map)['items'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const [];
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final name = item['name'] as String? ?? '文件';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除文件'),
        content: const Text('主机上暂存的文件会被移除；已下载到「下载」目录的副本不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final id = item['id'] as String? ?? '';
    try {
      final uri = Uri.parse('${connection.baseUrl}/__relay/files/$id');
      final response = await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已删除 $name')));
        _reload();
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：HTTP ${response.statusCode}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('文件收件箱')),
      body: connection == null
          ? const Center(child: Text('未连接'))
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('读取失败：${snap.error}'),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _reload, child: const Text('重试')),
                      ],
                    ),
                  );
                }
                final items = snap.data ?? const [];
                if (items.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NekoHero(size: 156),
                        SizedBox(height: 12),
                        Text('收件箱是空的'),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(top: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final name = item['name'] as String? ?? '文件';
                    final bytes = (item['bytes'] as num?)?.toInt() ?? 0;
                    final ts = DateTime.fromMillisecondsSinceEpoch(
                        (item['ts'] as num?)?.toInt() ?? 0);
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.insert_drive_file_outlined,
                              size: 16, color: theme.colorScheme.onSecondaryContainer),
                        ),
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${_formatBytes(bytes)} · ${ts.month}/${ts.day} '
                          '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () async {
                                final ok = await launchFileDownload(
                                  baseUrl: connection.baseUrl,
                                  token: connection.token,
                                  fileId: item['id'] as String? ?? '',
                                  fileName: name,
                                  title: item['title'] as String?,
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(ok ? '已开始下载，进度见通知栏' : '下载失败')),
                                  );
                                }
                              },
                              icon: const Icon(Icons.download, size: 16),
                              label: const Text('下载'),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline,
                                  size: 20, color: theme.colorScheme.error),
                              tooltip: '删除',
                              onPressed: () => _delete(item),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
