import 'package:shared_preferences/shared_preferences.dart';

/// 推送去重：relay 在每次 WS 连接时都会补发最近几条推送，
/// 这里把已处理（弹窗展示过）的推送 id 持久化到 SharedPreferences，
/// App 重启 / 断线重连后不再重复弹窗。漏掉的文件仍可从「文件收件箱」手动下载。
class PushDedupe {
  PushDedupe({this.maxEntries = 100});

  static const _prefsKey = 'dsh.handledPushIds';

  /// 持久化 id 的上限，超出时裁剪最旧的。
  final int maxEntries;

  final Set<String> _seen = {};
  Future<void>? _loading;

  /// 返回 true 表示首次见到（应弹窗）；false 表示空 id 或已处理过。
  /// 首次见到时立即持久化，避免「弹窗展示了但 App 被杀」导致重启后重复弹。
  Future<bool> markIfNew(String id) async {
    if (id.isEmpty) return false;
    await (_loading ??= _load());
    if (!_seen.add(id)) return false;
    await _persist();
    return true;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _seen.addAll(prefs.getStringList(_prefsKey) ?? const []);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    var ids = _seen.toList(); // LinkedHashSet 保持插入顺序
    if (ids.length > maxEntries) {
      ids = ids.sublist(ids.length - maxEntries);
      _seen
        ..clear()
        ..addAll(ids);
    }
    await prefs.setStringList(_prefsKey, ids);
  }
}
