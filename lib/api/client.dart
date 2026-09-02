/// DSH host client (dsh ≥ 0.1.2-alpha 新协议): unary RPC over HTTP POST plus
/// the multiplexed WebSocket `/api/remote.mux`.
///
/// - Unary: `POST /api/<ns>/<method>` with a ClientRequest envelope whose
///   payload is `{args: {...}}`.
/// - Streams: one physical WS carries many logical streams; the client opens
///   each with an `{type:'open', streamId, endpoint, payload}` frame and
///   receives `{type:'item'|'end'|'error', streamId}` frames.
///
/// Readiness requires the mux socket open and the `$events` stream's `ready`
/// frame (it carries the clientId needed to answer waterfall requests).
/// If the socket ends, the connection generation fails and is rebuilt.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'wire.dart';

enum ConnStatus { disconnected, connecting, connected, reconnecting, failed }

/// Low-level unary RPC against one host base URL.
class DshApi {
  DshApi(this.baseUrl, {this.token});

  /// e.g. `http://192.168.1.5:3081` (no trailing slash).
  final String baseUrl;

  /// relay 访问令牌：relay 主机上 `~/.dsh-remote/config.json` 里的 token
  ///（首次启动 relay 时生成并打印）。上游 dsh 鉴权由 relay 自行处理。
  final String? token;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null && token!.isNotEmpty) 'x-relay-token': token!,
      };

  final http.Client _http = http.Client();

  Uri _apiUri(String endpoint) => Uri.parse('$baseUrl/api/$endpoint');

  /// POST `/api/<ns>/<method>` with a ClientRequest envelope.
  ///
  /// [args] is wrapped as `payload: {args: args}` per the typert Remote
  /// contract. Returns the business value (nullable for void methods).
  Future<dynamic> rpc(String endpoint, [Map<String, dynamic> args = const {}]) async {
    final rpcId = mintRpcId();
    final response = await _http
        .post(
          _apiUri(endpoint),
          headers: _headers,
          body: jsonEncode(clientRequest(rpcId, endpoint, {'args': args})),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw RpcException('internal', 'HTTP ${response.statusCode}: ${response.body}', const {});
    }
    return decodeServerResponse(utf8.decode(response.bodyBytes), rpcId);
  }

  void dispose() => _http.close();

  /// 让 relay 重启主机上的 dsh（`dsh web --no-open`）。relay 自铸的上游
  /// cookie 跨重启有效，重连后无需更新令牌。
  Future<Map<String, dynamic>> restartDsh() async {
    final response = await _http
        .post(Uri.parse('$baseUrl/__relay/restart-dsh'), headers: _headers)
        .timeout(const Duration(seconds: 120));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      final error = decoded is Map<String, dynamic> ? decoded['error'] : null;
      throw RpcException('internal', 'HTTP ${response.statusCode}: ${error ?? response.body}', const {});
    }
    return (decoded as Map).cast<String, dynamic>();
  }
}

/// One logical stream on the mux socket: items until end/error/cancel.
class RemoteStream {
  RemoteStream._(this.streamId, this._controller);

  final String streamId;
  final StreamController<dynamic> _controller;

  /// Item values (`{type:'item'}` frames' `value`).
  Stream<dynamic> get items => _controller.stream;
}

/// Multiplexed WebSocket carrier: logical streams over `/api/remote.mux`.
class RemoteMux {
  RemoteMux(this._channel);

  final WebSocketChannel _channel;
  final Map<String, StreamController<dynamic>> _streams = {};
  bool _closed = false;

  /// Fires exactly once when the physical socket ends (error or close).
  final Completer<void> _done = Completer<void>();
  Future<void> get done => _done.future;

  static RemoteMux connect(Uri uri, {Map<String, String>? headers}) {
    final channel = IOWebSocketChannel.connect(uri, headers: headers ?? const {});
    return RemoteMux(channel);
  }

