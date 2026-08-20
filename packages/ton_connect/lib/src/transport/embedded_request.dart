import 'dart:convert';

import '../models/transaction.dart';

/// Encodes a request to ride along inside the connect URL.
///
/// Normally connecting and paying are two round trips: the user scans, approves
/// the connection, then approves the transaction. An embedded request folds
/// them into one — which is the difference between a queue moving and a queue
/// waiting, at a shop counter.
///
/// Only wallets advertising the `EmbeddedRequest` feature act on it. Wallets
/// that do not must ignore the parameter, so attaching one never breaks a
/// connect; it just does not save the second step. The wallet's answer arrives
/// as `ConnectEventSuccess.embeddedResponse`.
///
/// Field names on the wire are abbreviated because the whole thing has to fit
/// in a URL, and a longer URL means a denser QR code.
abstract final class EmbeddedRequest {
  /// Encodes a `sendTransaction` to embed in a connect URL.
  static String sendTransaction(TransactionPayload payload) =>
      _encode('st', payload);

  /// Encodes a `signMessage` to embed in a connect URL.
  static String signMessage(TransactionPayload payload) =>
      _encode('sm', payload);

  static String _encode(String method, TransactionPayload payload) {
    final wire = <String, Object?>{
      'm': method,
      'f': ?payload.from,
      'n': ?payload.network?.globalId,
      if (payload.validUntil case final DateTime validUntil)
        'vu': validUntil.millisecondsSinceEpoch ~/ 1000,
      if (payload.messages case final List<TransactionMessage> messages)
        'ms': [for (final message in messages) _message(message)],
      if (payload.items case final List<TransactionItem> items)
        'i': [for (final item in items) _item(item)],
    };

    // Base64url without padding, as the specification requires: `=` would be
    // percent-encoded in a query string and waste QR modules.
    return base64Url.encode(utf8.encode(jsonEncode(wire))).replaceAll('=', '');
  }

  static Map<String, Object?> _message(TransactionMessage message) => {
    'a': message.address,
    'am': message.amount.toString(),
    'p': ?message.payload,
    'si': ?message.stateInit,
    if (message.extraCurrency case final Map<int, BigInt> extra)
      'ec': {
        for (final entry in extra.entries)
          '${entry.key}': entry.value.toString(),
      },
  };

  static Map<String, Object?> _item(TransactionItem item) => switch (item) {
    TonTransferItem(
      :final address,
      :final amount,
      :final payload,
      :final stateInit,
      :final extraCurrency,
    ) =>
      {
        't': 'ton',
        'a': address,
        'am': amount.toString(),
        'p': ?payload,
        'si': ?stateInit,
        if (extraCurrency case final Map<int, BigInt> extra)
          'ec': {
            for (final entry in extra.entries)
              '${entry.key}': entry.value.toString(),
          },
      },
    JettonTransferItem(
      :final master,
      :final destination,
      :final amount,
      :final attachAmount,
      :final responseDestination,
      :final customPayload,
      :final forwardAmount,
      :final forwardPayload,
      :final queryId,
    ) =>
      {
        't': 'jetton',
        'ma': master,
        'd': destination,
        'am': amount.toString(),
        'aa': ?attachAmount?.toString(),
        'rd': ?responseDestination,
        'cp': ?customPayload,
        'fa': ?forwardAmount?.toString(),
        'fp': ?forwardPayload,
        'qi': ?queryId,
      },
    NftTransferItem(
      :final nftAddress,
      :final newOwner,
      :final attachAmount,
      :final responseDestination,
      :final customPayload,
      :final forwardAmount,
      :final forwardPayload,
      :final queryId,
    ) =>
      {
        't': 'nft',
        'na': nftAddress,
        'no': newOwner,
        'aa': ?attachAmount?.toString(),
        'rd': ?responseDestination,
        'cp': ?customPayload,
        'fa': ?forwardAmount?.toString(),
        'fp': ?forwardPayload,
        'qi': ?queryId,
      },
  };
}
