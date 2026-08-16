/// Riverpod state: server profile, connection lifecycle, session roster, and
/// per-session chat controllers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/fold.dart';
import '../api/models.dart';
import '../api/wire.dart';

// ---------------------------------------------------------------------------
// Host profiles（多主机配置，持久化）
// ---------------------------------------------------------------------------

const _kThemeModeKey = 'dsh.themeMode'; // system | light | dark
const _kHostProfilesKey = 'dsh.hostProfiles';
const _kActiveHostKey = 'dsh.activeHostId';
// 单主机时代的遗留键，仅用于一次性迁移。
const _kLegacyServerUrlKey = 'dsh.serverUrl';
const _kLegacyRelayTokenKey = 'dsh.relayToken';

/// 一台远程主机的连接配置。
class HostProfile {
  HostProfile({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
  });

  final String id;
  final String name;
  final String url;
  final String token; // relay 访问令牌，空串 = 未设置

  HostProfile copyWith({String? name, String? url, String? token}) => HostProfile(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        token: token ?? this.token,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'token': token};

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        token: json['token'] as String? ?? '',
      );

  /// 默认显示名：URL 的 host[:port] 部分。
  static String defaultName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
}

/// 主机列表。状态为 null 表示尚未从磁盘恢复（首帧加载中）。
class HostsNotifier extends Notifier<List<HostProfile>?> {
  Future<void>? _loading;

  /// 首次磁盘恢复完成的 Future（首帧等待 / 测试用）。
  Future<void> get ready => _loading ?? Future.value();

  @override
  List<HostProfile>? build() {
    _loading = _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHostProfilesKey);
    if (raw != null) {
      state = [
        for (final item in (jsonDecode(raw) as List? ?? const []))
          if (item is Map<String, dynamic>) HostProfile.fromJson(item)
      ];
      return;
    }
    // 一次性迁移：单主机配置 → 第一台主机。
    final legacyUrl = prefs.getString(_kLegacyServerUrlKey);
    if (legacyUrl != null && legacyUrl.isNotEmpty) {
      state = [
        HostProfile(
          id: mintRpcId(),
          name: HostProfile.defaultName(legacyUrl),
          url: legacyUrl,
          token: prefs.getString(_kLegacyRelayTokenKey) ?? '',
        )
      ];
      await prefs.remove(_kLegacyServerUrlKey);
      await prefs.remove(_kLegacyRelayTokenKey);
      await _persist();
      return;
    }
    state = const [];
  }

  Future<HostProfile> add({required String url, String name = '', String token = ''}) async {
    final profile = HostProfile(
      id: mintRpcId(),
      name: name.isEmpty ? HostProfile.defaultName(url) : name,
      url: url,
      token: token,
    );
    state = [...?state, profile];
    await _persist();
    return profile;
  }

  Future<void> update(HostProfile profile) async {
    state = [
      for (final p in state ?? const <HostProfile>[]) p.id == profile.id ? profile : p
    ];
    await _persist();
  }

  Future<void> remove(String id) async {
    state = [for (final p in state ?? const <HostProfile>[]) if (p.id != id) p];
    await _persist();
    if (ref.read(activeHostIdProvider) == id) {
      await ref.read(activeHostIdProvider.notifier).clear();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kHostProfilesKey,
      jsonEncode([for (final p in state ?? const <HostProfile>[]) p.toJson()]),
    );
  }
}

final hostsProvider = NotifierProvider<HostsNotifier, List<HostProfile>?>(HostsNotifier.new);

/// 当前选中的主机 id（持久化）。null = 未选择，停留在主机列表。
class ActiveHostNotifier extends Notifier<String?> {
  Future<void>? _loading;

  /// 首次磁盘恢复完成的 Future（测试用）。
  Future<void> get ready => _loading ?? Future.value();

  @override
  String? build() {
    _loading = _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kActiveHostKey);
  }

  Future<void> select(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveHostKey, id);
    state = id;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kActiveHostKey);
    state = null;
  }
}

final activeHostIdProvider = NotifierProvider<ActiveHostNotifier, String?>(ActiveHostNotifier.new);

/// 当前选中主机的完整配置（未选择 / 列表未恢复 / id 失效时为 null）。
final activeHostProvider = Provider<HostProfile?>((ref) {
  final id = ref.watch(activeHostIdProvider);
  final hosts = ref.watch(hostsProvider);
  if (id == null || hosts == null) return null;
  for (final host in hosts) {
    if (host.id == id) return host;
  }
  return null;
});

