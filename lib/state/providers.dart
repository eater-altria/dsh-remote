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

/// 一台远程主机的连接配置。
class HostProfile {
  HostProfile({
    required this.id,
    required this.name,
    required this.url,
    this.dshToken = '',
  });

  final String id;
  final String name;
  final String url;
  final String dshToken; // dsh 启动令牌（dsh ≥0.1.2 的 launch URL `?token=`），空串 = 未设置

  HostProfile copyWith({String? name, String? url, String? dshToken}) => HostProfile(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        dshToken: dshToken ?? this.dshToken,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'dshToken': dshToken};

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        dshToken: json['dshToken'] as String? ?? '',
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
        )
      ];
      await prefs.remove(_kLegacyServerUrlKey);
      await prefs.remove('dsh.relayToken'); // 旧 relay 令牌键，一并清除
      await _persist();
      return;
    }
    state = const [];
  }

  Future<HostProfile> add({required String url, String name = '', String dshToken = ''}) async {
    final profile = HostProfile(
      id: mintRpcId(),
      name: name.isEmpty ? HostProfile.defaultName(url) : name,
      url: url,
      dshToken: dshToken,
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

/// 当前聊天页的完整作用域（ProviderScope override 注入，chatProvider 的 family 键）。
final currentChatScopeProvider =
    Provider<ChatScope>((ref) => throw UnimplementedError('未注入 ChatScope'));

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
  String? _dshToken;

  @override
  DshConnection? build() {
    final host = ref.watch(activeHostProvider);
    final url = host?.url;
    final dshToken = (host == null || host.dshToken.isEmpty) ? null : host.dshToken;
    // 仅名称等无关字段变化时保留现有连接，不切线。
    if (url != null && url == _url && dshToken == _dshToken && _connection != null) {
      return _connection;
    }
    _connection?.dispose();
    _url = url;
    _dshToken = dshToken;
    if (url == null) {
      _connection = null;
      return null;
    }
    final connection = DshConnection(url, dshToken: dshToken);
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
  StreamSubscription? _workspaceSub;
  StreamSubscription? _emitSub;
  void Function()? _statusListener;
  Timer? _sessionRefreshTimer;

  @override
  RosterState build() {
    final connection = ref.watch(connectionProvider);
    _workspaceSub?.cancel();
    _emitSub?.cancel();
    _sessionRefreshTimer?.cancel();
    if (connection == null) return RosterState();

    // 工作区 roster：workspace/follow 流（baseline 全量 + 增量）。
    _workspaceSub = connection.followStream('workspace/follow').listen(_onWorkspaceFrame);
    // 会话列表：session/list 为权威，api-session/* emit 触发防抖重取。
    _emitSub = connection.emits.listen((frame) {
      final event = frame['event'] as String? ?? '';
      if (event.startsWith('api-session/')) _scheduleSessionRefresh();
    });
    // (Re)fetch whenever the connection reaches `connected`.
    void listener() {
      if (connection.status == ConnStatus.connected) unawaited(refreshSessions());
    }

    _statusListener = listener;
    connection.addListener(listener);
    ref.onDispose(() {
      _workspaceSub?.cancel();
      _emitSub?.cancel();
      _sessionRefreshTimer?.cancel();
      if (_statusListener != null) connection.removeListener(_statusListener!);
    });

    if (connection.status == ConnStatus.connected) {
      // build 返回前 state 尚未初始化，同步调 refresh 会在读取 state 时抛
      // StateError 导致首刷丢失。推迟到微任务，等首帧状态落地后再拉取。
      unawaited(Future<void>.microtask(refreshSessions));
    }
    return RosterState(loading: true);
  }

  void _onWorkspaceFrame(dynamic frame) {
    if (frame is! Map<String, dynamic>) return;
    switch (frame['type']) {
      case 'baseline':
        final value = (frame['value'] as Map?)?.cast<String, dynamic>() ?? const {};
        state = state.copyWith(
          workspaces: (value['items'] as List?)
                  ?.whereType<Map<String, dynamic>>()
                  .map(WorkspaceView.fromJson)
                  .toList() ??
              const [],
          archivedSessionIds:
              (value['archivedSessionIds'] as List?)?.whereType<String>().toSet() ?? const {},
          loading: false,
          error: () => null,
        );
      case 'upsert':
        final workspace = (frame['workspace'] as Map?)?.cast<String, dynamic>();
        if (workspace == null) return;
        final view = WorkspaceView.fromJson(workspace);
        final items = [...state.workspaces];
        final idx = items.indexWhere((w) => w.workspaceId == view.workspaceId);
        if (idx >= 0) {
          items[idx] = view;
        } else {
          items.add(view);
        }
        state = state.copyWith(workspaces: items);
      case 'remove':
        final id = frame['workspaceId'] as String?;
        if (id == null) return;
        state = state.copyWith(
          workspaces: state.workspaces.where((w) => w.workspaceId != id).toList(),
        );
      case 'order':
        final order = (frame['workspaceIds'] as List?)?.whereType<String>().toList() ?? const [];
        final byId = {for (final w in state.workspaces) w.workspaceId: w};
        final ordered = [for (final id in order) if (byId.containsKey(id)) byId[id]!];
        // 未出现在 order 里的（新到还没来得及进 order 帧的）保持尾部。
        ordered.addAll(state.workspaces.where((w) => !order.contains(w.workspaceId)));
        state = state.copyWith(workspaces: ordered);
      case 'archived':
        state = state.copyWith(
          archivedSessionIds:
              (frame['archivedSessionIds'] as List?)?.whereType<String>().toSet() ?? const {},
        );
    }
  }

  void _scheduleSessionRefresh() {
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(refreshSessions());
    });
  }

  /// 全量重取会话列表（api-session/* emit 防抖触发 + 连接就绪触发）。
  Future<void> refreshSessions() async {
    final connection = ref.read(connectionProvider);
    if (connection == null || connection.status != ConnStatus.connected) return;
    try {
      // 注意：session/list 的 args 键是全 API 唯一的 `_request`。
      final value = await connection.api.rpc('session/list', {'_request': {}});
      final map = (value as Map).cast<String, dynamic>();
      state = state.copyWith(
        sessions: (map['items'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(SessionSummary.fromJson)
                .toList() ??
            const [],
        loading: false,
        error: () => null,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: () => e.toString());
    }
  }

  /// 兼容旧调用点：全量刷新（会话 + 等下一帧工作区 baseline）。
  Future<void> refresh() => refreshSessions();
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

/// 聊天页作用域：子代理路由需要 parentSessionId + mode 才能组装 follow 地址。
class ChatScope {
  const ChatScope({required this.sessionId, this.parentSessionId, this.subagentMode});

  final String sessionId;
  final String? parentSessionId;
  final String? subagentMode;

  @override
  bool operator ==(Object other) =>
      other is ChatScope &&
      other.sessionId == sessionId &&
      other.parentSessionId == parentSessionId &&
      other.subagentMode == subagentMode;

  @override
  int get hashCode => Object.hash(sessionId, parentSessionId, subagentMode);
}

class ChatNotifier extends FamilyNotifier<ChatState, ChatScope> {
  StreamSubscription? _followSub;
  StreamSubscription? _controlSub;
  StreamSubscription? _waterfallSub;
  StreamSubscription? _cancelSub;
  int _historyGeneration = 0;
  final List<Map<String, dynamic>> _pendingChunks = [];
  Timer? _chunkFlushTimer;

  /// 最近一次 follow snapshot 的 cursor（session/page 翻页的 throughSeq 锚点）。
  int _cursor = 0;

  String get _sessionId => arg.sessionId;

  /// session/follow 的 address 参数（主会话 or 子代理）。
  Map<String, dynamic> _address() {
    final parent = arg.parentSessionId;
    if (parent != null) {
      return {
        'kind': 'subagent',
        'parentSessionId': parent,
        'childSessionId': _sessionId,
        'mode': arg.subagentMode ?? 'continuable',
      };
    }
    return {'kind': 'session', 'sessionId': _sessionId};
  }

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
  ChatState build(ChatScope arg) {
    final connection = ref.watch(connectionProvider);
    _followSub?.cancel();
    _controlSub?.cancel();
    _waterfallSub?.cancel();
    _cancelSub?.cancel();
    final chat = ChatState(sessionId: arg.sessionId, fold: ChatFold());
    if (connection == null) {
      return chat.copyWith(loadingHistory: false, historyError: () => '未连接');
    }

    // 会话日志流：snapshot = 历史尾页 + cursor 基线，之后直播事件。
    // 跨重连自动重开（followStream），新 snapshot 全量重建尾部窗口。
    _followSub = connection.followStream('session/follow', {
      'request': {'address': _address(), 'maxMessages': 60},
    }).listen(_onFollowFrame, onError: (_) {});
    // 控制流：全 Host 的 queue/jobs/projection 广播，按 sessionId 过滤。
    _controlSub = connection.followStream('session/control').listen(_onControlFrame, onError: (_) {});
    // 审批 / 提问（$events waterfall，agentId 即会话 id）。
    _waterfallSub = connection.waterfalls.listen(_onWaterfall);
    _cancelSub = connection.waterfallCancels.listen(_onWaterfallCancel);

    ref.onDispose(() {
      _followSub?.cancel();
      _controlSub?.cancel();
      _waterfallSub?.cancel();
      _cancelSub?.cancel();
      _chunkFlushTimer?.cancel();
    });
    return chat;
  }

  // -------------------------------------------------------------------------
  // session/follow 帧
  // -------------------------------------------------------------------------

  Future<void> _onFollowFrame(dynamic frame) async {
    if (frame is! Map<String, dynamic>) return;
    switch (frame['type']) {
      case 'snapshot':
        await _applySnapshot(frame);
      case 'event':
        final event = frame['event'];
        if (event is! Map<String, dynamic>) return;
        if (event['type'] == 'assistant/chunk') {
          // 流式 chunk 批量合并：40ms 内到达的 chunk 一次应用、一次重建，
          // 避免逐 token setState 导致的 UI 线程风暴。
          _pendingChunks.add(event);
          _chunkFlushTimer ??= Timer(const Duration(milliseconds: 40), _flushChunks);
        } else {
          // 非 chunk 事件先冲刷一次积压 chunk，保证应用顺序正确。
          _flushChunks();
          final fold = state.fold ?? ChatFold();
          fold.applyEvent(event, live: true);
          state = state.copyWith(fold: fold);
        }
    }
  }

  /// snapshot 帧 = 尾部历史窗口 + cursor + 投影基线：全量替换当前折叠。
  Future<void> _applySnapshot(Map<String, dynamic> frame) async {
    final generation = ++_historyGeneration;
    final sw = Stopwatch()..start();
    try {
      final result = await compute(
        parseAndFoldHistory,
        HistoryFoldTask(body: jsonEncode(frame), isTail: true),
      );
      if (generation != _historyGeneration) return;
      debugPrint('[perf] snapshot decode+fold: ${sw.elapsedMilliseconds}ms, ${result.fold.items.length} items');
      _cursor = (frame['cursor'] as num?)?.toInt() ?? 0;
      GoalView? goal = state.goal;
      if (result.projections.isNotEmpty || result.goalValue != null) {
        final g = GoalView.fromProjection(result.projections['goal']);
        goal = g.exists ? g : null;
      }
      _pendingChunks.clear();
      state = state.copyWith(
        fold: result.fold,
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

  // -------------------------------------------------------------------------
  // session/control 帧（queue / jobs / projection）
  // -------------------------------------------------------------------------

  void _onControlFrame(dynamic frame) {
    if (frame is! Map<String, dynamic>) return;
    final fold = state.fold ?? ChatFold();
    switch (frame['type']) {
      case 'baseline':
        final value = (frame['value'] as Map?)?.cast<String, dynamic>() ?? const {};
        final queues = (value['queues'] as Map?)?.cast<String, dynamic>() ?? const {};
        final jobs = (value['jobs'] as Map?)?.cast<String, dynamic>() ?? const {};
        final projections = (value['projections'] as Map?)?.cast<String, dynamic>() ?? const {};
        _applyQueue(queues[_sessionId]);
        state = state.copyWith(jobs: activeJobsFromSnapshot(jobs[_sessionId]));
        final block = projections[_sessionId];
        if (block is Map<String, dynamic>) _applyProjectionValues(block['values']);
      case 'queue':
        if (frame['sessionId'] != _sessionId) return;
        _applyQueue(frame['items']);
      case 'jobs':
        if (frame['sessionId'] != _sessionId) return;
        state = state.copyWith(jobs: activeJobsFromSnapshot(frame['jobs']));
      case 'projection':
        if (frame['sessionId'] != _sessionId) return;
        final key = frame['key'] as String?;
        if (key == null) return;
        if (key == 'title') {
          final value = frame['value'];
          if (value is String && value.isNotEmpty) {
            fold.title = value;
            state = state.copyWith(fold: fold);
          }
        } else if (key == 'goal') {
          final g = GoalView.fromProjection(frame['value']);
          final projections = Map<String, dynamic>.from(state.projections);
          projections['goal'] = frame['value'];
          state = state.copyWith(goal: () => g.exists ? g : null, projections: projections);
        } else {
          final projections = Map<String, dynamic>.from(state.projections);
          projections[key] = frame['value'];
          state = state.copyWith(projections: projections);
        }
    }
  }

  void _applyProjectionValues(dynamic raw) {
    if (raw is! Map<String, dynamic>) return;
    final projections = Map<String, dynamic>.from(raw);
    GoalView? goal = state.goal;
    if (projections.containsKey('goal')) {
      final g = GoalView.fromProjection(projections['goal']);
      goal = g.exists ? g : null;
    }
    final fold = state.fold ?? ChatFold();
    final t = projections['title'];
    if (t is String && t.isNotEmpty) fold.title = t;
    state = state.copyWith(
      fold: fold,
      projections: projections,
      goal: () => goal,
    );
  }

  void _applyQueue(dynamic raw) {
    final items = (raw as List?)?.whereType<Map<String, dynamic>>().map((item) {
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
  }

  // -------------------------------------------------------------------------
  // $events waterfall（approval / question）
  // -------------------------------------------------------------------------

  void _onWaterfall(WaterfallRequest req) {
    if (req.agentId != _sessionId) return;
    switch (req.event) {
      case 'approval/request':
        state = state.copyWith(
          pendingApproval: () => PendingApproval(
            eventId: req.eventId,
            sessionId: _sessionId,
            toolName: req.request['toolName'] as String? ?? '',
            callId: req.request['callId'] as String?,
            reason: req.request['reason'] as String?,
          ),
        );
      case 'user-questions/request':
        final questions = (req.request['questions'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(QuestionItem.fromJson)
                .toList() ??
            const [];
        state = state.copyWith(
          pendingQuestion: () =>
              PendingQuestion(eventId: req.eventId, sessionId: _sessionId, questions: questions),
        );
    }
  }

  void _onWaterfallCancel(String eventId) {
    final pendingQ = state.pendingQuestion;
    final pendingA = state.pendingApproval;
    if (pendingQ?.eventId == eventId) {
      state = state.copyWith(pendingQuestion: () => null);
    }
    if (pendingA?.eventId == eventId) {
      state = state.copyWith(pendingApproval: () => null);
    }
  }

  // -------------------------------------------------------------------------
  // 历史翻页（session/page）
  // -------------------------------------------------------------------------

  /// Page older history (prepended). No-op while the tail is still loading.
  Future<void> loadOlder() async {
    if (state.loadingHistory || !state.hasMore) return;
    final firstSeq = state.items.isEmpty ? null : state.items.first.seq;
    if (firstSeq == null || firstSeq <= 0) return;
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final generation = ++_historyGeneration;
    try {
      final value = await connection.api.rpc('session/page', {
        'request': {
          'address': _address(),
          'throughSeq': _cursor,
          'beforeSeq': firstSeq,
          'maxMessages': 60,
        },
      });
      if (generation != _historyGeneration) return;
      final result = await compute(
        parseAndFoldHistory,
        HistoryFoldTask(body: jsonEncode(value), isTail: false),
      );
      if (generation != _historyGeneration) return;
      // 更早的页面前插到现有列表。
      final current = state.fold ?? ChatFold();
      current.items = [...result.fold.items, ...current.items];
      state = state.copyWith(fold: current, hasMore: result.hasMore, historyError: () => null);
    } catch (e) {
      if (generation != _historyGeneration) return;
      state = state.copyWith(historyError: () => e.toString());
    }
  }

  /// 兼容旧调用点（旧版重连补拉；新版 follow 流自动处理）。
  Future<void> refreshHistory() async {}

  // -------------------------------------------------------------------------
  // 动作（unary RPC）
  // -------------------------------------------------------------------------

  /// goals.* —— CAS 动词；读侧走 `goal` 投影（control 流会带新值回来）。
  Future<void> goalAction(String verb, {String? objective, int? maxGoalRounds}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final goal = state.goal;
    final request = <String, dynamic>{
      'objective': ?objective,
      'maxGoalRounds': ?maxGoalRounds,
    };
    if (verb == 'create') {
      await connection.api.rpc('goals/create', {'agentId': _sessionId, 'request': request});
      return;
    }
    if (goal == null || !goal.exists) return;
    final ref0 = {'id': goal.id, 'revision': goal.revision};
    if (verb == 'edit') {
      await connection.api.rpc('goals/edit', {'agentId': _sessionId, 'ref': ref0, 'request': request});
    } else {
      // pause | resume | complete | clear
      await connection.api.rpc('goals/$verb', {'agentId': _sessionId, 'ref': ref0});
    }
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
      await connection.api.rpc('session/prompt', {
        'request': {
          'requestId': mintRpcId(),
          'sessionId': _sessionId,
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
        },
      });
    } finally {
      state = state.copyWith(sending: false);
    }
  }

  /// Cancel the active turn (pending queue is preserved).
  Future<void> cancel() async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    await connection.api.rpc('session/cancel', {
      'request': {'sessionId': _sessionId},
    });
  }

  /// 可续聊子代理：向其发消息（subagents/prompt）。
  Future<void> sendSubagentPrompt(String parentSessionId, String text) async {
    final connection = ref.read(connectionProvider);
    if (connection == null || text.trim().isEmpty) return;
    state = state.copyWith(sending: true);
    try {
      await connection.api.rpc('subagents/prompt', {
        'request': {
          'requestId': mintRpcId(),
          'parentSessionId': parentSessionId,
          'childSessionId': _sessionId,
          'mode': 'continuable',
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      });
    } finally {
      state = state.copyWith(sending: false);
    }
  }

  /// 打断可续聊子代理（subagents/interruptByParent）。
  Future<void> interruptSubagent(String parentSessionId) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    await connection.api.rpc('subagents/interruptByParent', {
      'parentSessionId': parentSessionId,
      'childSessionId': _sessionId,
      'mode': 'continuable',
    });
  }

  /// 编辑/移除队列中的待发消息（session/updateQueue）。
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
    await connection.api.rpc('session/updateQueue', {
      'request': {'sessionId': _sessionId, 'itemId': itemId, 'action': action},
    });
  }

  /// Answer the pending question prompt.
  Future<void> answerQuestion(List<Map<String, dynamic>> answers) async {
    final connection = ref.read(connectionProvider);
    final pending = state.pendingQuestion;
    if (connection == null || pending == null) return;
    await connection.answerWaterfall(
      WaterfallRequest(
        event: 'user-questions/request',
        eventId: pending.eventId,
        agentId: _sessionId,
        request: const {},
      ),
      {'answers': answers},
    );
    state = state.copyWith(pendingQuestion: () => null);
  }

  /// Answer the pending approval prompt.
  Future<void> answerApproval(bool approved) async {
    final connection = ref.read(connectionProvider);
    final pending = state.pendingApproval;
    if (connection == null || pending == null) return;
    await connection.answerWaterfall(
      WaterfallRequest(
        event: 'approval/request',
        eventId: pending.eventId,
        agentId: _sessionId,
        request: const {},
      ),
      approved ? 'allowed-once' : 'rejected',
    );
    state = state.copyWith(pendingApproval: () => null);
  }
}

final chatProvider = NotifierProvider.family<ChatNotifier, ChatState, ChatScope>(ChatNotifier.new);

// ---------------------------------------------------------------------------
// 模型目录（per session）
// ---------------------------------------------------------------------------

class SessionModels {
  SessionModels({required this.current, required this.routable, required this.groups});

  final ModelSelection current;
  final bool routable;
  final List<ModelProviderGroup> groups;
}

/// `session/modelCatalog`：默认选择 + provider 分组目录。selectModel 后失效重取。
final sessionModelsProvider = FutureProvider.family<SessionModels, String>((ref, sessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) {
    throw StateError('未连接');
  }
  final value = await connection.api.rpc('session/modelCatalog');
  final map = (value as Map).cast<String, dynamic>();
  return SessionModels(
    current: ModelSelection.fromJson((map['default'] as Map?)?.cast<String, dynamic>() ?? const {}),
    routable: (map['routableProviders'] as List?)?.isNotEmpty ?? false,
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
  await connection.api.rpc('session/selectModel', {
    'request': {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      'reasoningEffort': ?reasoningEffort,
    },
  });
  ref.invalidate(sessionModelsProvider(sessionId));
}

// ---------------------------------------------------------------------------
// 技能目录（per session，供 `/` 自动补全）
// ---------------------------------------------------------------------------

final skillListProvider = FutureProvider.family<List<SkillEntry>, String>((ref, sessionId) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) return const [];
  final value = await connection.api.rpc('skills/list', {
    'request': {'sessionId': sessionId},
  });
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
  final value = await connection.api.rpc('session/rename', {
    'request': {'sessionId': sessionId, 'title': title},
  });
  final normalized = ((value as Map)['title']) as String?;
  ref.invalidate(rosterProvider);
  return normalized;
}

/// 从某个事件锚点分叉会话，返回新 sessionId。
Future<String?> forkSession(WidgetRef ref, String sessionId, {int? atSeq}) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return null;
  final value = await connection.api.rpc('session/fork', {
    'request': {'sessionId': sessionId, 'atSeq': ?atSeq},
  });
  ref.invalidate(rosterProvider);
  return ((value as Map)['sessionId']) as String?;
}

/// 归档会话（新协议无 unarchive；roster 由 workspace/follow 的 archived 帧刷新）。
Future<void> archiveSession(WidgetRef ref, String sessionId) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.rpc('workspace/archiveSession', {
    'request': {'sessionId': sessionId},
  });
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
  final value = await connection.api.rpc('session/search', {
    'request': {'query': query.trim()},
  });
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
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      return DirectoryListing.fromJson(
          (jsonDecode(utf8.decode(response.bodyBytes)) as Map).cast<String, dynamic>());
    }
  } catch (_) {
    // relay 不支持 listDir（旧版）→ 回退 host 端 browse 能力
  }
  // directoryPicker/list 的 args 直传（非 request 包裹）；本机部署若为
  // native-only 会抛 directory-picker/unavailable，由调用方降级手动输入。
  final value = await connection.api.rpc('directoryPicker/list', {'path': ?path});
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
  final value = await connection.api.rpc('subagents/list', {'parentSessionId': parentSessionId});
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
  final value = await connection.api.rpc('messageFeedback/list', {
    'request': {'sessionId': sessionId},
  });
  // 双层结果：result.value = {ok:true, value:{items}} | {ok:false, error}
  final outer = (value as Map).cast<String, dynamic>();
  if (outer['ok'] != true) return const {};
  final map = (outer['value'] as Map?)?.cast<String, dynamic>() ?? const {};
  final items = (map['items'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
  return {for (final item in items) '${item['messageId']}': '${item['rating']}'};
});

/// 提交/更新反馈（ifVersion: null = 无条件写）。
Future<void> putFeedback(WidgetRef ref, String sessionId, String messageId, String rating,
    {String? note}) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.rpc('messageFeedback/put', {
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
  final value = await connection.api.rpc('commands/list', {'agentId': sessionId});
  return (value as List?)?.whereType<Map<String, dynamic>>().map(CommandEntry.fromJson).toList() ?? const [];
});

/// 执行一条斜杠命令（host 侧执行；结果经 command/run 帧回来）。
/// images 是 descriptor 的必填字段（图片附件），命令场景恒为空数组。
Future<void> executeCommand(WidgetRef ref, String sessionId, String line) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.rpc('commands/execute', {
    'agentId': sessionId,
    'line': line,
    'images': const [],
  });
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
  final value = await connection.api.rpc('agentPresets/list');
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
