import 'dart:convert';

import 'package:meta/meta.dart';

import '../../crypto/session_crypto.dart';
import '../../models/ton_connect_error.dart';

/// Everything needed to resume a bridge session after a restart.
///
/// Holds the session secret key, so persist it somewhere a hostile app on the
/// device cannot read.
@immutable
final class BridgeSession {
  /// Creates a session record.
  const BridgeSession({
    required this.crypto,
    required this.bridgeUrl,
    this.walletClientId,
    this.lastEventId,
    this.nextRequestId = 1,
    this.lastWalletEventId,
  });

  /// Starts a new session against [bridgeUrl] with a fresh keypair.
  factory BridgeSession.create(String bridgeUrl) =>
      BridgeSession(crypto: SessionCrypto(), bridgeUrl: bridgeUrl);

  /// Restores a session from [toJson] output.
  factory BridgeSession.fromJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw TonConnectParseError(
        'Stored session is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const TonConnectParseError('Stored session is not a JSON object.');
    }

    final secretKey = decoded['secretKey'];
    final bridgeUrl = decoded['bridgeUrl'];
    if (secretKey is! String || bridgeUrl is! String) {
      throw const TonConnectParseError(
        'Stored session must carry "secretKey" and "bridgeUrl".',
      );
    }

    return BridgeSession(
      crypto: SessionCrypto.fromSecretKey(secretKey),
      bridgeUrl: bridgeUrl,
      walletClientId: decoded['walletClientId'] as String?,
      lastEventId: decoded['lastEventId'] as String?,
      nextRequestId: decoded['nextRequestId'] as int? ?? 1,
      lastWalletEventId: decoded['lastWalletEventId'] as int?,
    );
  }

  /// The session keypair.
  final SessionCrypto crypto;

  /// Base URL of the bridge this session runs on.
  final String bridgeUrl;

  /// The wallet's `client_id`, learned when the wallet answers the connect.
  ///
  /// Null until the handshake completes. A session is the pair of the two
  /// `client_id` values, so once set this must not change.
  final String? walletClientId;

  /// The last bridge event id delivered, for replay after a restart.
  final String? lastEventId;

  /// The id to assign to the next outgoing request.
  ///
  /// Request ids must increase strictly within a session, and the wallet
  /// rejects anything that does not. Because the wallet remembers the highest
  /// id it has seen, this counter has to survive a process restart — resetting
  /// it to 1 gets every subsequent request rejected until the count catches up.
  final int nextRequestId;

  /// The highest wallet event id processed.
  ///
  /// Used to discard replayed or out-of-order events, which the bridge can
  /// deliver after a reconnect with `last_event_id`.
  final int? lastWalletEventId;

  /// This session's `client_id`.
  String get clientId => crypto.sessionId;

  /// Whether the handshake has completed.
  bool get isConnected => walletClientId != null;

  /// Returns a copy with the given fields replaced.
  BridgeSession copyWith({
    String? walletClientId,
    String? lastEventId,
    int? nextRequestId,
    int? lastWalletEventId,
  }) => BridgeSession(
    crypto: crypto,
    bridgeUrl: bridgeUrl,
    walletClientId: walletClientId ?? this.walletClientId,
    lastEventId: lastEventId ?? this.lastEventId,
    nextRequestId: nextRequestId ?? this.nextRequestId,
    lastWalletEventId: lastWalletEventId ?? this.lastWalletEventId,
  );

  /// Serialises the session for storage.
  String toJson() => jsonEncode({
    'secretKey': crypto.secretKeyHex,
    'bridgeUrl': bridgeUrl,
    'walletClientId': ?walletClientId,
    'lastEventId': ?lastEventId,
    'nextRequestId': nextRequestId,
    'lastWalletEventId': ?lastWalletEventId,
  });

  @override
  String toString() =>
      'BridgeSession(clientId: $clientId, wallet: $walletClientId)';
}