  void listen() {
    _channel.stream.listen(
      _onFrame,
      onError: _onEnd,
      onDone: _onEnd,
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic>? frame;
    try {
      final json = jsonDecode(data);
      if (json is Map<String, dynamic>) frame = json;
    } catch (_) {
      return;
    }
    if (frame == null) return;
    final streamId = frame['streamId'] as String?;
    if (streamId == null) return;
    final sink = _streams[streamId];
    if (sink == null || sink.isClosed) return;
    switch (frame['type']) {
      case 'item':
        sink.add(frame['value']);
      case 'end':
        unawaited(sink.close());
        _streams.remove(streamId);
      case 'error':
        final error = frame['error'];
        sink.addError(
          error is Map<String, dynamic>
              ? RpcException.fromJson(error)
              : RpcException('gateway/internal', 'stream error', const {}),
        );
        unawaited(sink.close());
        _streams.remove(streamId);
    }
  }

  void _onEnd([Object? error]) {
    if (_closed) return;
    _closed = true;
    for (final sink in _streams.values) {
      if (!sink.isClosed) {
        sink.addError(error ?? StateError('mux socket closed'));
        unawaited(sink.close());
      }
    }
    _streams.clear();
    if (!_done.isCompleted) _done.complete();
  }

  /// Open one logical stream; items arrive on the returned stream.
  RemoteStream openStream(String endpoint, [Map<String, dynamic> args = const {}]) {
    if (_closed) throw StateError('mux socket closed');
    final streamId = mintRpcId();
    final controller = StreamController<dynamic>();
    _streams[streamId] = controller;
    _channel.sink.add(jsonEncode({
      'type': 'open',
      'streamId': streamId,
      'endpoint': endpoint,
      'payload': {'args': args},
    }));
    // 消费者取消（或连接代重建）时通知 host 关闭逻辑流。
    controller.onCancel = () {
      _streams.remove(streamId);
      if (!_closed) {
        _channel.sink.add(jsonEncode({'type': 'cancel', 'streamId': streamId}));
      }
    };
    return RemoteStream._(streamId, controller);
  }

  Future<void> close() async {
    _onEnd();
    try {
      await _channel.sink.close();
    } catch (_) {}
  }
}

/// One `$events` waterfall invocation (approval / user question) awaiting an
/// answer through `$events/result`.
class WaterfallRequest {
  WaterfallRequest({
    required this.event,
    required this.eventId,
    required this.agentId,
    required this.request,
  });

  final String event;
  final String eventId;
  final String agentId;
  final Map<String, dynamic> request;
}

/// One live connection to a DSH host: unary RPC + the remote.mux carrier with
/// automatic reconnect. The `$events` stream is parsed into typed frames.
class DshConnection extends ChangeNotifier {
  DshConnection(this.baseUrl, {this.token});

  final String baseUrl;
  final String? token;
  late final DshApi api = DshApi(baseUrl, token: token);

  ConnStatus status = ConnStatus.disconnected;
  String? lastError;

  /// `$events` ready 帧给出的本代 clientId（waterfall 应答必须用）。
  String? clientId;

  /// `$events` ready 帧给出的 host 事实（目前仅 home）。
  String? hostHome;

  /// `$events` emit 通知（api-session/*、settings/document-updated 等）。
  final _emitController = StreamController<Map<String, dynamic>>.broadcast();

  /// `$events` waterfall 请求（approval/request、user-questions/request）。
  final _waterfallController = StreamController<WaterfallRequest>.broadcast();

  /// `$events` cancel（host 撤回一个 pending waterfall）。
  final _cancelController = StreamController<String>.broadcast();

  /// relay 文件推送事件（{kind:'push', id, name, bytes, title, ts}）。
  final _pushController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get emits => _emitController.stream;
  Stream<WaterfallRequest> get waterfalls => _waterfallController.stream;
  Stream<String> get waterfallCancels => _cancelController.stream;
  Stream<Map<String, dynamic>> get pushEvents => _pushController.stream;

  RemoteMux? _mux;
  StreamSubscription? _eventsSub;
  WebSocketChannel? _pushSocket;
  StreamSubscription? _pushSub;
  Timer? _reconnectTimer;
  int _generation = 0;
  bool _disposed = false;

  Uri get _wsBase {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme);
  }

  Map<String, String> get _wsHeaders => {
        if (token != null && token!.isNotEmpty) 'x-relay-token': token!,
      };

  /// 在 mux 上开一条逻辑流（连接就绪后调用；重建后需重开）。
  Stream<dynamic> openStream(String endpoint, [Map<String, dynamic> args = const {}]) {
    final mux = _mux;
    if (mux == null) return Stream.error(StateError('未连接'));
    return mux.openStream(endpoint, args).items;
  }

  /// 跨连接代跟随一条逻辑流：每次（重）连接成功自动重开，断代期间不发射。
  /// snapshot/baseline 类流由消费者按「全量替换」语义处理新基线。
  Stream<dynamic> followStream(String endpoint, [Map<String, dynamic> args = const {}]) {
    StreamController<dynamic>? controller;
    StreamSubscription? inner;
    void reopen() {
      if (status != ConnStatus.connected || _disposed) return;
      inner?.cancel();
      inner = null;
      try {
        inner = openStream(endpoint, args).listen(
          (item) {
            if (controller != null && !controller.isClosed) controller.add(item);
          },
          onError: (_) {},
          onDone: () {},
        );
      } catch (_) {}
    }

    controller = StreamController<dynamic>(
      onListen: () {
        addListener(reopen);
        reopen();
      },
      onCancel: () {
        removeListener(reopen);
        inner?.cancel();
        inner = null;
      },
    );
    return controller.stream;
  }

