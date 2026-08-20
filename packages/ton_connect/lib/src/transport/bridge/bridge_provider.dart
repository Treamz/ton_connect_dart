import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/connect_event.dart';
import '../../models/connect_request.dart';
import '../../models/return_strategy.dart';
import '../../models/rpc.dart';
import '../../models/ton_connect_error.dart';
import '../../storage/storage.dart';
import '../connect_link.dart';
import '../ton_connect_session.dart';
import 'bridge_gateway.dart';
import 'bridge_message.dart';
import 'bridge_session.dart';
import 'sse_transport.dart';

/// Storage key holding the serialised [BridgeSession].
const String bridgeSessionStorageKey = 'ton_connect:bridge_session';

/// Drives one TON Connect session over the HTTP bridge.
///
/// Sits between the raw [BridgeGateway], which only moves ciphertext, and the
/// dApp: it encrypts and decrypts under the session key, matches responses to
/// the requests that are waiting on them, enforces the id rules the protocol
/// requires, and persists enough state to resume after a restart.
final class BridgeProvider implements TonConnectSession {
  /// Creates a provider.
  ///
  /// The storage holds the session across restarts; without a durable
  /// implementation the user reconnects on every launch.
  BridgeProvider({required this._storage, this._transport, this._httpClient});

  final TonConnectStorage _storage;
  final SseTransport? _transport;
  final http.Client? _httpClient;

  final StreamController<WalletEvent> _events =
      StreamController<WalletEvent>.broadcast();
  final Map<String, Completer<WalletResponse>> _pending = {};

  BridgeSession? _session;
  BridgeGateway? _gateway;
  StreamSubscription<BridgeMessage>? _subscription;
  Completer<ConnectEventSuccess>? _connecting;

  /// Wallet-initiated events, currently only [DisconnectEvent].
  @override
  Stream<WalletEvent> get events => _events.stream;

  /// The current session, or `null` when there is none.
  BridgeSession? get session => _session;

  /// Whether a wallet is connected.
  bool get isConnected => _session?.isConnected ?? false;

  /// Starts a connection and returns the link to hand the wallet.
  ///
  /// Show the returned link as a QR code, or open it to jump to a wallet app.
  /// The subscription to the bridge is live before this returns, so the reply
  /// cannot arrive unheard.
  ///
  /// Await [awaitConnection] for the wallet's answer.
  ///
  /// [bridgeUrl] and [linkBase] come from the wallet's registry entry;
  /// [linkBase] may also be [unifiedDeepLinkBase] to address any wallet.
  Future<String> connect({
    required ConnectRequest request,
    required String bridgeUrl,
    required String linkBase,
    ReturnStrategy? returnStrategy,
    String? traceId,
    String? embeddedRequest,
  }) async {
    if (isConnected) throw const WalletAlreadyConnectedError();

    await _teardown();
    final session = BridgeSession.create(bridgeUrl);
    _session = session;
    _connecting = Completer<ConnectEventSuccess>();

    await _openGateway(session);
    await _persist();

    return buildConnectLink(
      base: linkBase,
      clientId: session.clientId,
      request: request,
      returnStrategy: returnStrategy,
      traceId: traceId,
      embeddedRequest: embeddedRequest,
    );
  }

  /// Completes when the wallet answers the pending connect.
  ///
  /// Throws [TonConnectProtocolError] if the wallet declined — a
  /// [UserDeclinedError] there is an ordinary outcome, not a bug.
  Future<ConnectEventSuccess> awaitConnection() {
    final connecting = _connecting;
    if (connecting == null) {
      throw const WalletNotConnectedError('No connect is in progress.');
    }
    return connecting.future;
  }

  /// Restores a session persisted by an earlier run.
  ///
  /// Returns `false` when there is nothing stored or the stored session never
  /// completed its handshake. Returns `true` once the bridge subscription is
  /// live again; the wallet is not contacted, because a completed handshake
  /// stays valid until either side drops it.
  Future<bool> restoreConnection() async {
    final raw = await _storage.read(bridgeSessionStorageKey);
    if (raw == null) return false;

    final BridgeSession session;
    try {
      session = BridgeSession.fromJson(raw);
    } on TonConnectError {
      // Unreadable stored state is worse than none: drop it rather than
      // failing every launch from here on.
      await _storage.delete(bridgeSessionStorageKey);
      return false;
    }

    if (!session.isConnected) {
      await _storage.delete(bridgeSessionStorageKey);
      return false;
    }

    await _teardown();
    _session = session;
    await _openGateway(session);
    return true;
  }

