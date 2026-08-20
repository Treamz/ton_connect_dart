import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'models/connect_event.dart';
import 'models/connect_request.dart';
import 'models/device_info.dart';
import 'models/return_strategy.dart';
import 'models/rpc.dart';
import 'models/ton_connect_error.dart';
import 'models/transaction.dart';
import 'models/wallet_app.dart';
import 'storage/storage.dart';
import 'transport/bridge/bridge_provider.dart';
import 'transport/bridge/sse_transport.dart';
import 'transport/injected/injected_bridge.dart';
import 'transport/injected/injected_discovery.dart';
import 'transport/injected/injected_provider.dart';
import 'transport/ton_connect_session.dart';
import 'wallets/wallets_list_manager.dart';

/// A live connection to a wallet.
@immutable
final class WalletConnection {
  /// Creates a connection record.
  const WalletConnection({
    required this.account,
    required this.device,
    this.proof,
  });

  /// The connected account.
  final Account account;

  /// What the wallet reported about itself.
  ///
  /// Its `features` are authoritative for this session — more so than anything
  /// the wallets registry claims.
  final DeviceInfo device;

  /// The address proof, when one was requested and returned.
  final TonProof? proof;

  @override
  String toString() =>
      'WalletConnection(${account.address} via ${device.appName})';
}

/// The entry point for talking to a TON wallet.
///
/// Wraps the bridge provider and the wallets registry behind the operations a
/// dApp actually performs: pick a wallet, connect, send, disconnect.
///
/// The facade refuses a method the connected wallet did not advertise, before
/// anything goes over the wire. The registry's feature list is a static claim
/// about a wallet binary; only the `DeviceInfo` from the live session says what
/// this wallet, at this version, will actually accept.
final class TonConnect {
  /// Creates a client for the dApp described by [manifestUrl].
  ///
  /// [manifestUrl] must point at a publicly reachable
  /// `tonconnect-manifest.json`. The wallet fetches it to show the user who is
  /// asking, so a localhost URL fails on a physical device.
  TonConnect({
    required this.manifestUrl,
    TonConnectStorage? storage,
    WalletsListManager? walletsList,
    SseTransport? transport,
    http.Client? httpClient,
  }) : _storage = storage ?? InMemoryStorage(),
       _walletsList =
           walletsList ??
           WalletsListManager(storage: storage, httpClient: httpClient) {
    _provider = BridgeProvider(
      storage: _storage,
      transport: transport,
      httpClient: httpClient,
    );
    _eventSubscription = _provider.events.listen(
      _onWalletEvent,
      onError: _events.addError,
    );
  }

  /// URL of the dApp's `tonconnect-manifest.json`.
  final String manifestUrl;

  final TonConnectStorage _storage;
  final WalletsListManager _walletsList;
  late final BridgeProvider _provider;
  late final StreamSubscription<WalletEvent> _eventSubscription;

  InjectedProvider? _injected;
  StreamSubscription<WalletEvent>? _injectedSubscription;

  final StreamController<WalletEvent> _events =
      StreamController<WalletEvent>.broadcast();

  WalletConnection? _connection;

  /// Wallet-initiated events, currently only [DisconnectEvent].
  Stream<WalletEvent> get events => _events.stream;

  /// The live connection, or `null` when no wallet is connected.
  WalletConnection? get connection => _connection;

  /// Whether a wallet is connected.
  bool get isConnected => _connection != null;

  /// The wallets registry.
  WalletsListManager get wallets => _walletsList;

  /// The `window` keys of wallets that injected themselves into this page.
  ///
  /// Always empty off the web. When this is not empty the dApp is running
  /// inside a wallet's browser or a Telegram Mini App, and should offer
  /// [connectInjected] instead of a QR code — the wallet is already here.
  List<String> get injectedWallets => injectedWalletKeys();

  /// The session currently in use, whichever transport carries it.
  TonConnectSession? get _session =>
      _injected ?? (_provider.isConnected ? _provider : null);

  /// Wallets that can be connected on [platform].
  Future<List<WalletApp>> availableWallets(WalletPlatform platform) =>
      _walletsList.forPlatform(platform);

  /// Starts connecting to [wallet] and returns the link to open or show.
  ///
  /// Pass [proofPayload] to also request a `ton_proof`. Use a server-issued
  /// nonce with an expiry: a proof is only evidence of key ownership if it
  /// cannot be replayed, and one verified on the client alone proves nothing.
  ///
  /// The bridge subscription is live before this returns. Await
  /// [awaitConnection] for the wallet's answer.
  Future<String> connect(
    WalletApp wallet, {
    String? proofPayload,
    ReturnStrategy? returnStrategy,
    String? traceId,
  }) async {
    final bridge = wallet.sseBridge;
    final linkBase = wallet.linkBase;
    if (bridge == null || linkBase == null) {
      throw TonConnectBridgeError(
        '${wallet.name} cannot be reached over the HTTP bridge: its registry '
        'entry has no SSE bridge or no link to open.',
      );
    }

    return _provider.connect(
      request: _requestFor(proofPayload),
      bridgeUrl: bridge.url,
      linkBase: linkBase,
      returnStrategy: returnStrategy,
      traceId: traceId,
    );
  }

