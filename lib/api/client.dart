/// DSH host client: unary RPC over HTTP POST plus the two WebSocket downlinks
/// (`/api/events.mux` and `/api/events.host`).
///
/// Readiness requires both sockets open and a successful `host.describe`.
/// If either socket ends, the connection generation fails and is rebuilt.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'wire.dart';

enum ConnStatus { disconnected, connecting, connected, reconnecting, failed }

/// Low-level unary RPC against one host base URL.
class DshApi {
  DshApi(this.baseUrl, {this.token});

  /// e.g. `http://192.168.1.5:3080` (no trailing slash).
  final String baseUrl;

  /// relay 访问令牌（DSH_RELAY_TOKEN 启用时必需）。
  final String? token;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null && token!.isNotEmpty) 'x-relay-token': token!,
      };

  final http.Client _http = http.Client();

  Uri _apiUri(String path) => Uri.parse('$baseUrl/api/$path');

  /// POST `/api/<method>` with a ClientRequest envelope.
  ///
  /// Returns the business value (nullable for void methods).
  Future<dynamic> rpc(String method, [Map<String, dynamic> payload = const {}]) async {
    final rpcId = mintRpcId();
    final response = await _http
        .post(
          _apiUri(method),
          headers: _headers,
          body: jsonEncode(clientRequest(rpcId, method, payload)),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw RpcException('internal', 'HTTP ${response.statusCode}: ${response.body}', const {});
    }
    return decodeServerResponse(utf8.decode(response.bodyBytes), rpcId);
  }

  /// POST `/api/respond` answering a pending ServerRequest (question or
  /// approval). Returns true when the host accepted the answer.
  Future<bool> respond(String rpcId, Object? value) async {
    final response = await _http
        .post(
          _apiUri('respond'),
          headers: _headers,
          body: jsonEncode(clientResponseOk(rpcId, value)),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) return false;
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      return json is Map<String, dynamic> && json['accepted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Typert Remote endpoint: POST `/api/<namespace>/<method>` with named args.
  Future<dynamic> remote(String endpoint, [Map<String, dynamic> args = const {}]) =>
      rpc(endpoint, {'args': args});

  void dispose() => _http.close();
}

/// One live connection to a DSH host: unary RPC + mux/host downlinks with
/// automatic reconnect. Frames are exposed as broadcast streams of raw
/// payload maps (`MuxFrame` / `HostFrame`).
class DshConnection extends ChangeNotifier {
  DshConnection(this.baseUrl, {this.token});

  final String baseUrl;
  final String? token;
  late final DshApi api = DshApi(baseUrl, token: token);

  ConnStatus status = ConnStatus.disconnected;
  HostDescription? host;
  String? lastError;

  final _muxController = StreamController<ServerRequestFrame>.broadcast();
  final _hostController = StreamController<ServerRequestFrame>.broadcast();
  final _pushController = StreamController<Map<String, dynamic>>.broadcast();

  /// Mux downlink frames (session/event, approvals, questions, queue, jobs…).
  Stream<ServerRequestFrame> get muxFrames => _muxController.stream;

  /// Host downlink frames (session/workspace roster changes…).
  Stream<ServerRequestFrame> get hostFrames => _hostController.stream;

  /// relay 文件推送事件（{kind:'push', id, name, bytes, title, ts}）。
  Stream<Map<String, dynamic>> get pushEvents => _pushController.stream;

  WebSocketChannel? _muxSocket;
  WebSocketChannel? _hostSocket;
  WebSocketChannel? _pushSocket;
  StreamSubscription? _muxSub;
  StreamSubscription? _hostSub;
  StreamSubscription? _pushSub;
  Timer? _reconnectTimer;
  int _generation = 0;
  bool _disposed = false;

  Uri get _wsBase {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme);
  }

  /// Open (or re-open) the connection generation.
  Future<void> connect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final generation = ++_generation;
    _setStatus(status == ConnStatus.disconnected ? ConnStatus.connecting : ConnStatus.reconnecting);
    try {
      await _tearDownSockets();
      // Readiness requires both downlink sockets plus host.describe.
      final muxReady = Completer<void>();
      final hostReady = Completer<void>();
      _openSocket('events.mux', _muxController, muxReady, (ch) => _muxSocket = ch, (s) => _muxSub = s, generation);
      _openSocket('events.host', _hostController, hostReady, (ch) => _hostSocket = ch, (s) => _hostSub = s, generation);
      _openOutboxSocket(generation);
      final describe = await api.rpc('host.describe');
      await Future.wait([muxReady.future, hostReady.future]).timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation) return;
      host = HostDescription.fromJson((describe as Map).cast<String, dynamic>());
      lastError = null;
      _setStatus(ConnStatus.connected);
    } catch (e) {
      if (_disposed || generation != _generation) return;
      lastError = e.toString();
      _setStatus(ConnStatus.failed);
      _scheduleReconnect();
    }
  }

  void _openSocket(
    String path,
    StreamController<ServerRequestFrame> sink,
    Completer<void> ready,
    void Function(WebSocketChannel) setChannel,
    void Function(StreamSubscription) setSub,
    int generation,
  ) {
    // IO 实现支持自定义握手头（relay token 鉴权用）。
    final channel = IOWebSocketChannel.connect(
      Uri.parse('$_wsBase/api/$path'),
      headers: {
        if (token != null && token!.isNotEmpty) 'x-relay-token': token!,
      },
    );
    setChannel(channel);
    var opened = false;
    setSub(channel.stream.listen(
      (data) {
        if (!opened) {
          opened = true;
          if (!ready.isCompleted) ready.complete();
        }
        if (data is String) {
          final frame = ServerRequestFrame.tryParse(data);
          if (frame != null && !sink.isClosed) sink.add(frame);
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
        _onSocketEnded(generation);
      },
      onDone: () {
        if (!opened && !ready.isCompleted) {
          ready.completeError(StateError('socket closed before first frame'));
        }
        _onSocketEnded(generation);
      },
      cancelOnError: true,
    ));
    // A socket that connects but stays silent still counts as open once the
    // WebSocket handshake succeeded; complete readiness on handshake.
    channel.ready.then((_) {
      if (!ready.isCompleted) {
        opened = true;
        ready.complete();
      }
    }).catchError((Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    });
  }

  /// relay 的 outbox 推送通道（/__relay/outbox，relay 私有，不过 host）。
  /// 失败静默降级（旧版 relay 没有这条通道），不参与就绪握手。
  void _openOutboxSocket(int generation) {
    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse('$_wsBase/__relay/outbox'),
        headers: {
          if (token != null && token!.isNotEmpty) 'x-relay-token': token!,
        },
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

  Future<void> _tearDownSockets() async {
    await _muxSub?.cancel();
    await _hostSub?.cancel();
    await _pushSub?.cancel();
    _muxSub = null;
    _hostSub = null;
    _pushSub = null;
    try {
      await _muxSocket?.sink.close();
    } catch (_) {}
    try {
      await _hostSocket?.sink.close();
    } catch (_) {}
    try {
      await _pushSocket?.sink.close();
    } catch (_) {}
    _muxSocket = null;
    _hostSocket = null;
    _pushSocket = null;
  }

  void _setStatus(ConnStatus next) {
    if (status == next) return;
    status = next;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _generation++;
    _reconnectTimer?.cancel();
    await _tearDownSockets();
    _setStatus(ConnStatus.disconnected);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _tearDownSockets();
    _muxController.close();
    _hostController.close();
    _pushController.close();
    api.dispose();
    super.dispose();
  }
}
