import 'dart:async';

import '../../models/connect_event.dart';
import '../../models/connect_request.dart';
import '../../models/rpc.dart';
import '../../models/ton_connect_error.dart';
import '../ton_connect_session.dart';
import 'injected_bridge.dart';

/// Drives a session with a wallet that injected itself into the page.
///
/// This is the Telegram Mini App and wallet-webview path. There is no bridge,
/// no encryption and no session to persist: the wallet is in the same page, so
/// the connection lives exactly as long as the page does. Reconnecting after a
/// reload goes through [restoreConnection], which the wallet answers from its
/// own record of having approved this dApp before.
final class InjectedProvider implements TonConnectSession {
  /// Creates a provider over an injected wallet binding.
  InjectedProvider(this._bridge) {
    _subscription = _bridge.events.listen(_onEvent, onError: _events.addError);
  }

  final InjectedBridge _bridge;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  final StreamController<WalletEvent> _events =
      StreamController<WalletEvent>.broadcast();

  int _nextRequestId = 1;
  int? _lastEventId;
  ConnectEventSuccess? _connection;

  /// Wallet-initiated events, currently only [DisconnectEvent].
  @override
  Stream<WalletEvent> get events => _events.stream;

  /// The `window` key this wallet injected itself under.
  String get key => _bridge.key;

  /// Whether the page is running inside the wallet's own browser.
  bool get isWalletBrowser => _bridge.isWalletBrowser;

  /// Whether a wallet is connected.
  bool get isConnected => _connection != null;

  /// The connect event that established the session, if there is one.
  ConnectEventSuccess? get connection => _connection;

  /// Asks the wallet to connect.
  ///
  /// Call this only from an explicit user action, such as a tap on a connect
  /// button — the specification says so, and a wallet that shows an unprompted
  /// confirmation dialog looks like a phishing attempt. Use
  /// [restoreConnection] on startup instead.
  ///
  /// Throws [TonConnectProtocolError] when the wallet declines.
  Future<ConnectEventSuccess> connect(ConnectRequest request) =>
      _resolveConnect(
        _bridge.connect(_bridge.protocolVersion, request.toJson()),
      );

  /// Attempts to restore a prior approval without prompting the user.
  ///
  /// Returns `null` when the wallet does not recognise the dApp, which is the
  /// ordinary answer on a first visit rather than a failure.
  Future<ConnectEventSuccess?> restoreConnection() async {
    try {
      return await _resolveConnect(_bridge.restoreConnection());
    } on UnknownAppError {
      // Code 100 is exactly how the wallet says "I have not approved you".
      return null;
    }
  }

  Future<ConnectEventSuccess> _resolveConnect(
    Future<Map<String, Object?>> pending,
  ) async {
    final event = ConnectEvent.fromJson(await pending);
    _trackEventId(event.id);

    switch (event) {
      case ConnectEventSuccess():
        _connection = event;
        return event;
      case ConnectEventError():
        _connection = null;
        throw event.error;
    }
  }

  /// Sends [request] to the wallet and returns its response.
  ///
  /// Request ids increase strictly within the session, as the protocol
  /// requires. Nothing is persisted: a page reload starts a new session, and
  /// the wallet's baseline resets with it.
  @override
  Future<WalletResponse> sendRequest(
    AppRequest request, {
    // An injected wallet answers immediately and there is no relay to buffer
    // or trace, so both are accepted and ignored for interface parity.
    Duration ttl = const Duration(seconds: 300),
    String? traceId,
  }) async {
    if (!isConnected) throw const WalletNotConnectedError();

    final id = '${_nextRequestId++}';
    final response = WalletResponse.fromJson(
      await _bridge.send(request.toJson(id)),
    );

    if (response.id != id) {
      // The JS bridge resolves each call with its own answer, so a mismatch
      // means the wallet is confusing requests rather than that a reply
      // arrived late.
      throw TonConnectParseError(
        'The wallet answered request $id with a response for ${response.id}.',
      );
    }
    return response;
  }

  /// Ends the session.
  ///
  /// Tells the wallet, then forgets the connection either way — a refusal must
  /// not leave the dApp believing it is still connected.
  @override
  Future<void> disconnect() async {
    if (!isConnected) return;
    try {
      await sendRequest(const DisconnectRequest());
    } on Object {
      // Best effort; the local session ends regardless.
    }
    _connection = null;
  }

  void _onEvent(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! int) {
      _events.addError(
        const TonConnectParseError('Wallet event is missing an integer "id".'),
      );
      return;
    }
    if (!_trackEventId(id)) return;

    switch (json['event']) {
      case 'disconnect':
        _connection = null;
        _events.add(DisconnectEvent(id));
      case 'connect' || 'connect_error':
        // Connect results arrive as the return value of connect(), not here.
        break;
      case final Object? unknown:
        _events.addError(
          TonConnectParseError('Unexpected wallet event "$unknown".'),
        );
    }
  }

  /// Records [id], returning whether it is new enough to act on.
  ///
  /// Event ids must increase strictly within a session. The first one seen sets
  /// the baseline.
  bool _trackEventId(int id) {
    final lastSeen = _lastEventId;
    if (lastSeen != null && id <= lastSeen) return false;
    _lastEventId = id;
    return true;
  }

  /// Closes the provider. Does not disconnect the wallet.
  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _bridge.close();
    await _events.close();
  }
}
