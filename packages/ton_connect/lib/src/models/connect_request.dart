import 'package:meta/meta.dart';

import 'network.dart';

/// A data item the dApp asks the wallet to share during connect.
@immutable
sealed class ConnectItem {
  const ConnectItem();

  /// Serialises the item for the connect request.
  Map<String, Object?> toJson();
}

/// Requests the account address, public key and state init.
///
/// The reply is untrusted: it proves nothing about key ownership. Pair it with
/// a [TonProofItem] when the address is used to authenticate a user.
@immutable
final class TonAddressItem extends ConnectItem {
  /// Creates a `ton_addr` item, optionally pinning a [network].
  const TonAddressItem({this.network});

  /// The TON network the dApp wants to connect to, if it requires a specific
  /// one. When omitted the wallet chooses.
  final NetworkId? network;

  @override
  Map<String, Object?> toJson() => {
    'name': 'ton_addr',
    if (network != null) 'network': network!.globalId,
  };
}

/// Requests a signature proving the user controls the connected account.
///
/// The [payload] is echoed back inside the signed message. Use a server-issued
/// nonce with an expiry — a replayed proof is otherwise indistinguishable from
/// a fresh one.
@immutable
final class TonProofItem extends ConnectItem {
  /// Creates a `ton_proof` item challenging the wallet with [payload].
  const TonProofItem(this.payload);

  /// Arbitrary challenge payload, echoed in the signed message.
  final String payload;

  @override
  Map<String, Object?> toJson() => {'name': 'ton_proof', 'payload': payload};
}

/// The first message of a session: what the dApp is, and what it wants.
///
/// This travels in the connect URL rather than over the bridge, because bridge
/// keys are not established yet. It is therefore the one message that is not
/// end-to-end encrypted.
@immutable
final class ConnectRequest {
  /// Creates a connect request.
  const ConnectRequest({required this.manifestUrl, required this.items});

  /// URL of the dApp's `tonconnect-manifest.json`.
  ///
  /// The wallet fetches this to show the user who is asking. It must be
  /// publicly reachable — a localhost URL fails on a physical device.
  final String manifestUrl;

  /// Data items to request from the wallet.
  final List<ConnectItem> items;

  /// Serialises the request for the connect URL.
  Map<String, Object?> toJson() => {
    'manifestUrl': manifestUrl,
    'items': [for (final item in items) item.toJson()],
  };
}
