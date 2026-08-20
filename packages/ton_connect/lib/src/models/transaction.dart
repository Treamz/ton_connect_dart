import 'package:meta/meta.dart';

import 'network.dart';

/// One raw outgoing message in a transaction.
///
/// [address] must be in user-friendly format per TEP-2. Wallets reject raw
/// addresses here, and they read the bounce flag out of the address itself:
/// use a bounceable address for smart contracts, so a throwing or
/// uninitialised contract returns the funds, and a non-bounceable one for
/// wallet contracts, so a transfer to an undeployed wallet still lands.
@immutable
final class TransactionMessage {
  /// Creates a raw message.
  const TransactionMessage({
    required this.address,
    required this.amount,
    this.payload,
    this.stateInit,
    this.extraCurrency,
  });

  /// Destination in user-friendly (base64url) format.
  final String address;

  /// Amount in nanocoins.
  final BigInt amount;

  /// Raw one-cell BoC in base64, when the message carries a body.
  final String? payload;

  /// Raw one-cell BoC in base64, to deploy the destination contract.
  final String? stateInit;

  /// Extra currencies, keyed by currency id.
  final Map<int, BigInt>? extraCurrency;

  /// Serialises the message for the transaction payload.
  Map<String, Object?> toJson() => {
    'address': address,
    'amount': amount.toString(),
    'payload': ?payload,
    'stateInit': ?stateInit,
    if (extraCurrency != null)
      'extra_currency': {
        for (final entry in extraCurrency!.entries)
          '${entry.key}': entry.value.toString(),
      },
  };
}

/// A structured transfer the wallet composes into a message itself.
///
/// Structured items let the wallet build and label the transfer, so the user
/// sees "send 10 USDT" rather than an opaque cell. Wallets advertise which
/// types they accept through the `itemTypes` parameter of their
/// `SendTransaction` or `SignMessage` feature; a wallet that advertises none
/// accepts only raw [TransactionMessage]s.
@immutable
sealed class TransactionItem {
  const TransactionItem();

  /// Serialises the item for the transaction payload.
  Map<String, Object?> toJson();
}

/// A plain TON transfer.
@immutable
final class TonTransferItem extends TransactionItem {
  /// Creates a TON transfer item.
  const TonTransferItem({
    required this.address,
    required this.amount,
    this.payload,
    this.stateInit,
    this.extraCurrency,
  });

  /// Destination address in user-friendly format.
  final String address;

  /// Amount in nanocoins.
  final BigInt amount;

  /// Raw one-cell BoC in base64.
  final String? payload;

  /// Raw one-cell BoC in base64.
  final String? stateInit;

  /// Extra currencies, keyed by currency id.
  final Map<int, BigInt>? extraCurrency;

  @override
  Map<String, Object?> toJson() => {
    'type': 'ton',
    'address': address,
    'amount': amount.toString(),
    'payload': ?payload,
    'stateInit': ?stateInit,
    if (extraCurrency != null)
      'extra_currency': {
        for (final entry in extraCurrency!.entries)
          '${entry.key}': entry.value.toString(),
      },
  };
}

/// A jetton transfer — USDT and every other TON token.
///
/// Leave [attachAmount] unset unless you have a reason not to: the wallet
/// computes the TON needed to carry the transfer, and a value that is too low
/// strands the transfer half-executed.
@immutable
final class JettonTransferItem extends TransactionItem {
  /// Creates a jetton transfer item.
  const JettonTransferItem({
    required this.master,
    required this.destination,
    required this.amount,
    this.attachAmount,
    this.queryId,
    this.responseDestination,
    this.customPayload,
    this.forwardAmount,
    this.forwardPayload,
  });

  /// Jetton master contract address.
  final String master;

  /// Recipient address.
  final String destination;

  /// Amount in the jetton's elementary units, not nanocoins.
  final BigInt amount;

  /// TON to attach for execution. The wallet calculates it when omitted.
  final BigInt? attachAmount;

  /// Query id for the transfer body.
  final String? queryId;

  /// Where excess TON is refunded. Defaults to the sender.
  final String? responseDestination;

  /// Raw one-cell BoC in base64.
  final String? customPayload;

  /// Nanocoins forwarded to the destination. Defaults to 1.
  ///
  /// A forward amount above zero is what triggers the recipient's notification
  /// message, which is how most services detect an incoming jetton transfer.
  final BigInt? forwardAmount;

