import 'dart:convert';

import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

/// Decodes an `e` parameter back into its wire object.
Map<String, Object?> decode(String encoded) {
  // The encoder strips base64 padding, so it has to be put back to decode.
  final padded = encoded.padRight((encoded.length + 3) & ~3, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}

TransactionPayload get onePayment => TransactionPayload.messages([
  TransactionMessage(address: 'EQAmerchant', amount: BigInt.from(2500000000)),
], network: NetworkId.mainnet);

void main() {
  group('EmbeddedRequest encoding', () {
    test('marks a sendTransaction', () {
      expect(decode(EmbeddedRequest.sendTransaction(onePayment))['m'], 'st');
    });

    test('marks a signMessage', () {
      expect(decode(EmbeddedRequest.signMessage(onePayment))['m'], 'sm');
    });

    test('is base64url without padding', () {
      final encoded = EmbeddedRequest.sendTransaction(onePayment);

      // `=` would be percent-encoded in a query string and waste QR modules,
      // and `+` and `/` would need escaping too.
      expect(encoded, isNot(contains('=')));
      expect(encoded, isNot(contains('+')));
      expect(encoded, isNot(contains('/')));
    });

    test('survives a round trip through a connect URL', () {
      final encoded = EmbeddedRequest.sendTransaction(onePayment);
      final link = buildConnectLink(
        base: unifiedDeepLinkBase,
        clientId: 'a' * 64,
        request: const ConnectRequest(
          manifestUrl: 'https://example.org/m.json',
          items: [TonAddressItem()],
        ),
        embeddedRequest: encoded,
      );

      expect(decode(Uri.parse(link).queryParameters['e']!)['m'], 'st');
    });

    test('abbreviates a raw message', () {
      final wire = decode(EmbeddedRequest.sendTransaction(onePayment));

      expect(wire['n'], '-239');
      expect((wire['ms']! as List<Object?>).single, {
        'a': 'EQAmerchant',
        'am': '2500000000',
      });
      expect(wire, isNot(contains('i')));
    });

    test('carries valid_until as unix seconds', () {
      final expiry = DateTime.utc(2027, 3, 4, 5, 6, 7);
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.messages([
            TransactionMessage(address: 'EQAa', amount: BigInt.one),
          ], validUntil: expiry),
        ),
      );

      expect(wire['vu'], expiry.millisecondsSinceEpoch ~/ 1000);
    });

    test('carries the sender when the dApp pins one', () {
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.messages([
            TransactionMessage(address: 'EQAa', amount: BigInt.one),
          ], from: 'EQAsender'),
        ),
      );

      expect(wire['f'], 'EQAsender');
    });

    test('omits everything the payload did not set', () {
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.messages([
            TransactionMessage(address: 'EQAa', amount: BigInt.one),
          ]),
        ),
      );

      expect(wire.keys, ['m', 'ms']);
    });

    test('abbreviates a jetton item', () {
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.items([
            JettonTransferItem(
              master: 'EQusdt',
              destination: 'EQtill',
              amount: BigInt.from(1000000),
              forwardAmount: BigInt.one,
            ),
          ], network: NetworkId.mainnet),
        ),
      );

      expect((wire['i']! as List<Object?>).single, {
        't': 'jetton',
        'ma': 'EQusdt',
        'd': 'EQtill',
        'am': '1000000',
        'fa': '1',
      });
      expect(wire, isNot(contains('ms')));
    });

    test('abbreviates a ton item', () {
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.items([
            TonTransferItem(address: 'EQtill', amount: BigInt.from(5)),
          ]),
        ),
      );

      expect((wire['i']! as List<Object?>).single, {
        't': 'ton',
        'a': 'EQtill',
        'am': '5',
      });
    });

    test('abbreviates an nft item', () {
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.items([
            const NftTransferItem(nftAddress: 'EQnft', newOwner: 'EQowner'),
          ]),
        ),
      );

      expect((wire['i']! as List<Object?>).single, {
        't': 'nft',
        'na': 'EQnft',
        'no': 'EQowner',
      });
    });

    test('encodes extra currencies as a string map', () {
      final wire = decode(
        EmbeddedRequest.sendTransaction(
          TransactionPayload.messages([
            TransactionMessage(
              address: 'EQAa',
              amount: BigInt.one,
              extraCurrency: {239: BigInt.from(42)},
            ),
          ]),
        ),
      );

      expect((wire['ms']! as List<Object?>).single, {
        'a': 'EQAa',
        'am': '1',
        'ec': {'239': '42'},
      });
    });

    test('stays shorter than the same payload unabbreviated', () {
      final payload = TransactionPayload.messages(
        [
          TransactionMessage(
            address: 'EQAmerchant',
            amount: BigInt.from(2500000000),
          ),
        ],
        network: NetworkId.mainnet,
        from: 'EQAsender',
      );

      // Compare the JSON on both sides: base64 inflates by a third either way,
      // so encoding one and not the other would measure the wrong thing.
      final abbreviated = jsonEncode(
        decode(EmbeddedRequest.sendTransaction(payload)),
      );
      final full = jsonEncode({
        'method': 'sendTransaction',
        'params': [jsonEncode(payload.toJson())],
      });

      // The abbreviations exist to keep the URL short, which keeps the QR
      // coarse enough to scan across a counter.
      expect(abbreviated.length, lessThan(full.length));
    });
  });
}