  /// Connects to the wallet injected under [key], without a bridge or a QR.
  ///
  /// Call this only from an explicit user action. There is no link to show and
  /// no waiting: the wallet is in the same page, so this returns the finished
  /// connection.
  ///
  /// Throws [TonConnectBridgeError] when no wallet is injected under [key], and
  /// [UserDeclinedError] when the user refuses.
  Future<WalletConnection> connectInjected(String key) async {
    final bridge = openInjected(key);
    if (bridge == null) {
      throw TonConnectBridgeError('No wallet is injected under "$key".');
    }
    return _adopt(await _useInjected(bridge).connect(_requestFor(null)));
  }

  InjectedProvider _useInjected(InjectedBridge bridge) {
    final provider = InjectedProvider(bridge);
    _injected = provider;
    _injectedSubscription = provider.events.listen(
      _onWalletEvent,
      onError: _events.addError,
    );
    return provider;
  }

  ConnectRequest _requestFor(String? proofPayload) => ConnectRequest(
    manifestUrl: manifestUrl,
    items: [
      const TonAddressItem(),
      if (proofPayload != null) TonProofItem(proofPayload),
    ],
  );

  /// Completes when the wallet answers the pending connect.
  ///
  /// Throws [UserDeclinedError] when the user refused, which is an ordinary
  /// outcome rather than a failure.
  Future<WalletConnection> awaitConnection() async {
    final event = await _provider.awaitConnection();
    return _adopt(event);
  }

  /// Restores a connection persisted by an earlier run.
  ///
  /// Returns `false` when there is nothing to restore.
  Future<bool> restoreConnection() async {
    for (final key in injectedWalletKeys()) {
      final bridge = openInjected(key);
      if (bridge == null) continue;
      final restored = await _useInjected(bridge).restoreConnection();
      if (restored != null) {
        _adopt(restored);
        return true;
      }
      // This wallet does not know the dApp; drop it and try the next.
      await _releaseInjected();
    }

    if (!await _provider.restoreConnection()) return false;

    final restored = await _readStoredConnection();
    if (restored == null) {
      // The session survived but the account did not, so there is nothing
      // useful to hand back. Drop it rather than report a connection whose
      // account this SDK cannot name.
      await _provider.disconnect();
      return false;
    }
    _connection = restored;
    return true;
  }

  WalletConnection _adopt(ConnectEventSuccess event) {
    final account = event.account;
    if (account == null) {
      throw const TonConnectParseError(
        'The wallet approved the connection without returning an address.',
      );
    }
    final connection = WalletConnection(
      account: account,
      device: event.device,
      proof: event.tonProof,
    );
    _connection = connection;
    // Storing the wallet's own payload means restoring runs the same parser,
    // so there is no second serialisation to drift out of step with this one.
    _fireAndForget(
      _storage.write(_connectionStorageKey, jsonEncode(event.rawPayload)),
    );
    return connection;
  }

  /// Asks the wallet to sign and broadcast [payload].
  ///
  /// Returns the base64 BoC of the broadcast external message. That is a
  /// receipt that the wallet sent something, not proof that it landed — wait
  /// for the transaction on-chain before treating a payment as settled.
  ///
  /// Throws [FeatureNotSupportedError] when the wallet did not advertise
  /// `SendTransaction`, or when [payload] exceeds what it accepts.
  Future<String> sendTransaction(
    TransactionPayload payload, {
    Duration ttl = const Duration(seconds: 300),
    String? traceId,
  }) async {
    final device = _requireConnection().device;
    final feature = device.feature<SendTransactionFeature>();
    if (feature == null) {
      throw FeatureNotSupportedError(
        'SendTransaction',
        '${device.appName} did not advertise sendTransaction.',
      );
    }
    _checkPayload(
      payload,
      feature.maxMessages,
      feature.itemTypes,
      feature: 'SendTransaction',
      method: 'sendTransaction',
    );

    return _resultOf(
      await _requireSession().sendRequest(
        SendTransactionRequest(payload),
        ttl: ttl,
        traceId: traceId,
      ),
    );
  }