/// Normalize user input into `http://host:port` form.
String normalizeBaseUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  if (!url.contains('://')) url = 'http://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// 当前聊天页的 sessionId（ProviderScope override 注入，供深层图片/反馈组件读取）。
final currentSessionIdProvider = Provider<String>((ref) => throw UnimplementedError('未注入 sessionId'));

/// Factory for one-shot low-level API handles against an arbitrary base URL
/// (used by the setup probe before a profile exists).
final apiFactoryProvider = Provider<DshApi Function(String)>((ref) {
  return (String baseUrl) => DshApi(baseUrl);
});

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

class ConnectionNotifier extends Notifier<DshConnection?> {
  DshConnection? _connection;
  String? _url;
  String? _token;

  @override
  DshConnection? build() {
    final host = ref.watch(activeHostProvider);
    final url = host?.url;
    final token = (host == null || host.token.isEmpty) ? null : host.token;
    // 仅名称等无关字段变化时保留现有连接，不切线。
    if (url != null && url == _url && token == _token && _connection != null) {
      return _connection;
    }
    _connection?.dispose();
    _url = url;
    _token = token;
    if (url == null) {
      _connection = null;
      return null;
    }
    final connection = DshConnection(url, token: token);
    _connection = connection;
    unawaited(connection.connect());
    return connection;
  }

  Future<void> reconnect() async => state?.connect();
}

final connectionProvider = NotifierProvider<ConnectionNotifier, DshConnection?>(ConnectionNotifier.new);

// ---------------------------------------------------------------------------
// Roster (workspaces + sessions)
// ---------------------------------------------------------------------------

class RosterState {
  RosterState({
    this.workspaces = const [],
    this.sessions = const [],
    this.archivedSessionIds = const {},
    this.loading = false,
    this.error,
  });

  final List<WorkspaceView> workspaces;
  final List<SessionSummary> sessions;
  final Set<String> archivedSessionIds;
  final bool loading;
  final String? error;

  RosterState copyWith({
    List<WorkspaceView>? workspaces,
    List<SessionSummary>? sessions,
    Set<String>? archivedSessionIds,
    bool? loading,
    String? Function()? error,
  }) =>
      RosterState(
        workspaces: workspaces ?? this.workspaces,
        sessions: sessions ?? this.sessions,
        archivedSessionIds: archivedSessionIds ?? this.archivedSessionIds,
        loading: loading ?? this.loading,
        error: error != null ? error() : this.error,
      );
}

class RosterNotifier extends Notifier<RosterState> {
  StreamSubscription? _hostSub;
  void Function()? _statusListener;

  @override
  RosterState build() {
    final connection = ref.watch(connectionProvider);
    _hostSub?.cancel();
    if (connection == null) return RosterState();

    _hostSub = connection.hostFrames.listen((frame) {
      final type = frame.payload['type'];
      // Any roster-affecting frame triggers a refetch (the list is the
      // reconnect authority; increments arrive in either order).
      if (type is String && type.startsWith('host/') && type != 'host/agent-error' && type != 'host/remote-event') {
        unawaited(refresh());
      }
    });
    // (Re)fetch whenever the connection reaches `connected`.
    void listener() {
      if (connection.status == ConnStatus.connected) unawaited(refresh());
    }

    _statusListener = listener;
    connection.addListener(listener);
    ref.onDispose(() {
      _hostSub?.cancel();
      if (_statusListener != null) connection.removeListener(_statusListener!);
    });

    if (connection.status == ConnStatus.connected) unawaited(refresh());
    return RosterState(loading: true);
  }

