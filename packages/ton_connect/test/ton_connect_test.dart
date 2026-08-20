import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

import 'support/fake_sse_transport.dart';
import 'support/fake_wallet.dart';

const String manifestUrl = 'https://example.org/tonconnect-manifest.json';

final Map<String, Object?> tonkeeperEntry = {
  'app_name': 'tonkeeper',
  'name': 'Tonkeeper',
  'image': 'https://example.org/icon.png',
  'about_url': 'https://tonkeeper.com',
  'universal_url': 'https://app.tonkeeper.com/ton-connect',
  'bridge': [
    {'type': 'sse', 'url': 'https://bridge.example.org/bridge'},
  ],
  'platforms': ['ios', 'android'],
  'features': [
    {'name': 'SendTransaction', 'maxMessages': 4},
  ],
};

/// A wallet with only a JS bridge, which a link cannot reach.
final Map<String, Object?> extensionEntry = {
  'app_name': 'someExtension',
  'name': 'Some Extension',
  'image': 'https://example.org/icon.png',
  'about_url': 'https://example.org',
  'bridge': [
    {'type': 'js', 'key': 'someExtension'},
  ],
  'platforms': ['chrome'],
  'features': [
    {'name': 'SendTransaction', 'maxMessages': 4},
  ],
};

/// Routes registry reads and bridge posts through one client, as a real app would.
http.Client clientRouting({
  List<Map<String, Object?>>? registry,
  void Function(http.Request request)? onPost,
}) {
  return MockClient((request) async {
    if (request.method == 'GET') {
      return http.Response(jsonEncode(registry ?? [tonkeeperEntry]), 200);
    }
    onPost?.call(request);
    return http.Response('', 200);
  });
}

({TonConnect client, FakeSseTransport transport, InMemoryStorage storage})
build({
  List<Map<String, Object?>>? registry,
  void Function(http.Request request)? onPost,
  InMemoryStorage? storage,
}) {
  final transport = FakeSseTransport();
  final store = storage ?? InMemoryStorage();
  final client = TonConnect(
    manifestUrl: manifestUrl,
    storage: store,
    transport: transport,
    httpClient: clientRouting(registry: registry, onPost: onPost),
  );
  return (client: client, transport: transport, storage: store);
}

/// Connects the client in [ctx], answering the handshake as [wallet] would.
Future<WalletConnection> connectAs(
  ({TonConnect client, FakeSseTransport transport, InMemoryStorage storage})
  ctx,
  FakeWallet wallet, {
  List<Map<String, Object?>>? features,
  bool withProof = false,
  String? proofPayload,
}) async {
  final tonkeeper = (await ctx.client.availableWallets(
    WalletPlatform.ios,
  )).first;
  await ctx.client.connect(tonkeeper, proofPayload: proofPayload);
  final pending = ctx.client.awaitConnection();
  ctx.transport.emitMessage(
    wallet.envelopeFor(
      _clientIdOf(ctx),
      wallet.connectSuccess(features: features, withProof: withProof),
    ),
  );
  return pending;
}

String _clientIdOf(
  ({TonConnect client, FakeSseTransport transport, InMemoryStorage storage})
  ctx,
) => Uri.parse(
  ctx.transport.requestedUrls.last.toString(),
).queryParameters['client_id']!;

