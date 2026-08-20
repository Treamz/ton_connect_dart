import 'dart:convert';

import 'package:meta/meta.dart';

import '../../models/ton_connect_error.dart';

/// The envelope the bridge writes to a recipient's event stream.
///
/// The bridge itself is untrusted and sees only this: who sent the message and
/// an opaque ciphertext. [message] must be decrypted with the session key
/// before any of it is believed.
@immutable
final class BridgeMessage {
  /// Creates a bridge message envelope.
  const BridgeMessage({
    required this.from,
    required this.message,
    this.traceId,
  });

  /// Parses an envelope from the `data` field of a server-sent event.
  factory BridgeMessage.fromJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw TonConnectParseError(
        'Bridge envelope is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const TonConnectParseError('Bridge envelope is not a JSON object.');
    }

    final from = decoded['from'];
    final message = decoded['message'];
    if (from is! String || message is! String) {
      throw const TonConnectParseError(
        'Bridge envelope must carry string "from" and "message" fields.',
      );
    }

    return BridgeMessage(
      from: from,
      message: message,
      // Older, tracing-unaware bridges omit this; readers must tolerate that.
      traceId: decoded['trace_id'] as String?,
    );
  }

  /// Sender `client_id`, as 64-character lowercase hex.
  final String from;

  /// Base64 ciphertext: a 24-byte nonce followed by the `crypto_box` output.
  final String message;

  /// Analytics correlation id, when the bridge propagates tracing.
  final String? traceId;

  @override
  String toString() => 'BridgeMessage(from: $from, trace_id: $traceId)';
}
