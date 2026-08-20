import 'dart:convert';

import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

const String clientId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const ConnectRequest simpleRequest = ConnectRequest(
  manifestUrl: 'https://example.org/tonconnect-manifest.json',
  items: [TonAddressItem()],
);

void main() {
  group('buildConnectLink', () {
    test('carries the protocol version and client id', () {
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: simpleRequest,
        ),
      );

      expect(uri.queryParameters['v'], '2');
      expect(uri.queryParameters['id'], clientId);
    });

    test('encodes the request as URL-safe JSON', () {
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: simpleRequest,
        ),
      );

      final decoded = jsonDecode(uri.queryParameters['r']!);
      expect(decoded, isA<Map<String, Object?>>());
      expect(
        (decoded as Map<String, Object?>)['manifestUrl'],
        'https://example.org/tonconnect-manifest.json',
      );
      expect(decoded['items'], [
        {'name': 'ton_addr'},
      ]);
    });

    test('escapes characters that would otherwise break the query', () {
      final link = buildConnectLink(
        base: unifiedDeepLinkBase,
        clientId: clientId,
        request: simpleRequest,
      );

      // Raw JSON braces, quotes and ampersands in the query would truncate the
      // request at the first delimiter a wallet parses.
      final query = link.substring(link.indexOf('?') + 1);
      expect(query, isNot(contains('{')));
      expect(query, isNot(contains('"')));
    });

    test('round-trips a ton_proof payload containing reserved characters', () {
      const payload = 'nonce=1&exp=2 + more';
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: const ConnectRequest(
            manifestUrl: 'https://example.org/m.json',
            items: [TonAddressItem(), TonProofItem(payload)],
          ),
        ),
      );

      final decoded =
          jsonDecode(uri.queryParameters['r']!) as Map<String, Object?>;
      final items = decoded['items']! as List<Object?>;
      expect((items[1]! as Map<String, Object?>)['payload'], payload);
    });

    test('includes the requested network on a ton_addr item', () {
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: const ConnectRequest(
            manifestUrl: 'https://example.org/m.json',
            items: [TonAddressItem(network: NetworkId.testnet)],
          ),
        ),
      );

      final decoded =
          jsonDecode(uri.queryParameters['r']!) as Map<String, Object?>;
      expect((decoded['items']! as List<Object?>).first, {
        'name': 'ton_addr',
        'network': '-3',
      });
    });

    test('omits optional parameters that were not supplied', () {
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: simpleRequest,
        ),
      );

      expect(uri.queryParameters.keys, ['v', 'id', 'r']);
    });

    test('includes the return strategy, trace id and embedded request', () {
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: simpleRequest,
          returnStrategy: ReturnStrategy.none,
          traceId: '01900000-0000-7000-8000-000000000000',
          embeddedRequest: 'eyJtIjoic3QifQ',
        ),
      );

      expect(uri.queryParameters['ret'], 'none');
      expect(
        uri.queryParameters['trace_id'],
        '01900000-0000-7000-8000-000000000000',
      );
      expect(uri.queryParameters['e'], 'eyJtIjoic3QifQ');
    });

    test('carries a custom return URL verbatim', () {
      final uri = Uri.parse(
        buildConnectLink(
          base: unifiedDeepLinkBase,
          clientId: clientId,
          request: simpleRequest,
          returnStrategy: ReturnStrategy.url('myapp://till/receipt?id=7'),
        ),
      );

      expect(uri.queryParameters['ret'], 'myapp://till/receipt?id=7');
    });

    test('appends to a universal URL that already carries a query', () {
      final link = buildConnectLink(
        base: 'https://app.tonkeeper.com/ton-connect?source=qr',
        clientId: clientId,
        request: simpleRequest,
      );

      final uri = Uri.parse(link);
      expect(uri.queryParameters['source'], 'qr');
      expect(uri.queryParameters['v'], '2');
    });

    test('builds a wallet universal link', () {
      final link = buildConnectLink(
        base: 'https://app.tonkeeper.com/ton-connect',
        clientId: clientId,
        request: simpleRequest,
      );

      expect(link, startsWith('https://app.tonkeeper.com/ton-connect?'));
    });
  });
}