  Future<void> refresh() async {
    final connection = ref.read(connectionProvider);
    if (connection == null || connection.status != ConnStatus.connected) return;
    state = state.copyWith(loading: true);
    try {
      final results = await Future.wait([
        connection.api.rpc('workspace.list'),
        connection.api.rpc('session.list'),
      ]);
      final wsValue = (results[0] as Map).cast<String, dynamic>();
      final ssValue = (results[1] as Map).cast<String, dynamic>();
      state = RosterState(
        workspaces: (wsValue['items'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(WorkspaceView.fromJson)
                .toList() ??
            const [],
        sessions: (ssValue['items'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(SessionSummary.fromJson)
                .toList() ??
            const [],
        archivedSessionIds:
            (wsValue['archivedSessionIds'] as List?)?.whereType<String>().toSet() ?? const {},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: () => e.toString());
    }
  }
}

final rosterProvider = NotifierProvider<RosterNotifier, RosterState>(RosterNotifier.new);

// ---------------------------------------------------------------------------
// Chat (per session)
// ---------------------------------------------------------------------------

class ChatState {
  ChatState({
    required this.sessionId,
    this.fold,
    this.loadingHistory = true,
    this.historyError,
    this.hasMore = false,
    this.pendingQuestion,
    this.pendingApproval,
    this.queue = const [],
    this.sending = false,
    this.scrollSignal = 0,
    this.goal,
    this.projections = const {},
    this.jobs = const [],
  });

  final String sessionId;
  final ChatFold? fold;
  final bool loadingHistory;
  final String? historyError;
  final bool hasMore;
  final PendingQuestion? pendingQuestion;
  final PendingApproval? pendingApproval;
  final List<QueueItem> queue;
  final bool sending;

  /// 单调递增信号：尾部历史页加载完成时 +1，UI 据此跳到底部。
  final int scrollSignal;

  /// `goal` 投影：进行中的目标（无目标时为 null）。
  final GoalView? goal;

  /// 全部会话投影的原始值（todos / plan / permissions / imageLimits …）。
  final Map<String, dynamic> projections;

  /// 后台任务快照（session/jobs 帧；[{id, kind, label, status, startedAt}]）。
  final List<Map<String, dynamic>> jobs;

  List<ChatItem> get items => fold?.items ?? const [];
  bool get running => fold?.running ?? false;
  String? get title => fold?.title;

  ChatState copyWith({
    ChatFold? fold,
    bool? loadingHistory,
    String? Function()? historyError,
    bool? hasMore,
    PendingQuestion? Function()? pendingQuestion,
    PendingApproval? Function()? pendingApproval,
    List<QueueItem>? queue,
    bool? sending,
    int? scrollSignal,
    GoalView? Function()? goal,
    Map<String, dynamic>? projections,
    List<Map<String, dynamic>>? jobs,
  }) =>
      ChatState(
        sessionId: sessionId,
        fold: fold ?? this.fold,
        loadingHistory: loadingHistory ?? this.loadingHistory,
        historyError: historyError != null ? historyError() : this.historyError,
        hasMore: hasMore ?? this.hasMore,
        pendingQuestion: pendingQuestion != null ? pendingQuestion() : this.pendingQuestion,
        pendingApproval: pendingApproval != null ? pendingApproval() : this.pendingApproval,
        queue: queue ?? this.queue,
        sending: sending ?? this.sending,
        scrollSignal: scrollSignal ?? this.scrollSignal,
        goal: goal != null ? goal() : this.goal,
        projections: projections ?? this.projections,
        jobs: jobs ?? this.jobs,
      );
}

/// session/jobs 快照过滤：任务条只展示活动任务
/// （host 快照会保留 completed/killed/failed 的已终结任务）。
List<Map<String, dynamic>> activeJobsFromSnapshot(Object? raw) {
  const terminal = {'completed', 'killed', 'failed'};
  return (raw as List?)
          ?.whereType<Map<String, dynamic>>()
          .where((job) => !terminal.contains(job['status']))
          .toList() ??
      const [];
}

class ChatNotifier extends FamilyNotifier<ChatState, String> {
  StreamSubscription? _muxSub;  void Function()? _statusListener;
  int _historyGeneration = 0;
  final List<Map<String, dynamic>> _pendingChunks = [];
  Timer? _chunkFlushTimer;

  /// mux 流的 lastSeq 跟踪：session/subscribed 建立基线，session/event 逐个校验，
  /// 出现缺口（seq 跳跃）说明重连期间丢了帧 → 补拉历史尾部页对齐。
  int _lastSeq = -1;
  bool _resyncing = false;

  void _flushChunks() {
    _chunkFlushTimer?.cancel();
    _chunkFlushTimer = null;
    if (_pendingChunks.isEmpty) return;
    final fold = state.fold ?? ChatFold();
    for (final event in _pendingChunks) {
      fold.applyEvent(event, live: true);
    }
    _pendingChunks.clear();
    state = state.copyWith(fold: fold);
  }

  @override
  ChatState build(String arg) {
    final connection = ref.watch(connectionProvider);
    _muxSub?.cancel();
    final chat = ChatState(sessionId: arg, fold: ChatFold());
    if (connection == null) {
      return chat.copyWith(loadingHistory: false, historyError: () => '未连接');
    }

    _muxSub = connection.muxFrames.listen(_onMuxFrame);
    // (Re)load history whenever the connection (re)establishes — a reconnect
    // generation replays missed frames only for still-live sessions.
    void listener() {
      if (connection.status == ConnStatus.connected && !state.loadingHistory) {
        unawaited(_loadHistory());
      }
    }

    _statusListener = listener;
    connection.addListener(listener);
    ref.onDispose(() {
      _muxSub?.cancel();
      _chunkFlushTimer?.cancel();
      if (_statusListener != null) connection.removeListener(_statusListener!);
    });
    if (connection.status == ConnStatus.connected) {
      unawaited(_loadHistory());
    }
    return chat;
  }

  /// 拉取原始历史页：优先走 relay 的 slim 端点（剥掉 chunk/replayState，
  /// 9MB→1.5MB），不支持时回退标准 session.history。
  Future<String> _fetchHistoryRaw({int? beforeSeq}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) throw StateError('未连接');
    final payload = {
      'sessionId': arg,
      'beforeSeq': ?beforeSeq,
      'maxMessages': 60,
    };
    try {
      final response = await http
          .post(
            Uri.parse('${connection.baseUrl}/__relay/history.slim'),
            headers: {
              'content-type': 'application/json',
              if (connection.token != null && connection.token!.isNotEmpty)
                'x-relay-token': connection.token!,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic> && decoded.containsKey('events')) {
          return utf8.decode(response.bodyBytes);
        }
      }
    } catch (_) {
      // relay 不支持 slim → 回退标准路径
    }
    final value = await connection.api.rpc('session.history', payload);
    return jsonEncode(value);
  }

  Future<void> _loadHistory({int? beforeSeq}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final generation = ++_historyGeneration;
    final sw = Stopwatch()..start();
    try {
      final raw = await _fetchHistoryRaw(beforeSeq: beforeSeq);
      if (generation != _historyGeneration) return;
      debugPrint('[perf] history fetch: ${sw.elapsedMilliseconds}ms, ${raw.length} bytes');
      // 解码 + 折叠放后台 isolate：数 MB 的 JSON 同步解析会冻结 UI 线程。
      final result = await compute(
        parseAndFoldHistory,
        HistoryFoldTask(body: raw, isTail: beforeSeq == null),
      );
      if (generation != _historyGeneration) return;
      debugPrint('[perf] isolate decode+fold: ${sw.elapsedMilliseconds}ms total, ${result.fold.items.length} items');
      final fold = result.fold;
      if (beforeSeq != null) {
        // 更早的页面前插到现有列表。
        final current = state.fold ?? ChatFold();
        current.items = [...fold.items, ...current.items];
        state = state.copyWith(fold: current, hasMore: result.hasMore, historyError: () => null);
        return;
      }
      GoalView? goal = state.goal;
      if (result.projections.isNotEmpty || result.goalValue != null) {
        final g = GoalView.fromProjection(result.projections['goal']);
        goal = g.exists ? g : null;
      }
      state = state.copyWith(
        fold: fold,
        loadingHistory: false,
        hasMore: result.hasMore,
        historyError: () => null,
        scrollSignal: state.scrollSignal + 1,
        goal: () => goal,
        projections: result.projections.isNotEmpty ? result.projections : null,
      );
    } catch (e) {
      if (generation != _historyGeneration) return;
      state = state.copyWith(loadingHistory: false, historyError: () => e.toString());
    }
  }

  /// Page older history (prepended). No-op while the tail is still loading.
  Future<void> loadOlder() async {
    if (state.loadingHistory || !state.hasMore) return;
    final firstSeq = state.items.isEmpty ? null : state.items.first.seq;
    if (firstSeq == null || firstSeq <= 0) return;
    await _loadHistory(beforeSeq: firstSeq);
  }

  void _onMuxFrame(ServerRequestFrame frame) {
    final payload = frame.payload;
    final type = payload['type'] as String? ?? '';
    if (payload['sessionId'] != arg) return;
    final fold = state.fold ?? ChatFold();

    switch (type) {
      case 'session/subscribed':
        final lastSeq = (payload['lastSeq'] as num?)?.toInt();
        if (lastSeq != null) _lastSeq = lastSeq;
        // 重连后的新基线：与本地状态对齐一次；初始加载进行中时跳过（那次拉取
        // 已经覆盖基线之前的全部事件）。
        if (lastSeq != null && state.fold != null && !_resyncing && !state.loadingHistory) {
          _resyncing = true;
          unawaited(_loadHistory().whenComplete(() => _resyncing = false));
        }
      case 'session/event':
        final event = payload['event'];
        if (event is! Map<String, dynamic>) return;
        final seq = (event['seq'] as num?)?.toInt();
        if (seq != null) {
          if (_lastSeq >= 0 && seq > _lastSeq + 1 && !_resyncing) {
            // 缺口：丢帧了，补拉历史对齐后再继续。
            _resyncing = true;
            _pendingChunks.clear();
            unawaited(_loadHistory().whenComplete(() {
              _resyncing = false;
              _lastSeq = seq;
            }));
            return;
          }
          if (seq > _lastSeq) _lastSeq = seq;
        }
        if (event['type'] == 'assistant/chunk') {
          // 流式 chunk 批量合并：40ms 内到达的 chunk 一次应用、一次重建，
          // 避免逐 token setState 导致的 UI 线程风暴。
          _pendingChunks.add(event);
          _chunkFlushTimer ??= Timer(const Duration(milliseconds: 40), _flushChunks);
        } else {
          // 非 chunk 事件先冲刷一次积压 chunk，保证应用顺序正确。
          _flushChunks();
          fold.applyEvent(event, live: true, view: (payload['view'] as Map?)?.cast<String, dynamic>());
          state = state.copyWith(fold: fold);
        }
      case 'question/requested':
        final questions = (payload['questions'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(QuestionItem.fromJson)
                .toList() ??
            const [];
        state = state.copyWith(
          pendingQuestion: () => PendingQuestion(rpcId: frame.rpcId, sessionId: arg, questions: questions),
        );
      case 'question/resolved':
        state = state.copyWith(pendingQuestion: () => null);
      case 'approval/requested':
        state = state.copyWith(
          pendingApproval: () => PendingApproval(
            rpcId: frame.rpcId,
            sessionId: arg,
            approvalId: payload['approvalId'] as String? ?? '',
            toolName: payload['toolName'] as String? ?? '',
            callId: payload['callId'] as String?,
            reason: payload['reason'] as String?,
          ),
        );
      case 'approval/resolved':
        state = state.copyWith(pendingApproval: () => null);
      case 'session/queue':
        final items = (payload['items'] as List?)?.whereType<Map<String, dynamic>>().map((item) {
              final message = item['message'];
              var text = '';
              if (message is Map<String, dynamic>) {
                final content = message['content'];
                if (content is List) {
                  text = content
                      .whereType<Map<String, dynamic>>()
                      .where((b) => b['type'] == 'text')
                      .map((b) => b['text'] as String? ?? '')
                      .join('\n');
                }
              }
              return QueueItem(
                id: item['id'] as String? ?? '',
                placement: item['placement'] as String? ?? 'queued',
                text: text,
              );
            }).toList() ??
            const [];
        state = state.copyWith(queue: items);
      case 'session/jobs':
        final jobs = (payload['jobs'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
        state = state.copyWith(jobs: jobs);
      case 'session/projection':
        if (payload['key'] == 'title') {
          final value = payload['value'];
          if (value is String && value.isNotEmpty) {
            fold.title = value;
            state = state.copyWith(fold: fold);
          }
        } else if (payload['key'] == 'goal') {
          final g = GoalView.fromProjection(payload['value']);
          final projections = Map<String, dynamic>.from(state.projections);
          projections['goal'] = payload['value'];
          state = state.copyWith(goal: () => g.exists ? g : null, projections: projections);
        } else {
          final key = payload['key'] as String?;
          if (key != null) {
            final projections = Map<String, dynamic>.from(state.projections);
            projections[key] = payload['value'];
            state = state.copyWith(projections: projections);
          }
        }
      default:
        break;
    }
  }

  /// goal.* —— CAS 动词；读侧走 `goal` 投影（goal/change 帧会带新值回来）。
  Future<void> goalAction(String verb, {String? objective, int? maxGoalRounds}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final goal = state.goal;
    final payload = <String, dynamic>{'sessionId': arg};
    if (verb != 'create') {
      if (goal == null || !goal.exists) return;
      payload['ref'] = {'id': goal.id, 'revision': goal.revision};
    }
    if (objective != null) payload['objective'] = objective;
    if (maxGoalRounds != null) payload['maxGoalRounds'] = maxGoalRounds;
    await connection.api.rpc('goal.$verb', payload);
  }

  /// Send a user prompt, with optional images.
  ///
  /// [mode]：`queue`（默认，排队等当前回合）或 `steer`（插入正在进行的回合）。
  /// [images] 是 `{bytes: Uint8List, mediaType: String, name: String}` 列表，
  /// 按 promptContentPart 的 image 分支 base64 编码上送；超出 imageLimits
  /// 投影限额时本地直接拒绝（免去一次失败的网络往返）。
  Future<void> sendPrompt(String text,
      {List<Map<String, Object>> images = const [], String mode = 'queue'}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null || (text.trim().isEmpty && images.isEmpty)) return;
    final limits = state.projections['imageLimits'];
    if (limits is Map<String, dynamic> && images.isNotEmpty) {
      final maxCount = (limits['maxImagesPerMessage'] as num?)?.toInt();
      final maxBytes = (limits['maxImageBytes'] as num?)?.toInt();
      final maxTotal = (limits['maxMessageImageBytes'] as num?)?.toInt();
      if (maxCount != null && images.length > maxCount) {
        throw RpcException('attachment-error', '一条消息最多 $maxCount 张图片', const {});
      }
      final total = images.fold<int>(0, (sum, i) => sum + (i['bytes'] as Uint8List).length);
      for (final image in images) {
        final size = (image['bytes'] as Uint8List).length;
        if (maxBytes != null && size > maxBytes) {
          throw RpcException('attachment-error', '单张图片超出大小限制', const {});
        }
      }
      if (maxTotal != null && total > maxTotal) {
        throw RpcException('attachment-error', '图片总大小超出限制', const {});
      }
    }
    state = state.copyWith(sending: true);
    try {
      await connection.api.rpc('session.prompt', {
        'sessionId': arg,
        'mode': mode,
        'content': [
          if (text.trim().isNotEmpty) {'type': 'text', 'text': text},
          for (final image in images)
            {
              'type': 'image',
              'mediaType': image['mediaType'],
              'data': base64Encode(image['bytes'] as Uint8List),
              'name': image['name'],
            },
        ],
      });
    } finally {
      state = state.copyWith(sending: false);
    }
  }

  /// Cancel the active turn (pending queue is preserved).
  Future<void> cancel() async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    await connection.api.rpc('session.cancel', {'sessionId': arg});
  }

  /// 可续聊子代理：向其发消息（subagent.prompt）。
  Future<void> sendSubagentPrompt(String parentSessionId, String text) async {
    final connection = ref.read(connectionProvider);
    if (connection == null || text.trim().isEmpty) return;
    state = state.copyWith(sending: true);
    try {
      await connection.api.rpc('subagent.prompt', {
        'parentSessionId': parentSessionId,
        'childSessionId': arg,
        'mode': 'continuable',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
    } finally {
      state = state.copyWith(sending: false);
    }
  }

  /// 打断可续聊子代理（subagent.interrupt）。
  Future<void> interruptSubagent(String parentSessionId) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    await connection.api.rpc('subagent.interrupt', {
      'parentSessionId': parentSessionId,
      'childSessionId': arg,
      'mode': 'continuable',
    });
  }

  /// 编辑/移除队列中的待发消息（session.updateQueue）。
  Future<void> updateQueueItem(String itemId, {String? editText, bool remove = false, bool steer = false}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final action = remove
        ? {'kind': 'remove'}
        : steer
            ? {'kind': 'steer'}
            : {
                'kind': 'edit',
                'content': [
                  {'type': 'text', 'text': editText ?? ''},
                ],
              };
    await connection.api.rpc('session.updateQueue', {
      'sessionId': arg,
      'itemId': itemId,
      'action': action,
    });
  }

  /// Answer the pending question prompt.
  Future<void> answerQuestion(List<Map<String, dynamic>> answers) async {
    final connection = ref.read(connectionProvider);
    final pending = state.pendingQuestion;
    if (connection == null || pending == null) return;
    await connection.api.respond(pending.rpcId, {
      'sessionId': arg,
      'answer': {'answers': answers},
    });
    state = state.copyWith(pendingQuestion: () => null);
  }

  /// Answer the pending approval prompt.
  Future<void> answerApproval(bool approved) async {
    final connection = ref.read(connectionProvider);
    final pending = state.pendingApproval;
    if (connection == null || pending == null) return;
    await connection.api.respond(pending.rpcId, {
      'sessionId': arg,
      'approvalId': pending.approvalId,
      'outcome': approved ? 'allowed-once' : 'rejected',
    });
    state = state.copyWith(pendingApproval: () => null);
  }
}

final chatProvider = NotifierProvider.family<ChatNotifier, ChatState, String>(ChatNotifier.new);

// ---------------------------------------------------------------------------
// 模型目录（per session）
// ---------------------------------------------------------------------------

class SessionModels {
  SessionModels({required this.current, required this.routable, required this.groups});

  final ModelSelection current;
  final bool routable;
  final List<ModelProviderGroup> groups;
}

/// `session.models`：当前选择 + provider 分组目录。selectModel 后失效重取。
final sessionModelsProvider = FutureProvider.family<SessionModels, String>((ref, sessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) {
    throw StateError('未连接');
  }
  final value = await connection.api.rpc('session.models', {'sessionId': sessionId});
  final map = (value as Map).cast<String, dynamic>();
  return SessionModels(
    current: ModelSelection.fromJson((map['current'] as Map?)?.cast<String, dynamic>() ?? const {}),
    routable: map['routable'] as bool? ?? false,
    groups:
        (map['groups'] as List?)?.whereType<Map<String, dynamic>>().map(ModelProviderGroup.fromJson).toList() ??
            const [],
  );
});

/// 切换当前会话的模型选择（host 会把它存为部署默认值）。
/// [reasoningEffort]：思考强度 id（该模型支持 reasoning 时可选）。
Future<void> selectModel(WidgetRef ref, String sessionId, String provider, String model,
    {String? reasoningEffort}) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.rpc('session.selectModel', {
    'sessionId': sessionId,
    'provider': provider,
    'model': model,
    'reasoningEffort': ?reasoningEffort,
  });
  ref.invalidate(sessionModelsProvider(sessionId));
}

// ---------------------------------------------------------------------------
// 技能目录（per session，供 `/` 自动补全）
// ---------------------------------------------------------------------------

final skillListProvider = FutureProvider.family<List<SkillEntry>, String>((ref, sessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const [];
  final value = await connection.api.rpc('skill.list', {'sessionId': sessionId});
  final map = (value as Map).cast<String, dynamic>();
  return (map['skills'] as List?)?.whereType<Map<String, dynamic>>().map(SkillEntry.fromJson).toList() ??
      const [];
});

// ---------------------------------------------------------------------------
// 会话操作（rename / fork / archive）
// ---------------------------------------------------------------------------

/// 重命名会话，返回宿主规范化后的标题。
Future<String?> renameSession(WidgetRef ref, String sessionId, String title) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return null;
  final value = await connection.api.rpc('session.rename', {'sessionId': sessionId, 'title': title});
  final normalized = ((value as Map)['title']) as String?;
  ref.invalidate(rosterProvider);
  return normalized;
}

/// 从某个事件锚点分叉会话，返回新 sessionId。
Future<String?> forkSession(WidgetRef ref, String sessionId, {int? atSeq}) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return null;
  final value = await connection
      .api
      .rpc('session.fork', {'sessionId': sessionId, 'atSeq': ?atSeq});
  ref.invalidate(rosterProvider);
  return ((value as Map)['sessionId']) as String?;
}

/// 归档/取消归档会话（host 应答完整集合，本地直接刷新 roster）。
Future<void> archiveSession(WidgetRef ref, String sessionId, {required bool archived}) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.rpc('workspace.archiveSession', {'sessionId': sessionId, 'archived': archived});
  ref.invalidate(rosterProvider);
}

// ---------------------------------------------------------------------------
// 会话搜索
// ---------------------------------------------------------------------------

final sessionSearchProvider =
    FutureProvider.family<List<SessionSearchItem>, String>((ref, query) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected || query.trim().isEmpty) {
    return const [];
  }
  final value = await connection.api.rpc('session.search', {'query': query.trim()});
  final map = (value as Map).cast<String, dynamic>();
  return (map['items'] as List?)?.whereType<Map<String, dynamic>>().map(SessionSearchItem.fromJson).toList() ??
      const [];
});

