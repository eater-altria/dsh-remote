import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/client.dart';
import '../api/download_service.dart';
import '../state/providers.dart';
import 'theme.dart';

/// relay 推送收件箱（GET /__relay/outbox）。
class InboxPage extends ConsumerWidget {
  const InboxPage({super.key});

  Future<List<Map<String, dynamic>>> _fetch(DshConnection connection) async {
    final uri = Uri.parse('${connection.baseUrl}/__relay/outbox');
    final response = await http.get(uri, headers: {
      if (connection.token != null && connection.token!.isNotEmpty)
        'x-relay-token': connection.token!,
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw StateError('HTTP ${response.statusCode}');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return ((decoded as Map)['items'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const [];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('文件收件箱')),
      body: connection == null
          ? const Center(child: Text('未连接'))
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: _fetch(connection),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('读取失败：${snap.error}'));
                }
                final items = snap.data ?? const [];
                if (items.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NekoMascot(size: 72),
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
                        trailing: FilledButton.tonalIcon(
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