  Future<void> _openGateway(BridgeSession session) async {
    final gateway = BridgeGateway(
      bridgeUrl: Uri.parse(session.bridgeUrl),
      clientId: session.clientId,
      transport: _transport,
      httpClient: _httpClient,
    );
    _gateway = gateway;
    _subscription = gateway.messages.listen(
      _onMessage,
      onError: _events.addError,
    );
    await gateway.open(lastEventId: session.lastEventId);
  }

  void _onMessage(BridgeMessage envelope) {
    final session = _session;
    if (session == null) return;

    // A session is a fixed pair of client_ids. Once the wallet is known,
    // anything from another sender is not part of this session.
    final peer = session.walletClientId;
    if (peer != null && envelope.from != peer) return;

    final String plaintext;
    try {
      plaintext = session.crypto.decrypt(envelope.message, envelope.from);
    } on TonConnectSessionError catch (e) {
      _events.addError(e);
      return;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(plaintext);
    } on FormatException catch (e) {
      _events.addError(
        TonConnectParseError('Wallet message is not valid JSON: ${e.message}'),
      );
      return;
    }
    if (decoded is! Map<String, Object?>) {
      _events.addError(
        const TonConnectParseError('Wallet message is not a JSON object.'),
      );
      return;
    }

    // A wallet message is either an event or a response to a request.
    if (decoded.containsKey('event')) {
      _onWalletEvent(decoded, envelope.from);
    } else {
      _onWalletResponse(decoded);
      unawaited(_persist());
    }
  }

  void _onWalletEvent(Map<String, Object?> json, String from) {
    final session = _session;
    if (session == null) return;

    final id = json['id'];
    if (id is! int) {
      _events.addError(
        const TonConnectParseError('Wallet event is missing an integer "id".'),
      );
      return;
    }

    // Events must increase strictly. A bridge replaying from last_event_id can
    // redeliver an old event, and re-applying a stale disconnect would drop a
    // session that is actually alive.
    final lastSeen = session.lastWalletEventId;
    if (lastSeen != null && id <= lastSeen) return;
    _session = session.copyWith(lastWalletEventId: id);

    switch (json['event']) {
      case 'connect' || 'connect_error':
        _completeConnect(json, from);
        unawaited(_persist());
      case 'disconnect':
        _events.add(DisconnectEvent(id));
        // The wallet dropped the session; its keys are dead from here on.
        // Clearing it synchronously stops anything still in flight from
        // persisting a session that has already ended.
        _session = null;
        unawaited(_forgetSession());
      case final Object? unknown:
        _events.addError(
          TonConnectParseError('Unexpected wallet event "$unknown".'),
        );
    }
  }

  void _completeConnect(Map<String, Object?> json, String from) {
    final connecting = _connecting;
    final session = _session;
    if (connecting == null || session == null || connecting.isCompleted) return;

    final ConnectEvent event;
    try {
      event = ConnectEvent.fromJson(json);
    } on TonConnectError catch (e) {
      connecting.completeError(e);
      return;
    }

    switch (event) {
      case ConnectEventSuccess():
        // The sender of the connect reply is the wallet's half of the session.
        _session = session.copyWith(walletClientId: from);
        unawaited(_persist());
        connecting.complete(event);
      case ConnectEventError():
        connecting.completeError(event.error);
        unawaited(_forgetSession());
    }
  }

  void _onWalletResponse(Map<String, Object?> json) {
    final WalletResponse response;
    try {
      response = WalletResponse.fromJson(json);
    } on TonConnectParseError catch (e) {
      _events.addError(e);
      return;
    }

    // A response with no waiting request is a duplicate or a late arrival after
    // a timeout. Dropping it is correct; the caller has already moved on.
    _pending.remove(response.id)?.complete(response);
  }