// ---------------------------------------------------------------------------
// 目录浏览（relay /__relay/listDir 优先，host.listDirectory 兜底）
// ---------------------------------------------------------------------------

final directoryListingProvider =
    FutureProvider.family<DirectoryListing, String?>((ref, path) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) {
    throw StateError('未连接');
  }
  // relay 跑在主机上，自己列目录——不占用 host 的 directory-picker seam
  //（native 选择器是 Web GUI 本地新建工作区用的）。
  try {
    final uri = Uri.parse('${connection.baseUrl}/__relay/listDir')
        .replace(queryParameters: {'path': ?path});
    final response = await http.get(uri, headers: {
      if (connection.token != null && connection.token!.isNotEmpty)
        'x-relay-token': connection.token!,
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      return DirectoryListing.fromJson(
          (jsonDecode(utf8.decode(response.bodyBytes)) as Map).cast<String, dynamic>());
    }
  } catch (_) {
    // relay 不支持 listDir（旧版）→ 回退 host 端 browse 能力
  }
  final value = await connection.api.rpc('host.listDirectory', {'path': ?path});
  return DirectoryListing.fromJson((value as Map).cast<String, dynamic>());
});

// ---------------------------------------------------------------------------
// 子代理列表（subagent.list）
// ---------------------------------------------------------------------------

