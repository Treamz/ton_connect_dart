import '../models/rpc.dart';

/// The operations the facade needs from a live session, whichever transport
/// carries it.
///
/// The two transports differ in almost everything — one is an encrypted relay
/// between devices, the other a direct call inside one page — but once a wallet
/// is connected the dApp does the same three things through either.
abstract interface class TonConnectSession {
  /// Wallet-initiated events.
  Stream<WalletEvent> get events;

  /// Sends [request] and waits for the wallet's response.
  ///
  /// [ttl] and [traceId] apply to the HTTP bridge, which buffers messages and
  /// propagates tracing. An injected wallet has neither, and ignores them.
  Future<WalletResponse> sendRequest(
    AppRequest request, {
    Duration ttl,
    String? traceId,
  });

  /// Ends the session.
  Future<void> disconnect();

  /// Releases resources without ending the session.
  Future<void> close();
}