  /// 应答一个 waterfall 请求（approval / question）。
  Future<void> answerWaterfall(WaterfallRequest req, Object? value) async {
    final id = clientId;
    if (id == null) throw StateError('连接未就绪（无 clientId）');
    await api.rpc(r'$events/result', {
      'clientId': id,
      'eventId': req.eventId,
      'outcome': {'kind': 'result', 'value': ?value},
    });
  }

  /// Open (or re-open) the connection generation.
  Future<void> connect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final generation = ++_generation;
    _setStatus(status == ConnStatus.disconnected ? ConnStatus.connecting : ConnStatus.reconnecting);
    try {
      await _tearDown();
      final mux = RemoteMux.connect(Uri.parse('$_wsBase/api/remote.mux'), headers: _wsHeaders);
      _mux = mux;
      mux.listen();
      _openOutboxSocket(generation);
      // 就绪 = $events 流的 ready 帧（首个 item）。
      final ready = Completer<void>();
      final events = mux.openStream(r'$events');
      _eventsSub = events.items.listen(
        (frame) {
          if (frame is! Map<String, dynamic>) return;
          switch (frame['type']) {
            case 'ready':
              clientId = frame['clientId'] as String?;
              hostHome = (frame['host'] as Map?)?['home'] as String?;
              if (!ready.isCompleted) ready.complete();
            case 'emit':
              if (!_emitController.isClosed) _emitController.add(frame);
            case 'waterfall':
              if (!_waterfallController.isClosed) {
                _waterfallController.add(WaterfallRequest(
                  event: frame['event'] as String? ?? '',
                  eventId: frame['eventId'] as String? ?? '',
                  agentId: frame['agentId'] as String? ?? '',
                  request: (frame['request'] as Map?)?.cast<String, dynamic>() ?? const {},
                ));
              }
            case 'cancel':
              final eventId = frame['eventId'] as String?;
              if (eventId != null && !_cancelController.isClosed) _cancelController.add(eventId);
          }
        },
        onError: (Object e) {
          if (!ready.isCompleted) ready.completeError(e);
          _onSocketEnded(generation);
        },
        onDone: () {
          if (!ready.isCompleted) ready.completeError(StateError('$events stream ended'));
          _onSocketEnded(generation);
        },
        cancelOnError: false,
      );
      unawaited(mux.done.then((_) => _onSocketEnded(generation)));
      await ready.future.timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation) return;
      lastError = null;
      _setStatus(ConnStatus.connected);
    } catch (e) {
      if (_disposed || generation != _generation) return;
      lastError = e.toString();
      _setStatus(ConnStatus.failed);
      _scheduleReconnect();
    }
  }

  /// relay 的 outbox 推送通道（/__relay/outbox，relay 私有，不过 host）。
  /// 失败静默降级，不参与就绪握手。
  void _openOutboxSocket(int generation) {
    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse('$_wsBase/__relay/outbox'),
        headers: _wsHeaders,
      );
      _pushSocket = channel;
      _pushSub = channel.stream.listen(
        (data) {
          if (data is String && !_pushController.isClosed) {
            try {
              final json = jsonDecode(data);
              if (json is Map<String, dynamic> && json['kind'] == 'push') {
                _pushController.add(json);
              }
            } catch (_) {}
          }
        },
        onDone: () => _onSocketEnded(generation),
        onError: (_) {}, // 通道不可用时静默
        cancelOnError: false,
      );
    } catch (_) {}
  }

  void _onSocketEnded(int generation) {
    if (_disposed || generation != _generation) return;
    if (status == ConnStatus.connected || status == ConnStatus.reconnecting) {
      _setStatus(ConnStatus.reconnecting);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), connect);
  }

  Future<void> _tearDown() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _pushSub?.cancel();
    _pushSub = null;
    try {
      await _pushSocket?.sink.close();
    } catch (_) {}
    _pushSocket = null;
    final mux = _mux;
    _mux = null;
    if (mux != null) await mux.close();
    clientId = null;
  }

  void _setStatus(ConnStatus next) {
    if (status == next) return;
    status = next;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _generation++;
    _reconnectTimer?.cancel();
    await _tearDown();
    _setStatus(ConnStatus.disconnected);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _tearDown();
    _emitController.close();
    _waterfallController.close();
    _cancelController.close();
    _pushController.close();
    api.dispose();
    super.dispose();
  }
}