  /// Raw one-cell BoC in base64, carried to the destination.
  final String? forwardPayload;

  @override
  Map<String, Object?> toJson() => {
    'type': 'jetton',
    'master': master,
    'destination': destination,
    'amount': amount.toString(),
    'attachAmount': ?attachAmount?.toString(),
    'queryId': ?queryId,
    'responseDestination': ?responseDestination,
    'customPayload': ?customPayload,
    'forwardAmount': ?forwardAmount?.toString(),
    'forwardPayload': ?forwardPayload,
  };
}

/// An NFT transfer.
@immutable
final class NftTransferItem extends TransactionItem {
  /// Creates an NFT transfer item.
  const NftTransferItem({
    required this.nftAddress,
    required this.newOwner,
    this.attachAmount,
    this.queryId,
    this.responseDestination,
    this.customPayload,
    this.forwardAmount,
    this.forwardPayload,
  });

  /// NFT item contract address.
  final String nftAddress;

  /// Address receiving the item.
  final String newOwner;

  /// TON to attach for execution. The wallet calculates it when omitted.
  final BigInt? attachAmount;

  /// Query id for the transfer body.
  final String? queryId;

  /// Where excess TON is refunded. Defaults to the sender.
  final String? responseDestination;

  /// Raw one-cell BoC in base64.
  final String? customPayload;

  /// Nanocoins forwarded to the new owner. Defaults to 1.
  final BigInt? forwardAmount;

  /// Raw one-cell BoC in base64, carried to the new owner.
  final String? forwardPayload;

  @override
  Map<String, Object?> toJson() => {
    'type': 'nft',
    'nftAddress': nftAddress,
    'newOwner': newOwner,
    'attachAmount': ?attachAmount?.toString(),
    'queryId': ?queryId,
    'responseDestination': ?responseDestination,
    'customPayload': ?customPayload,
    'forwardAmount': ?forwardAmount?.toString(),
    'forwardPayload': ?forwardPayload,
  };
}

/// The payload of a `sendTransaction` or `signMessage` request.
///
/// A payload carries either raw [TransactionMessage]s or structured
/// [TransactionItem]s, never both. The two constructors make that structural,
/// so a payload the wallet would reject cannot be built in the first place.
@immutable
final class TransactionPayload {
  /// Creates a payload of raw messages.
  const TransactionPayload.messages(
    List<TransactionMessage> messages, {
    this.validUntil,
    this.network,
    this.from,
  }) : _messages = messages,
       _items = null;

  /// Creates a payload of structured items.
  ///
  /// Check the wallet's advertised `itemTypes` before using this: a wallet
  /// that does not list the item type will refuse the request.
  const TransactionPayload.items(
    List<TransactionItem> items, {
    this.validUntil,
    this.network,
    this.from,
  }) : _items = items,
       _messages = null;

  final List<TransactionMessage>? _messages;
  final List<TransactionItem>? _items;

  /// When the request stops being valid. The wallet rejects it afterwards.
  ///
  /// Set this on anything a user might leave sitting on a confirmation screen.
  /// Without it a transaction approved an hour later still goes through.
  final DateTime? validUntil;

  /// The network the dApp intends to transact on.
  ///
  /// Always set this. If it is omitted the wallet uses whatever network it
  /// happens to be on, and a mainnet payment can be signed on testnet. When it
  /// is set and does not match, the wallet refuses instead.
  final NetworkId? network;

  /// The sender address the dApp requires.
  ///
  /// Set this when the payment must come from a specific account — the wallet
  /// then cannot let the user switch accounts at confirmation time.
  final String? from;

  /// Raw messages, when this payload carries them.
  List<TransactionMessage>? get messages => _messages;

  /// Structured items, when this payload carries them.
  List<TransactionItem>? get items => _items;

  /// Serialises the payload.
  Map<String, Object?> toJson() => {
    if (validUntil != null)
      'valid_until': validUntil!.millisecondsSinceEpoch ~/ 1000,
    'network': ?network?.globalId,
    'from': ?from,
    if (_messages != null)
      'messages': [for (final message in _messages) message.toJson()],
    if (_items != null) 'items': [for (final item in _items) item.toJson()],
  };
}
