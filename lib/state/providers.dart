/// Riverpod state: server profile, connection lifecycle, session roster, and
/// per-session chat controllers.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/fold.dart';
import '../api/models.dart';
import '../api/wire.dart';

// ---------------------------------------------------------------------------
// Server profile (persisted)
// ---------------------------------------------------------------------------

const _kServerUrlKey = 'dsh.serverUrl';

class ServerProfileNotifier extends Notifier<String?> {
  @override
  String? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kServerUrlKey);
  }

  Future<void> setUrl(String url) async {
    final normalized = normalizeBaseUrl(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerUrlKey, normalized);
    state = normalized;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kServerUrlKey);
    state = null;
  }
}

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

final serverProfileProvider = NotifierProvider<ServerProfileNotifier, String?>(ServerProfileNotifier.new);

/// Factory for one-shot low-level API handles against an arbitrary base URL
/// (used by the setup probe before a profile exists).
final apiFactoryProvider = Provider<DshApi Function(String)>((ref) {
  return (String baseUrl) => DshApi(baseUrl);
});

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

class ConnectionNotifier extends Notifier<DshConnection?> {
  @override
  DshConnection? build() {
    final url = ref.watch(serverProfileProvider);
    if (url == null || url.isEmpty) {
      return null;
    }
    final connection = DshConnection(url);
    ref.onDispose(() => connection.dispose());
    unawaited(connection.connect());
    return connection;
  }

  Future<void> reconnect() async => state?.connect();

  Future<void> disconnect() async {
    await state?.disconnect();
    await ref.read(serverProfileProvider.notifier).clear();
  }
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
      );
}

class ChatNotifier extends FamilyNotifier<ChatState, String> {
  StreamSubscription? _muxSub;
  void Function()? _statusListener;
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

  Future<void> _loadHistory({int? beforeSeq}) async {
    final connection = ref.read(connectionProvider);
    if (connection == null) return;
    final generation = ++_historyGeneration;
    try {
      final value = await connection.api.rpc('session.history', {
        'sessionId': arg,
        'beforeSeq': ?beforeSeq,
        'maxMessages': 200,
      });
      if (generation != _historyGeneration) return;
      final map = (value as Map).cast<String, dynamic>();
      final events = (map['events'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
      // Tail page (re)loads rebuild the fold from scratch; older pages prepend.
      final fold = beforeSeq == null ? ChatFold() : (state.fold ?? ChatFold());
      if (beforeSeq != null) {
        final older = ChatFold();
        for (final entry in events) {
          final event = entry['event'];
          if (event is Map<String, dynamic>) {
            older.applyEvent(event, view: (entry['view'] as Map?)?.cast<String, dynamic>());
          }
        }
        fold.items = [...older.items, ...fold.items];
      } else {
        for (final entry in events) {
          final event = entry['event'];
          if (event is Map<String, dynamic>) {
            fold.applyEvent(event, view: (entry['view'] as Map?)?.cast<String, dynamic>());
          }
        }
      }
      // Title also rides the projections block on the tail page.
      final projections = map['projections'];
      GoalView? goal = state.goal;
      if (projections is Map<String, dynamic>) {
        final values = projections['values'];
        if (values is Map<String, dynamic>) {
          final t = values['title'];
          if (t is String && t.isNotEmpty) fold.title = t;
          if (values.containsKey('goal')) {
            final g = GoalView.fromProjection(values['goal']);
            goal = g.exists ? g : null;
          }
        }
      }
      state = state.copyWith(
        fold: fold,
        loadingHistory: false,
        hasMore: map['hasMore'] == true,
        historyError: () => null,
        // 尾部页加载完成 → 通知 UI 跳到底部。
        scrollSignal: beforeSeq == null ? state.scrollSignal + 1 : null,
        goal: beforeSeq == null ? () => goal : null,
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
        // 重连后的新基线：直接与本地状态对齐一次。
        if (lastSeq != null && state.fold != null && !_resyncing) {
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
      case 'session/projection':
        if (payload['key'] == 'title') {
          final value = payload['value'];
          if (value is String && value.isNotEmpty) {
            fold.title = value;
            state = state.copyWith(fold: fold);
          }
        } else if (payload['key'] == 'goal') {
          final g = GoalView.fromProjection(payload['value']);
          state = state.copyWith(goal: () => g.exists ? g : null);
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

  /// Send a user prompt (queued behind an active turn).
  Future<void> sendPrompt(String text) async {
    final connection = ref.read(connectionProvider);
    if (connection == null || text.trim().isEmpty) return;
    state = state.copyWith(sending: true);
    try {
      await connection.api.rpc('session.prompt', {
        'sessionId': arg,
        'mode': 'queue',
        'content': [
          {'type': 'text', 'text': text},
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
Future<void> selectModel(WidgetRef ref, String sessionId, String provider, String model) async {
  final connection = ref.read(connectionProvider);
  if (connection == null) return;
  await connection.api.rpc('session.selectModel', {
    'sessionId': sessionId,
    'provider': provider,
    'model': model,
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
// 目录浏览（host.listDirectory，供 workspace 创建选择目录）
// ---------------------------------------------------------------------------

final directoryListingProvider =
    FutureProvider.family<DirectoryListing, String?>((ref, path) async {
  final connection = ref.watch(connectionProvider);
  if (connection == null || connection.status != ConnStatus.connected) {
    throw StateError('未连接');
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