void main() {
  group('TonConnect connect', () {
    test('builds a link to the wallet universal URL', () async {
      final ctx = build();
      addTearDown(ctx.client.close);

      final wallet = (await ctx.client.availableWallets(
        WalletPlatform.ios,
      )).single;
      final link = await ctx.client.connect(wallet);

      expect(link, startsWith('https://app.tonkeeper.com/ton-connect?'));
      expect(Uri.parse(link).queryParameters['v'], '2');
    });

    test('requests only an address by default', () async {
      final ctx = build();
      addTearDown(ctx.client.close);

      final wallet = (await ctx.client.availableWallets(
        WalletPlatform.ios,
      )).single;
      final link = await ctx.client.connect(wallet);

      final request =
          jsonDecode(Uri.parse(link).queryParameters['r']!)
              as Map<String, Object?>;
      expect(request['items'], [
        {'name': 'ton_addr'},
      ]);
      expect(request['manifestUrl'], manifestUrl);
    });

    test('adds a ton_proof item when a payload is supplied', () async {
      final ctx = build();
      addTearDown(ctx.client.close);

      final wallet = (await ctx.client.availableWallets(
        WalletPlatform.ios,
      )).single;
      final link = await ctx.client.connect(wallet, proofPayload: 'nonce-1');

      final request =
          jsonDecode(Uri.parse(link).queryParameters['r']!)
              as Map<String, Object?>;
      expect(request['items'], [
        {'name': 'ton_addr'},
        {'name': 'ton_proof', 'payload': 'nonce-1'},
      ]);
    });

    test('refuses a wallet that no link can reach', () async {
      final ctx = build(registry: [extensionEntry]);
      addTearDown(ctx.client.close);

      final wallets = await ctx.client.wallets.load();

      await expectLater(
        ctx.client.connect(wallets.single),
        throwsA(isA<TonConnectBridgeError>()),
      );
    });

    test('exposes the account and device once connected', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();

      final connection = await connectAs(ctx, wallet);

      expect(connection.account.address, '0:abc');
      expect(connection.account.network, NetworkId.mainnet);
      expect(connection.device.appName, 'tonkeeper');
      expect(ctx.client.isConnected, isTrue);
    });

    test('exposes a ton_proof when the wallet returned one', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();

      final connection = await connectAs(
        ctx,
        wallet,
        proofPayload: 'nonce-1',
        withProof: true,
      );

      expect(connection.proof, isNotNull);
      expect(connection.proof!.domain, 'example.org');
      expect(connection.proof!.payload, 'nonce-1');
    });
  });

  group('TonConnect feature gating', () {
    Future<void> expectRefused(
      Future<void> Function() call, {
      required String feature,
    }) async {
      await expectLater(
        call(),
        throwsA(
          isA<FeatureNotSupportedError>().having(
            (e) => e.feature,
            'feature',
            feature,
          ),
        ),
      );
    }

    test(
      'refuses sendTransaction when the wallet did not advertise it',
      () async {
        var posted = false;
        final ctx = build(onPost: (_) => posted = true);
        addTearDown(ctx.client.close);
        await connectAs(
          ctx,
          FakeWallet(),
          features: [
            {
              'name': 'SignData',
              'types': ['text'],
            },
          ],
        );

        await expectRefused(
          () => ctx.client.sendTransaction(
            TransactionPayload.messages([
              TransactionMessage(address: 'EQAa', amount: BigInt.one),
            ]),
          ),
          feature: 'SendTransaction',
        );
        // The refusal happens locally: nothing reached the bridge.
        expect(posted, isFalse);
      },
    );

    test('refuses signMessage when the wallet did not advertise it', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      await connectAs(ctx, FakeWallet());

      await expectRefused(
        () => ctx.client.signMessage(
          TransactionPayload.messages([
            TransactionMessage(address: 'EQAa', amount: BigInt.one),
          ]),
        ),
        feature: 'SignMessage',
      );
    });

    test(
      'refuses a payload with more messages than the wallet accepts',
      () async {
        final ctx = build();
        addTearDown(ctx.client.close);
        await connectAs(
          ctx,
          FakeWallet(),
          features: [
            {'name': 'SendTransaction', 'maxMessages': 2},
          ],
        );

        await expectRefused(
          () => ctx.client.sendTransaction(
            TransactionPayload.messages([
              for (var i = 0; i < 3; i++)
                TransactionMessage(address: 'EQAa', amount: BigInt.one),
            ]),
          ),
          feature: 'SendTransaction',
        );
      },
    );

    test('refuses structured items when the wallet advertises none', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      // No itemTypes means raw messages only, which is different from an
      // empty list.
      await connectAs(ctx, FakeWallet());

      await expectRefused(
        () => ctx.client.sendTransaction(
          TransactionPayload.items([
            TonTransferItem(address: 'EQAa', amount: BigInt.one),
          ]),
        ),
        feature: 'SendTransaction',
      );
    });

    test('refuses an item type the wallet does not accept', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      await connectAs(
        ctx,
        FakeWallet(),
        features: [
          {
            'name': 'SendTransaction',
            'maxMessages': 4,
            'itemTypes': ['ton'],
          },
        ],
      );

      await expectRefused(
        () => ctx.client.sendTransaction(
          TransactionPayload.items([
            JettonTransferItem(
              master: 'EQmaster',
              destination: 'EQdest',
              amount: BigInt.from(10),
            ),
          ]),
        ),
        feature: 'SendTransaction',
      );
    });

    test('allows an item type the wallet does accept', () async {
      late http.Request captured;
      final ctx = build(onPost: (request) => captured = request);
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();
      await connectAs(
        ctx,
        wallet,
        features: [
          {
            'name': 'SendTransaction',
            'maxMessages': 4,
            'itemTypes': ['ton', 'jetton'],
          },
        ],
      );

      final pending = ctx.client.sendTransaction(
        TransactionPayload.items([
          JettonTransferItem(
            master: 'EQmaster',
            destination: 'EQdest',
            amount: BigInt.from(10),
          ),
        ], network: NetworkId.mainnet),
      );
      await pumpEventQueue();

      expect(captured.url.queryParameters['topic'], 'sendTransaction');
      _answer(ctx, wallet, captured, result: 'te6boc');
      expect(await pending, 'te6boc');
    });

    test('refuses to send when nothing is connected', () async {
      final ctx = build();
      addTearDown(ctx.client.close);

      await expectLater(
        ctx.client.sendTransaction(
          TransactionPayload.messages([
            TransactionMessage(address: 'EQAa', amount: BigInt.one),
          ]),
        ),
        throwsA(isA<WalletNotConnectedError>()),
      );
    });
  });

  group('TonConnect sendTransaction', () {
    test('returns the BoC the wallet broadcast', () async {
      late http.Request captured;
      final ctx = build(onPost: (request) => captured = request);
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();
      await connectAs(ctx, wallet);

      final pending = ctx.client.sendTransaction(
        TransactionPayload.messages([
          TransactionMessage(
            address: 'EQAacceptor',
            amount: BigInt.from(100000000),
          ),
        ], network: NetworkId.mainnet),
      );
      await pumpEventQueue();
      _answer(ctx, wallet, captured, result: 'te6ccgBROADCAST');

      expect(await pending, 'te6ccgBROADCAST');
    });

    test('sends the payload the caller built', () async {
      late http.Request captured;
      final ctx = build(onPost: (request) => captured = request);
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();
      final connection = await connectAs(ctx, wallet);

      final validUntil = DateTime.utc(2027);
      unawaited(
        ctx.client
            .sendTransaction(
              TransactionPayload.messages(
                [
                  TransactionMessage(
                    address: 'EQAacceptor',
                    amount: BigInt.from(100000000),
                  ),
                ],
                network: NetworkId.mainnet,
                validUntil: validUntil,
              ),
            )
            .then((_) {}, onError: (_) {}),
      );
      await pumpEventQueue();

      final decrypted = wallet.crypto.decrypt(captured.body, _clientIdOf(ctx));
      final request = jsonDecode(decrypted) as Map<String, Object?>;
      expect(request['method'], 'sendTransaction');
      final payload =
          jsonDecode((request['params']! as List<Object?>).single! as String)
              as Map<String, Object?>;
      expect(payload['network'], '-239');
      expect(payload['valid_until'], validUntil.millisecondsSinceEpoch ~/ 1000);
      expect((payload['messages']! as List<Object?>).single, {
        'address': 'EQAacceptor',
        'amount': '100000000',
      });
      expect(connection.account.address, '0:abc');
    });

    test('throws the protocol error when the user declines', () async {
      late http.Request captured;
      final ctx = build(onPost: (request) => captured = request);
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();
      await connectAs(ctx, wallet);

      final pending = ctx.client.sendTransaction(
        TransactionPayload.messages([
          TransactionMessage(address: 'EQAa', amount: BigInt.one),
        ]),
      );
      await pumpEventQueue();

      final requestId = _requestIdOf(ctx, wallet, captured);
      ctx.transport.emitMessage(
        wallet.envelopeFor(_clientIdOf(ctx), wallet.errorResponse(requestId)),
      );

      await expectLater(pending, throwsA(isA<UserDeclinedError>()));
    });
  });

  group('TonConnect session lifetime', () {
    test('restores a connection across a restart', () async {
      final storage = InMemoryStorage();
      final first = build(storage: storage);
      await connectAs(first, FakeWallet());
      await first.client.close();

      final second = build(storage: storage);
      addTearDown(second.client.close);

      expect(await second.client.restoreConnection(), isTrue);
      expect(second.client.connection?.account.address, '0:abc');
      expect(second.client.connection?.device.appName, 'tonkeeper');
    });

    test('reports nothing to restore on a clean install', () async {
      final ctx = build();
      addTearDown(ctx.client.close);

      expect(await ctx.client.restoreConnection(), isFalse);
    });

    test('clears the connection on disconnect', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      await connectAs(ctx, FakeWallet());

      await ctx.client.disconnect();

      expect(ctx.client.isConnected, isFalse);
      expect(ctx.client.connection, isNull);
    });

    test('clears the connection when the wallet disconnects', () async {
      final ctx = build();
      addTearDown(ctx.client.close);
      final wallet = FakeWallet();
      await connectAs(ctx, wallet);

      final events = <WalletEvent>[];
      ctx.client.events.listen(events.add, onError: (_) {});
      ctx.transport.emitMessage(
        wallet.envelopeFor(_clientIdOf(ctx), wallet.disconnectEvent()),
      );
      await pumpEventQueue();

      expect(events.single, isA<DisconnectEvent>());
      expect(ctx.client.isConnected, isFalse);
    });

    test('does not restore after a disconnect', () async {
      final storage = InMemoryStorage();
      final first = build(storage: storage);
      await connectAs(first, FakeWallet());
      await first.client.disconnect();
      await first.client.close();

      final second = build(storage: storage);
      addTearDown(second.client.close);

      expect(await second.client.restoreConnection(), isFalse);
    });
  });
}

/// Answers the request captured in [captured] as the wallet would.
void _answer(
  ({TonConnect client, FakeSseTransport transport, InMemoryStorage storage})
  ctx,
  FakeWallet wallet,
  http.Request captured, {
  required String result,
}) {
  final requestId = _requestIdOf(ctx, wallet, captured);
  ctx.transport.emitMessage(
    wallet.envelopeFor(
      _clientIdOf(ctx),
      wallet.response(requestId, result: result),
    ),
  );
}

String _requestIdOf(
  ({TonConnect client, FakeSseTransport transport, InMemoryStorage storage})
  ctx,
  FakeWallet wallet,
  http.Request captured,
) {
  final decrypted = wallet.crypto.decrypt(captured.body, _clientIdOf(ctx));
  return (jsonDecode(decrypted) as Map<String, Object?>)['id']! as String;
}
