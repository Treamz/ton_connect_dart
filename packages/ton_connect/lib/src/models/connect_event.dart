import 'package:meta/meta.dart';

import 'device_info.dart';
import 'network.dart';
import 'ton_connect_error.dart';

/// The wallet's reply to a [ConnectRequest].
///
/// [ConnectRequest]: ../connect_request/ConnectRequest-class.html
@immutable
sealed class ConnectEvent {
  const ConnectEvent(this.id);

  /// Increasing wallet-side event counter.
  ///
  /// Wallets emit this so a dApp can discard events it has already processed
  /// after a bridge replay. Compare against the last seen id per session.
  final int id;

  /// Parses a `connect` or `connect_error` event.
  factory ConnectEvent.fromJson(Map<String, Object?> json) {
    final event = json['event'];
    final id = json['id'];
    if (id is! int) {
      throw const TonConnectParseError(
        'Connect event is missing an integer "id".',
      );
    }
    final payload = json['payload'];
    if (payload is! Map<String, Object?>) {
      throw const TonConnectParseError(
        'Connect event is missing a "payload" object.',
      );
    }

    return switch (event) {
      'connect' => ConnectEventSuccess.fromJson(id, payload, json['response']),
      'connect_error' => ConnectEventError(
        id,
        TonConnectProtocolError.fromCode(
          payload['code'] as int? ?? 0,
          payload['message'] as String? ?? 'Wallet rejected the connection.',
        ),
      ),
      _ => throw TonConnectParseError(
        'Unexpected connect event type "$event".',
      ),
    };
  }
}

/// The user approved the connection.
@immutable
final class ConnectEventSuccess extends ConnectEvent {
  /// Creates a successful connect event.
  const ConnectEventSuccess(
    super.id, {
    required this.items,
    required this.device,
    required this.rawPayload,
    this.embeddedResponse,
  });

  /// Parses the success payload.
  factory ConnectEventSuccess.fromJson(
    int id,
    Map<String, Object?> payload,
    Object? embeddedResponse,
  ) {
    final rawItems = payload['items'];
    final rawDevice = payload['device'];
    if (rawDevice is! Map<String, Object?>) {
      throw const TonConnectParseError(
        'Connect payload is missing a "device" object.',
      );
    }
    return ConnectEventSuccess(
      id,
      rawPayload: payload,
      items: rawItems is List<Object?>
          ? List<ConnectItemReply>.unmodifiable(
              rawItems.whereType<Map<String, Object?>>().map(
                ConnectItemReply.fromJson,
              ),
            )
          : const <ConnectItemReply>[],
      device: DeviceInfo.fromJson(rawDevice),
      embeddedResponse: embeddedResponse is Map<String, Object?>
          ? embeddedResponse
          : null,
    );
  }

  /// Replies to the requested connect items, in no guaranteed order.
  final List<ConnectItemReply> items;

  /// Metadata about the wallet application.
  final DeviceInfo device;

  /// The payload exactly as the wallet sent it.
  ///
  /// Kept so a caller can persist the connection and rebuild it later through
  /// the same parsing path, instead of maintaining a second serialisation of
  /// every model that would drift from this one.
  final Map<String, Object?> rawPayload;

  /// Raw response to an embedded request carried in the connect URL.
  ///
  /// Present only when the connect URL used the `e` parameter and the wallet
  /// advertises [EmbeddedRequestFeature].
  final Map<String, Object?>? embeddedResponse;

  /// The connected account, or `null` if the wallet returned no `ton_addr`.
  Account? get account {
    for (final item in items) {
      if (item is TonAddressItemReply) return item.account;
    }
    return null;
  }

  /// The address proof, if one was requested and returned successfully.
  TonProof? get tonProof {
    for (final item in items) {
      if (item is TonProofItemReply) return item.proof;
    }
    return null;
  }
}

/// The connection failed or was declined.
@immutable
final class ConnectEventError extends ConnectEvent {
  /// Creates a failed connect event.
  const ConnectEventError(super.id, this.error);

  /// The reason the wallet gave.
  final TonConnectProtocolError error;
}

/// A wallet reply to one requested connect item.
@immutable
sealed class ConnectItemReply {
  const ConnectItemReply();

  /// Parses one entry of the connect payload's `items` array.
  factory ConnectItemReply.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final error = json['error'];

    if (error is Map<String, Object?>) {
      final failure = TonConnectProtocolError.fromCode(
        error['code'] as int? ?? 0,
        error['message'] as String? ?? 'Wallet declined the "$name" item.',
      );
      return switch (name) {
        'ton_proof' => TonProofItemReply.failed(failure),
        _ => UnknownItemReply(name is String ? name : '', json),
      };
    }

