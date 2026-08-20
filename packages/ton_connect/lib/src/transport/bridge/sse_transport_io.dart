import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/ton_connect_error.dart';
import 'sse_event.dart';
import 'sse_parser.dart';
import 'sse_transport.dart';

/// Creates the native SSE transport.
SseTransport createPlatformSseTransport() => HttpSseTransport();

/// An [SseTransport] backed by a streaming HTTP client.
///
/// Used on every platform except the web, where `EventSource` is available.
/// This does not reconnect — the gateway owns backoff and replay, so the retry
/// policy stays one thing in one place rather than split with the platform.
final class HttpSseTransport implements SseTransport {
  /// Creates a transport.
  ///
  /// Pass [client] to supply a pre-configured or instrumented HTTP client; the
  /// transport then leaves closing it to the caller.
  HttpSseTransport({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  bool get handlesReconnect => false;

  @override
  Future<Stream<SseEvent>> subscribe(Uri url, {String? lastEventId}) async {
    final request = http.Request('GET', url)
      ..headers['Accept'] = 'text/event-stream'
      // A proxy that caches an event stream would stall the session outright.
      ..headers['Cache-Control'] = 'no-cache';
    if (lastEventId != null) {
      request.headers['Last-Event-ID'] = lastEventId;
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } on http.ClientException catch (e) {
      throw TonConnectBridgeError('Could not reach the bridge: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw await _errorFor(response);
    }

    // Headers are in, so the subscription is live; body chunks follow.
    return response.stream
        // The chunked decoder carries a multi-byte character split across two
        // network chunks over the boundary.
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .transform(const SseParser());
  }

  /// Builds an error for a non-200 response, draining the body first.
  ///
  /// The body is read even when unused: an undrained stream keeps the
  /// connection out of the client's pool.
  Future<TonConnectBridgeError> _errorFor(
    http.StreamedResponse response,
  ) async {
    var body = '';
    try {
      body = await response.stream.bytesToString();
    } on Exception {
      // A body that cannot be read adds nothing to the status code.
    }
    final detail = body.trim().isEmpty ? '' : ' — ${_truncate(body.trim())}';

    return switch (response.statusCode) {
      429 => TonConnectBridgeError(
        'Bridge rate limit exceeded${_retryAfter(response)}$detail',
        statusCode: 429,
      ),
      final int code when code >= 500 => TonConnectBridgeError(
        'Bridge is unavailable (HTTP $code)$detail',
        statusCode: code,
      ),
      final int code => TonConnectBridgeError(
        'Bridge rejected the subscription (HTTP $code)$detail',
        statusCode: code,
      ),
    };
  }

  static String _retryAfter(http.StreamedResponse response) {
    final value = response.headers['retry-after'];
    return value == null ? '' : ', retry after ${value}s';
  }

  static String _truncate(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  @override
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}
