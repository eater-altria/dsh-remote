/// Wire protocol envelope for the DSH host `/api` contract.
///
/// The wire is a four-quadrant discriminated union:
/// - ClientRequest  (POST `/api/<method>` body)
/// - ServerResponse (that POST's response body)
/// - ServerRequest  (downlink WebSocket frame)
/// - ClientResponse (POST `/api/respond` body)
///
/// Responses always echo the matching request's `rpcId`.
library;

import 'dart:convert';

/// Business error carried by the `RpcResult` error branch.
class RpcException implements Exception {
  RpcException(this.code, this.message, this.details);

  final String code;
  final String message;
  final Map<String, dynamic> details;

  factory RpcException.fromJson(Map<String, dynamic> json) => RpcException(
        json['code'] as String? ?? 'internal',
        json['message'] as String? ?? 'unknown error',
        (json['details'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  @override
  String toString() => 'RpcException($code): $message';
}

int _rpcCounter = 0;

/// Mint an opaque rpc id (echo token; uniqueness within the process suffices).
String mintRpcId() {
  _rpcCounter += 1;
  return 'm${_rpcCounter.toRadixString(36)}-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

/// Encode a ClientRequest envelope.
Map<String, dynamic> clientRequest(String rpcId, String method, Object? payload) => {
      'type': 'client-request',
      'rpcId': rpcId,
      'method': method,
      'payload': payload ?? const <String, dynamic>{},
    };

/// Encode a ClientResponse envelope (answer to a ServerRequest, e.g. a
/// question or approval prompt).
Map<String, dynamic> clientResponseOk(String rpcId, Object? value) => {
      'type': 'client-response',
      'rpcId': rpcId,
      'result': {'ok': true, 'value': ?value},
    };

/// Decode a ServerResponse body, returning the business `value` (nullable for
/// void methods) or throwing [RpcException] on the error branch.
dynamic decodeServerResponse(String body, String expectedRpcId) {
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) {
    throw RpcException('bad-response', 'response is not a JSON object', const {});
  }
  if (json['type'] != 'server-response') {
    throw RpcException('bad-response', 'unexpected envelope type: ${json['type']}', const {});
  }
  final rpcId = json['rpcId'];
  if (rpcId != expectedRpcId) {
    throw RpcException('bad-response', 'rpcId mismatch: expected $expectedRpcId, got $rpcId', const {});
  }
  final result = json['result'];
  if (result is! Map<String, dynamic>) {
    throw RpcException('bad-response', 'missing result', const {});
  }
  if (result['ok'] == true) return result['value'];
  final error = result['error'];
  if (error is Map<String, dynamic>) throw RpcException.fromJson(error);
  throw RpcException('internal', 'malformed error branch', const {});
}

/// One decoded ServerRequest downlink frame.
class ServerRequestFrame {
  ServerRequestFrame({required this.rpcId, required this.method, required this.payload});

  final String rpcId;
  final String method;

  /// The MuxFrame / HostFrame map (discriminated by `payload['type']`).
  final Map<String, dynamic> payload;

  static ServerRequestFrame? tryParse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      if (json['type'] != 'server-request') return null;
      final payload = json['payload'];
      if (payload is! Map<String, dynamic>) return null;
      return ServerRequestFrame(
        rpcId: json['rpcId'] as String? ?? '',
        method: json['method'] as String? ?? '',
        payload: payload,
      );
    } catch (_) {
      return null;
    }
  }
}