  /// Asks the wallet to sign [payload] without broadcasting it.
  ///
  /// Returns the signed BoC for a relayer to submit. This is the basis of
  /// gasless flows, where the relayer pays the network fee so the user needs no
  /// TON of their own.
  ///
  /// Throws [FeatureNotSupportedError] when the wallet did not advertise
  /// `SignMessage`. Many wallets do not — check before offering it in the UI.
  Future<String> signMessage(
    TransactionPayload payload, {
    Duration ttl = const Duration(seconds: 300),
    String? traceId,
  }) async {
    final device = _requireConnection().device;
    final feature = device.feature<SignMessageFeature>();
    if (feature == null) {
      throw FeatureNotSupportedError(
        'SignMessage',
        '${device.appName} did not advertise signMessage.',
      );
    }
    _checkPayload(
      payload,
      feature.maxMessages,
      feature.itemTypes,
      feature: 'SignMessage',
      method: 'signMessage',
    );

    return _resultOf(
      await _requireSession().sendRequest(
        SignMessageRequest(payload),
        ttl: ttl,
        traceId: traceId,
      ),
    );
  }

  /// Ends the session.
  Future<void> disconnect() async {
    await _session?.disconnect();
    await _releaseInjected();
    _connection = null;
    await _storage.delete(_connectionStorageKey);
  }

  Future<void> _releaseInjected() async {
    await _injectedSubscription?.cancel();
    _injectedSubscription = null;
    await _injected?.close();
    _injected = null;
  }

  TonConnectSession _requireSession() {
    final session = _session;
    if (session == null) throw const WalletNotConnectedError();
    return session;
  }

  /// Refuses a payload the connected wallet would not accept.
  ///
  /// [feature] names the capability for [FeatureNotSupportedError.feature], so
  /// a caller matching on it sees the same value whether the wallet lacks the
  /// feature outright or merely refuses this payload. [method] is only for the
  /// human-readable message.
  void _checkPayload(
    TransactionPayload payload,
    int maxMessages,
    Set<TransactionItemType>? itemTypes, {
    required String feature,
    required String method,
  }) {
    final messages = payload.messages;
    final items = payload.items;

    final count = messages?.length ?? items?.length ?? 0;
    if (count > maxMessages) {
      throw FeatureNotSupportedError(
        feature,
        'The wallet accepts at most $maxMessages messages per $method, '
        'and this payload carries $count.',
      );
    }

    if (items == null) return;
    if (itemTypes == null) {
      throw FeatureNotSupportedError(
        feature,
        'The wallet accepts only raw messages: it advertised no structured '
        'item types. Build the payload with TransactionPayload.messages.',
      );
    }
    for (final item in items) {
      final type = switch (item) {
        TonTransferItem() => TransactionItemType.ton,
        JettonTransferItem() => TransactionItemType.jetton,
        NftTransferItem() => TransactionItemType.nft,
      };
      if (!itemTypes.contains(type)) {
        throw FeatureNotSupportedError(
          feature,
          'The wallet does not accept "${type.name}" items in $method.',
        );
      }
    }
  }

  String _resultOf(WalletResponse response) => switch (response) {
    WalletResponseError(:final error) => throw error,
    WalletResponseSuccess(:final resultString?) => resultString,
    WalletResponseSuccess() => throw const TonConnectParseError(
      'The wallet returned a result that was not a BoC string.',
    ),
  };

  /// Starts [work] without waiting for it.
  ///
  /// Storage is `FutureOr<void>` so a synchronous implementation costs nothing;
  /// this bridges that back to something [unawaited] accepts.
  static void _fireAndForget(FutureOr<void> work) {
    if (work is Future<void>) unawaited(work);
  }

  WalletConnection _requireConnection() {
    final connection = _connection;
    if (connection == null) throw const WalletNotConnectedError();
    return connection;
  }

  void _onWalletEvent(WalletEvent event) {
    if (event is DisconnectEvent) {
      _connection = null;
      _fireAndForget(_storage.delete(_connectionStorageKey));
    }
    _events.add(event);
  }

  static const String _connectionStorageKey = 'ton_connect:connection';

  Future<WalletConnection?> _readStoredConnection() async {
    final raw = await _storage.read(_connectionStorageKey);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final event = ConnectEventSuccess.fromJson(0, decoded, null);
      final account = event.account;
      if (account == null) return null;
      return WalletConnection(
        account: account,
        device: event.device,
        proof: event.tonProof,
      );
    } on Object {
      // A stored connection this build can no longer read is worse than none.
      await _storage.delete(_connectionStorageKey);
      return null;
    }
  }

  /// Releases resources. Does not disconnect the wallet.
  Future<void> close() async {
    await _eventSubscription.cancel();
    await _releaseInjected();
    await _provider.close();
    await _events.close();
    _walletsList.close();
  }
}