    return switch (name) {
      'ton_addr' => TonAddressItemReply(Account.fromJson(json)),
      'ton_proof' => TonProofItemReply(TonProof.fromJson(json)),
      _ => UnknownItemReply(name is String ? name : '', json),
    };
  }
}

/// Reply to a `ton_addr` item.
@immutable
final class TonAddressItemReply extends ConnectItemReply {
  /// Creates a `ton_addr` reply.
  const TonAddressItemReply(this.account);

  /// The account the wallet connected with.
  final Account account;
}

/// Reply to a `ton_proof` item, successful or failed.
@immutable
final class TonProofItemReply extends ConnectItemReply {
  /// Creates a successful `ton_proof` reply.
  const TonProofItemReply(TonProof this.proof) : error = null;

  /// Creates a failed `ton_proof` reply.
  const TonProofItemReply.failed(TonConnectProtocolError this.error)
    : proof = null;

  /// The proof, when the wallet produced one.
  final TonProof? proof;

  /// Why the wallet declined, when it did.
  final TonConnectProtocolError? error;
}

/// A reply to an item this SDK revision does not model.
@immutable
final class UnknownItemReply extends ConnectItemReply {
  /// Creates an unknown item reply preserving its raw [json].
  const UnknownItemReply(this.name, this.json);

  /// The item name as sent by the wallet.
  final String name;

  /// The raw reply object.
  final Map<String, Object?> json;
}

/// An account exposed by the wallet.
///
/// Every field here is untrusted — the wallet asserts them but proves nothing.
/// Request a `ton_proof` item when the address authenticates a user.
@immutable
final class Account {
  /// Creates an account descriptor.
  const Account({
    required this.address,
    required this.network,
    required this.publicKey,
    required this.walletStateInit,
  });

  /// Parses a `ton_addr` reply.
  factory Account.fromJson(Map<String, Object?> json) {
    final address = json['address'];
    if (address is! String) {
      throw const TonConnectParseError(
        'ton_addr reply is missing a string "address".',
      );
    }
    return Account(
      address: address,
      network: NetworkId(
        json['network'] as String? ?? NetworkId.mainnet.globalId,
      ),
      publicKey: json['publicKey'] as String? ?? '',
      walletStateInit: json['walletStateInit'] as String? ?? '',
    );
  }

  /// Raw-format address, `0:<hex>`.
  final String address;

  /// Network `global_id` of the connected account.
  final NetworkId network;

  /// Account public key as hex, without a `0x` prefix.
  final String publicKey;

  /// Base64 (not URL-safe) state-init cell of the wallet contract.
  final String walletStateInit;

  @override
  String toString() => 'Account($address on ${network.globalId})';
}

/// A signature proving the user controls the connected account.
///
/// Verify it server-side before trusting it: reconstruct the signed message
/// from [timestamp], [domain] and the account address, then check [signature]
/// against the account's public key. A proof verified only on the client
/// authenticates nothing.
@immutable
final class TonProof {
  /// Creates an address proof.
  const TonProof({
    required this.timestamp,
    required this.domainLengthBytes,
    required this.domain,
    required this.signature,
    required this.payload,
  });

  /// Parses a successful `ton_proof` reply.
  factory TonProof.fromJson(Map<String, Object?> json) {
    final proof = json['proof'];
    if (proof is! Map<String, Object?>) {
      throw const TonConnectParseError(
        'ton_proof reply is missing a "proof" object.',
      );
    }
    final domain = proof['domain'];
    if (domain is! Map<String, Object?>) {
      throw const TonConnectParseError(
        'ton_proof is missing a "domain" object.',
      );
    }
    // The wire type is a string holding 64-bit unix seconds; some wallets send
    // it as a JSON number instead.
    final rawTimestamp = proof['timestamp'];
    final seconds = switch (rawTimestamp) {
      final int value => value,
      final String value => int.tryParse(value),
      _ => null,
    };
    if (seconds == null) {
      throw const TonConnectParseError(
        'ton_proof has an unparseable "timestamp".',
      );
    }

    return TonProof(
      timestamp: seconds,
      domainLengthBytes: domain['lengthBytes'] as int? ?? 0,
      domain: domain['value'] as String? ?? '',
      signature: proof['signature'] as String? ?? '',
      payload: proof['payload'] as String? ?? '',
    );
  }

  /// Unix seconds at which the wallet signed.
  final int timestamp;

  /// Byte length of the domain as the wallet encoded it.
  final int domainLengthBytes;

  /// The dApp domain taken from the manifest.
  final String domain;

  /// Base64-encoded signature.
  final String signature;

  /// The challenge payload echoed from the request.
  final String payload;

  /// [timestamp] as a UTC date-time.
  DateTime get signedAt =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
}