  /// Sends [request] to the wallet and waits for the matching response.
  ///
  /// The request id is assigned here, from a counter that survives restarts,
  /// because the wallet rejects any id that does not exceed the last one it
  /// processed.
  ///
  /// Throws [WalletNotConnectedError] when no wallet is connected, and
  /// [TonConnectBridgeError] when the bridge refuses the message. The returned
  /// future resolves when the wallet answers, which is after the user acts.
  @override
  Future<WalletResponse> sendRequest(
    AppRequest request, {
    Duration ttl = const Duration(seconds: 300),
    String? traceId,
  }) async {
    final dispatched = await _dispatch(request, ttl: ttl, traceId: traceId);
    return dispatched.response;
  }

  /// Posts [request] and hands back the future that resolves on the reply.
  ///
  /// Awaiting this waits only for the bridge to accept the message. That is the
  /// distinction [disconnect] needs: it must know the notice went out, but the
  /// wallet owes it no answer.
  Future<({Future<WalletResponse> response})> _dispatch(
    AppRequest request, {
    required Duration ttl,
    String? traceId,
  }) async {
    final session = _session;
    final gateway = _gateway;
    final peer = session?.walletClientId;
    if (session == null || gateway == null || peer == null) {
      throw const WalletNotConnectedError();
    }

    final id = '${session.nextRequestId}';
    _session = session.copyWith(nextRequestId: session.nextRequestId + 1);
    await _persist();

    final completer = Completer<WalletResponse>();
    _pending[id] = completer;

    try {
      await gateway.send(
        to: peer,
        message: session.crypto.encrypt(jsonEncode(request.toJson(id)), peer),
        ttl: ttl,
        // The topic lets the bridge raise a push notification without ever
        // seeing which method it is routing.
        topic: request.method,
        traceId: traceId,
      );
    } on Object {
      _pending.remove(id);
      rethrow;
    }

    return (response: completer.future);
  }

  /// Ends the session from the dApp's side.
  ///
  /// Tells the wallet, then forgets the session either way: a disconnect the
  /// wallet never hears about still has to end locally, or the user is stuck
  /// connected to a wallet the app no longer talks to.
  @override
  Future<void> disconnect() async {
    if (!isConnected) {
      await _forgetSession();
      return;
    }

    try {
      final sent = await _dispatch(
        const DisconnectRequest(),
        ttl: const Duration(seconds: 300),
      );
      // The wallet SHOULD NOT reply to a dApp-initiated disconnect, so waiting
      // on a response would only stall until the request timed out.
      sent.response.ignore();
    } on Object {
      // Best effort. The local session ends either way — a wallet that never
      // hears the notice must not leave the dApp believing it is connected.
    }
    await _forgetSession();
  }

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    final gateway = _gateway;
    final withEventId = gateway?.lastEventId != null
        ? session.copyWith(lastEventId: gateway!.lastEventId)
        : session;
    _session = withEventId;
    await _storage.write(bridgeSessionStorageKey, withEventId.toJson());
  }

  Future<void> _forgetSession() async {
    await _storage.delete(bridgeSessionStorageKey);
    await _teardown();
    _session = null;
  }

  Future<void> _teardown() async {
    await _subscription?.cancel();
    _subscription = null;
    await _gateway?.close();
    _gateway = null;

    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const WalletNotConnectedError('The session ended.'),
        );
        // A caller that fired the request without awaiting it would otherwise
        // turn this into an unhandled async error that takes down the zone.
        // Callers that did await still receive it.
        pending.future.ignore();
      }
    }
    _pending.clear();

    final connecting = _connecting;
    if (connecting != null && !connecting.isCompleted) {
      connecting.completeError(
        const WalletNotConnectedError('The connect was cancelled.'),
      );
      connecting.future.ignore();
    }
    _connecting = null;
  }

  /// Closes the provider and releases its resources.
  ///
  /// Does not disconnect the wallet — the session stays valid and can be
  /// restored later. Call [disconnect] to actually end it.
  @override
  Future<void> close() async {
    await _teardown();
    await _events.close();
  }
}
