import 'dart:convert';

import 'package:meta/meta.dart';

import 'ton_connect_error.dart';
import 'transaction.dart';

/// A request from the dApp to the wallet.
///
/// The `id` is assigned by the session, not by the caller: the specification
/// requires it to increase strictly within a session, and the wallet rejects
/// anything that does not.
@immutable
sealed class AppRequest {
  const AppRequest();

  /// The RPC method name.
  ///
  /// Doubles as the bridge `topic`, which is how the bridge routes a push
  /// notification without seeing inside the ciphertext.
  String get method;

  /// The `params` array for this method.
  List<String> get params;

  /// Serialises the request with the session-assigned [id].
  Map<String, Object?> toJson(String id) => {
    'method': method,
    'params': params,
    'id': id,
  };
}

/// Asks the wallet to sign and broadcast outgoing messages.
@immutable
final class SendTransactionRequest extends AppRequest {
  /// Creates a `sendTransaction` request.
  const SendTransactionRequest(this.payload);

  /// What to send.
  final TransactionPayload payload;

  @override
  String get method => 'sendTransaction';

  @override
  List<String> get params => [jsonEncode(payload.toJson())];
}

/// Asks the wallet to sign messages without broadcasting them.
///
/// The wallet returns a signed BoC for the dApp to submit through a relayer.
/// This is what gasless flows are built on: a relayer broadcasts and pays the
/// network fee, so the user needs no TON of their own to move a jetton.
@immutable
final class SignMessageRequest extends AppRequest {
  /// Creates a `signMessage` request.
  const SignMessageRequest(this.payload);

  /// What to sign.
  final TransactionPayload payload;

  @override
  String get method => 'signMessage';

  @override
  List<String> get params => [jsonEncode(payload.toJson())];
}

/// Tells the wallet the dApp has ended the session.
@immutable
final class DisconnectRequest extends AppRequest {
  /// Creates a `disconnect` request.
  const DisconnectRequest();

  @override
  String get method => 'disconnect';

  @override
  List<String> get params => const [];
}

/// The wallet's answer to one [AppRequest].
@immutable
sealed class WalletResponse {
  const WalletResponse(this.id);

  /// The id of the request this answers.
  final String id;

  /// Parses a response envelope.
  factory WalletResponse.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String) {
      throw const TonConnectParseError(
        'Wallet response is missing a string "id".',
      );
    }

    final error = json['error'];
    if (error is Map<String, Object?>) {
      return WalletResponseError(
        id,
        TonConnectProtocolError.fromCode(
          error['code'] as int? ?? 0,
          error['message'] as String? ?? 'The wallet rejected the request.',
        ),
        data: error['data'],
      );
    }

    if (!json.containsKey('result')) {
      throw const TonConnectParseError(
        'Wallet response carries neither "result" nor "error".',
      );
    }
    return WalletResponseSuccess(id, json['result']);
  }
}

/// The wallet completed the request.
@immutable
final class WalletResponseSuccess extends WalletResponse {
  /// Creates a successful response.
  const WalletResponseSuccess(super.id, this.result);

  /// The method-specific result.
  ///
  /// `sendTransaction` and `signMessage` return a base64 BoC string;
  /// `disconnect` returns an empty object.
  final Object? result;

  /// The result as a string, or `null` when it is not one.
  String? get resultString => result is String ? result! as String : null;
}

/// The wallet refused or failed the request.
@immutable
final class WalletResponseError extends WalletResponse {
  /// Creates an error response.
  const WalletResponseError(super.id, this.error, {this.data});

  /// Why the wallet refused.
  final TonConnectProtocolError error;

  /// Optional wallet-supplied detail. Shape is not specified.
  final Object? data;
}

/// An event the wallet raises on its own.
@immutable
sealed class WalletEvent {
  const WalletEvent(this.id);

  /// Monotonic per-session event counter.
  ///
  /// Tracked separately from request ids. The dApp must reject an event whose
  /// id does not exceed the last one it processed, which is what stops a bridge
  /// replay from re-applying a stale event.
  final int id;
}

/// The wallet ended the session from its side.
///
/// The user removed the dApp from the wallet's session list. Delete the saved
/// session on receipt — the session keys are dead and reusing them only
/// produces `UNKNOWN_APP`.
@immutable
final class DisconnectEvent extends WalletEvent {
  /// Creates a disconnect event.
  const DisconnectEvent(super.id);
}
