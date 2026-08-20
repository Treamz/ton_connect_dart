import 'package:meta/meta.dart';

/// Base type for every error surfaced by this package.
///
/// Errors split into two groups. [TonConnectProtocolError] and its subtypes
/// carry a numeric `code` returned by the wallet over the wire. The remaining
/// subtypes are raised locally by the SDK — bad arguments, transport failures,
/// unusable session state.
@immutable
sealed class TonConnectError implements Exception {
  /// Creates an error carrying a human-readable [message].
  const TonConnectError(this.message);

  /// Human-readable description. Not intended for end users as-is.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// An error returned by the wallet, carrying a protocol error code.
///
/// Codes are shared across the connect flow and the RPC methods, though not
/// every code is valid for every method. See the `code` tables in the TON
/// Connect `connect.md` and `rpc.md` specifications.
@immutable
sealed class TonConnectProtocolError extends TonConnectError {
  /// Creates a protocol error with the wire [code] and [message].
  const TonConnectProtocolError(this.code, super.message);

  /// The numeric error code sent by the wallet.
  final int code;

  /// Maps a wire [code] to the matching error type.
  ///
  /// Unrecognised codes become [UnknownProtocolError] rather than throwing, so
  /// that a wallet using a newer protocol revision cannot break the SDK.
  factory TonConnectProtocolError.fromCode(int code, String message) =>
      switch (code) {
        1 => BadRequestError(message),
        2 => ManifestNotFoundError(message),
        3 => ManifestContentError(message),
        100 => UnknownAppError(message),
        300 => UserDeclinedError(message),
        400 => MethodNotSupportedError(message),
        _ => UnknownProtocolError(code, message),
      };

  @override
  String toString() => '$runtimeType($code): $message';
}

/// Code 0, or any code this SDK revision does not recognise.
final class UnknownProtocolError extends TonConnectProtocolError {
  /// Creates an unknown protocol error.
  const UnknownProtocolError(super.code, super.message);
}

/// Code 1 — the request payload was malformed or violated method constraints.
final class BadRequestError extends TonConnectProtocolError {
  /// Creates a bad-request error.
  const BadRequestError(String message) : super(1, message);
}

/// Code 2 — the wallet could not fetch the dApp manifest.
///
/// Usually the manifest URL is unreachable, blocked by CORS, or served over a
/// scheme the wallet refuses.
final class ManifestNotFoundError extends TonConnectProtocolError {
  /// Creates a manifest-not-found error.
  const ManifestNotFoundError(String message) : super(2, message);
}

/// Code 3 — the manifest was fetched but its contents are invalid.
final class ManifestContentError extends TonConnectProtocolError {
  /// Creates a manifest-content error.
  const ManifestContentError(String message) : super(3, message);
}

/// Code 100 — the wallet does not know this session or app.
///
/// Raised when restoring a session the wallet has since dropped. Treat it as a
/// signal to clear local session state and reconnect.
final class UnknownAppError extends TonConnectProtocolError {
  /// Creates an unknown-app error.
  const UnknownAppError(String message) : super(100, message);
}

/// Code 300 — the user explicitly declined the action.
///
/// This is an expected outcome, not a failure. Do not retry automatically.
final class UserDeclinedError extends TonConnectProtocolError {
  /// Creates a user-declined error.
  const UserDeclinedError(String message) : super(300, message);
}

/// Code 400 — the wallet does not implement the requested method.
final class MethodNotSupportedError extends TonConnectProtocolError {
  /// Creates a method-not-supported error.
  const MethodNotSupportedError(String message) : super(400, message);
}

/// The session keypair or an encrypted bridge payload is unusable.
///
/// Covers malformed keys, truncated ciphertext and failed authentication. A
/// decryption failure MUST NOT be treated as a recoverable parse error — the
/// message is discarded.
final class TonConnectSessionError extends TonConnectError {
  /// Creates a session error.
  const TonConnectSessionError(super.message);
}

/// The bridge transport failed: HTTP error, dropped stream, or a malformed
/// server-sent event.
final class TonConnectBridgeError extends TonConnectError {
  /// Creates a bridge error, optionally carrying the HTTP [statusCode].
  const TonConnectBridgeError(super.message, {this.statusCode});

  /// HTTP status code, when the failure came from an HTTP response.
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'TonConnectBridgeError: $message'
      : 'TonConnectBridgeError($statusCode): $message';
}

/// A wallet response or bridge envelope did not match the expected shape.
final class TonConnectParseError extends TonConnectError {
  /// Creates a parse error.
  const TonConnectParseError(super.message);
}

/// The operation requires a connected wallet, but none is connected.
final class WalletNotConnectedError extends TonConnectError {
  /// Creates a wallet-not-connected error.
  const WalletNotConnectedError([
    super.message = 'No wallet is connected. Call connect() first.',
  ]);
}

/// A connect was attempted while a wallet is already connected.
final class WalletAlreadyConnectedError extends TonConnectError {
  /// Creates a wallet-already-connected error.
  const WalletAlreadyConnectedError([
    super.message = 'A wallet is already connected. Call disconnect() first.',
  ]);
}

/// The connected wallet does not advertise a feature the call requires.
///
/// Raised before anything is sent, because the specification requires SDKs to
/// treat an absent feature as unsupported and refuse the request.
final class FeatureNotSupportedError extends TonConnectError {
  /// Creates a feature-not-supported error naming the missing [feature].
  const FeatureNotSupportedError(this.feature, super.message);

  /// The feature name as it appears in `DeviceInfo.features`.
  final String feature;
}

/// The wallets registry could not be fetched or parsed.
final class WalletsListError extends TonConnectError {
  /// Creates a wallets-list error.
  const WalletsListError(super.message);
}