class SubagentEntry {
  SubagentEntry({
    required this.id,
    required this.mode,
    required this.activity,
    required this.hasChildren,
    this.label,
    this.diagnosticReason,
  });

  final String id;
  final String mode; // one-shot | continuable | ''(diagnostic)
  final String activity; // running | inactive
  final bool hasChildren;
  final String? label;

  /// 诊断行的原因（corrupt/unsupported/unavailable），正常条目为 null。
  final String? diagnosticReason;

  factory SubagentEntry.fromJson(Map<String, dynamic> json) => SubagentEntry(
        id: json['id'] as String? ?? '',
        mode: json['mode'] as String? ?? '',
        activity: json['activity'] as String? ?? '',
        hasChildren: json['hasChildren'] as bool? ?? false,
        label: json['label'] as String?,
        diagnosticReason: json['reason'] as String?,
      );
}

final subagentListProvider =
    FutureProvider.family<List<SubagentEntry>, String>((ref, parentSessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const [];
  final value = await connection.api.rpc('subagent.list', {'parentSessionId': parentSessionId});
  final map = (value as Map).cast<String, dynamic>();
  return (map['entries'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(SubagentEntry.fromJson)
          .toList() ??
      const [];
});

// ---------------------------------------------------------------------------
// 消息反馈（messageFeedback Remote 端点）
// ---------------------------------------------------------------------------

/// messageId → rating ("positive" | "negative")。
final messageFeedbackProvider =
    FutureProvider.family<Map<String, String>, String>((ref, sessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const {};
  final value = await connection.api.remote('messageFeedback/list', {
    'request': {'sessionId': sessionId},
  });
  final map = (value as Map).cast<String, dynamic>();
  final items = (map['items'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
  return {for (final item in items) '${item['messageId']}': '${item['rating']}'};
});

/// 提交/更新反馈（ifVersion: null = 无条件写）。
Future<void> putFeedback(WidgetRef ref, String sessionId, String messageId, String rating,
    {String? note}) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.remote('messageFeedback/put', {
    'request': {
      'sessionId': sessionId,
      'messageId': messageId,
      'rating': rating,
      'note': ?note,
      'ifVersion': null,
    },
  });
  ref.invalidate(messageFeedbackProvider(sessionId));
}

// ---------------------------------------------------------------------------
// 斜杠命令目录（commands/list Remote 端点）
// ---------------------------------------------------------------------------

class CommandEntry {
  CommandEntry({required this.name, required this.description, this.hint});

  final String name;
  final String description;
  final String? hint;

  factory CommandEntry.fromJson(Map<String, dynamic> json) => CommandEntry(
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        hint: (json['input'] as Map?)?['hint'] as String?,
      );
}

final commandListProvider = FutureProvider.family<List<CommandEntry>, String>((ref, sessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const [];
  final value = await connection.api.remote('commands/list', {'agentId': sessionId});
  return (value as List?)?.whereType<Map<String, dynamic>>().map(CommandEntry.fromJson).toList() ?? const [];
});

/// 执行一条斜杠命令（host 侧执行；结果经 command/run 帧回来）。
Future<void> executeCommand(WidgetRef ref, String sessionId, String line) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.remote('commands/execute', {'agentId': sessionId, 'line': line});
}

// ---------------------------------------------------------------------------
// Agent preset 目录（agentPreset.list）
// ---------------------------------------------------------------------------

class AgentPresetEntry {
  AgentPresetEntry({
    required this.id,
    required this.isDefault,
    required this.trust,
    this.name,
    this.description,
    this.brokenReason,
  });

  final String id;
  final bool isDefault;
  final String trust; // system | user
  final String? name;
  final String? description;
  final String? brokenReason;

  factory AgentPresetEntry.fromJson(Map<String, dynamic> json) => AgentPresetEntry(
        id: json['id'] as String? ?? '',
        isDefault: json['isDefault'] as bool? ?? false,
        trust: json['trust'] as String? ?? '',
        name: json['name'] as String?,
        description: json['description'] as String?,
        brokenReason: json['broken'] as String?,
      );
}

final agentPresetListProvider = FutureProvider<List<AgentPresetEntry>>((ref) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const [];
  final value = await connection.api.rpc('agentPreset.list');
  final map = (value as Map).cast<String, dynamic>();
  final rows = map['presets'];
  return (rows as List?)?.whereType<Map<String, dynamic>>().map(AgentPresetEntry.fromJson).toList() ?? const [];
});

// ---------------------------------------------------------------------------
// 主题模式（跟随系统 / 浅色 / 深色）
// ---------------------------------------------------------------------------

class ThemeModeNotifier extends Notifier<String> {
  @override
  String build() {
    _load();
    return 'system';
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kThemeModeKey) ?? 'system';
  }

  Future<void> setMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, mode);
    state = mode;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, String>(ThemeModeNotifier.new);
