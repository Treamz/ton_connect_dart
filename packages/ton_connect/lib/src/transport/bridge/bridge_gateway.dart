import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../models/ton_connect_error.dart';
import 'bridge_message.dart';
import 'sse_event.dart';
import 'sse_transport.dart';
import 'sse_transport_factory.dart';

/// The payload a bridge sends as a keep-alive.
const String _heartbeatPayload = 'heartbeat';

/// Maintains a subscription to one bridge and posts messages to peers.
///
/// The gateway owns everything about staying connected: retry with backoff, and
/// replay from the last delivered event so nothing buffered is lost across a
/// drop. It does not decrypt — [messages] carries envelopes exactly as the
/// bridge wrote them, and the session layer above turns them into RPC.
///
/// When the platform transport reconnects on its own, as the browser's
/// `EventSource` does, the gateway defers to it rather than running a competing
/// retry loop.
final class BridgeGateway {
  /// Creates a gateway for one bridge, subscribing as [clientId].
  ///
  /// The bridge URL is the base URL from the wallets registry, for example
  /// `https://bridge.tonapi.io/bridge`; `/events` and `/message` are resolved
  /// against it.
  ///
  /// Pass [transport] and [httpClient] to substitute the network in tests.
  BridgeGateway({
    required this._bridgeUrl,
    required this.clientId,
    SseTransport? transport,
    http.Client? httpClient,
    this.heartbeatTimeout = const Duration(seconds: 60),
    this.initialRetryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 30),
    Random? random,
  }) : _transport = transport ?? createSseTransport(),
       _ownsTransport = transport == null,
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _random = random ?? Random();

  /// This session's `client_id`, as 64-character lowercase hex.
  final String clientId;

  /// How long to wait for any event before assuming the connection is dead.
  ///
  /// A TCP connection that dies with the network — a phone moving from Wi-Fi to
  /// cellular — can stay open indefinitely without delivering anything. The
  /// bridge sends periodic keep-alives, so silence past this window means the
  /// connection is gone whatever the socket claims.
  ///
  /// Only applies where the gateway owns reconnection.
  final Duration heartbeatTimeout;

  /// Delay before the first reconnect attempt.
  final Duration initialRetryDelay;

  /// Ceiling for the exponential backoff between reconnect attempts.
  final Duration maxRetryDelay;

  final Uri _bridgeUrl;
  final SseTransport _transport;
  final bool _ownsTransport;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Random _random;

  final StreamController<BridgeMessage> _messages =
      StreamController<BridgeMessage>.broadcast();

  StreamSubscription<SseEvent>? _subscription;
  Timer? _watchdog;
  Timer? _retryTimer;
  int _attempt = 0;
  String? _lastEventId;
  bool _closed = false;
  bool _opened = false;

  /// Envelopes received from peers, still encrypted.
  ///
  /// Keep-alive frames are filtered out — a listener sees only real traffic.
  Stream<BridgeMessage> get messages => _messages.stream;

  /// The id of the last event the bridge delivered.
  ///
  /// Exposed so a caller can persist it and resume across a process restart.
  String? get lastEventId => _lastEventId;

  /// Subscribes to the bridge, completing once the connection is live.
  ///
  /// Await this before publishing a connect link. The bridge buffers messages
  /// for their TTL, so a late subscription is survivable, but a live one avoids
  /// depending on that.
  ///
  /// Pass [lastEventId] to resume a persisted session from where it stopped.
  /// Throws [TonConnectBridgeError] if the first attempt fails; later drops are
  /// retried instead of surfacing.
  Future<void> open({String? lastEventId}) async {
    if (_closed) {
      throw const TonConnectBridgeError('This gateway has been closed.');
    }
    if (_opened) return;
    _lastEventId = lastEventId ?? _lastEventId;

    // The first attempt reports its failure to the caller: an unreachable
    // bridge or a rejected client_id is worth surfacing before a QR is shown.
    // Only once a connection has succeeded does retrying silently make sense.
    await _connect();
    _opened = true;
  }

  Future<void> _connect() async {
    final stream = await _transport.subscribe(
      _eventsUrl(),
      lastEventId: _transport.handlesReconnect ? null : _lastEventId,
    );

    _subscription = stream.listen(
      _onEvent,
      onError: _onStreamFailure,
      onDone: _onStreamClosed,
      cancelOnError: true,
    );
    _armWatchdog();
  }

  void _onEvent(SseEvent event) {
    _armWatchdog();
    if (event.id != null) _lastEventId = event.id;

    // Keep-alives arrive either as their own event type or, when the bridge was
    // asked for standard delivery, as a message with this exact payload.
    if (event.event == _heartbeatPayload) return;
    if (event.data.isEmpty || event.data == _heartbeatPayload) return;

    try {
      _messages.add(BridgeMessage.fromJson(event.data));
    } on TonConnectParseError catch (e) {
      // A malformed envelope is the bridge's fault, not the session's. Report
      // it without tearing down a connection that is otherwise healthy.
      _messages.addError(e);
    }
  }

  void _onStreamFailure(Object error, StackTrace stackTrace) {
    if (_transport.handlesReconnect) {
      // The transport has given up; there is nothing left to retry.
      _messages.addError(error, stackTrace);
      return;
    }
    _scheduleReconnect();
  }

  void _onStreamClosed() {
    // The browser closes and reopens on its own schedule, so a closed stream
    // there is not a signal to act on.
    if (_transport.handlesReconnect) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _watchdog?.cancel();
    _retryTimer?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;

    final delay = _backoffDelay(_attempt++);
    _retryTimer = Timer(delay, () async {
      if (_closed) return;
      try {
        await _connect();
        // Reset only after a connection actually stands, so a bridge that
        // accepts and immediately drops still backs off.
        _attempt = 0;
      } on Object {
        _scheduleReconnect();
      }
    });
  }

  /// Exponential backoff with full jitter, capped at [maxRetryDelay].
  ///
  /// The jitter matters here: every dApp session talking to a bridge that just
  /// restarted would otherwise retry in lockstep and knock it over again.
  Duration _backoffDelay(int attempt) {
    final exponential =
        initialRetryDelay.inMilliseconds * (1 << attempt.clamp(0, 16));
    final capped = min(exponential, maxRetryDelay.inMilliseconds);
    return Duration(milliseconds: _random.nextInt(capped + 1));
  }

  void _armWatchdog() {
    if (_transport.handlesReconnect) return;
    _watchdog?.cancel();
    _watchdog = Timer(heartbeatTimeout, () {
      // Silence past the keep-alive window: treat the connection as dead even
      // though the socket has not reported anything.
      _scheduleReconnect();
    });
  }

  /// Sends an already-encrypted [message] to the peer [to].
  ///
  /// [message] is the base64 `nonce ++ ciphertext` produced by the session
  /// layer. [topic] should name the RPC method inside the ciphertext so the
  /// bridge can route a push notification; it never sees the method otherwise.
  ///
  /// Throws [TonConnectBridgeError] when the bridge rejects the message.
  Future<void> send({
    required String to,
    required String message,
    Duration ttl = const Duration(seconds: 300),
    String? topic,
    String? traceId,
  }) async {
    final url = _resolve('message', {
      'client_id': clientId,
      'to': to,
      'ttl': '${ttl.inSeconds}',
      'topic': ?topic,
      'trace_id': ?traceId,
    });

    final http.Response response;
    try {
      response = await _httpClient.post(url, body: message);
    } on http.ClientException catch (e) {
      throw TonConnectBridgeError('Could not reach the bridge: ${e.message}');
    }

    if (response.statusCode == 200) return;

    final reason = switch (response.statusCode) {
      400 =>
        'Bridge rejected the message as malformed. A ttl above the bridge '
            'limit is the usual cause.',
      413 => 'The message is larger than the bridge accepts.',
      429 => 'Bridge rate limit exceeded.',
      final int code => 'Bridge refused the message (HTTP $code).',
    };
    final detail = response.body.trim();
    throw TonConnectBridgeError(
      detail.isEmpty ? reason : '$reason — $detail',
      statusCode: response.statusCode,
    );
  }

  Uri _eventsUrl() => _resolve('events', {
    'client_id': clientId,
    // Ask for keep-alives as standard messages so the watchdog can see them.
    // The browser transport manages its own liveness and does not need this.
    if (!_transport.handlesReconnect) 'heartbeat': 'message',
  });

  /// Resolves [path] against the bridge base URL, preserving any base path.
  ///
  /// A registry URL like `https://example.org/bridge` must become
  /// `https://example.org/bridge/events`, which plain [Uri.resolve] would
  /// truncate to `https://example.org/events`.
  Uri _resolve(String path, Map<String, String> query) {
    final base = _bridgeUrl.path.endsWith('/')
        ? _bridgeUrl.path.substring(0, _bridgeUrl.path.length - 1)
        : _bridgeUrl.path;
    return _bridgeUrl.replace(path: '$base/$path', queryParameters: query);
  }

  /// Closes the subscription and releases owned resources.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _opened = false;
    _watchdog?.cancel();
    _retryTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    if (_ownsTransport) await _transport.close();
    if (_ownsHttpClient) _httpClient.close();
    await _messages.close();
  }
}
