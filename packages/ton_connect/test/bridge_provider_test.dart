import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

import 'support/fake_sse_transport.dart';
import 'support/fake_wallet.dart';

const String bridgeUrl = 'https://bridge.example.org/bridge';

({BridgeProvider provider, FakeSseTransport transport, InMemoryStorage storage})
buildProvider({InMemoryStorage? storage, http.Client? httpClient}) {
  final transport = FakeSseTransport();
  final store = storage ?? InMemoryStorage();
  final provider = BridgeProvider(
    storage: store,
    transport: transport,
    httpClient: httpClient ?? MockClient((_) async => http.Response('', 200)),
  );
  return (provider: provider, transport: transport, storage: store);
}

ConnectRequest get request => const ConnectRequest(
  manifestUrl: 'https://example.org/tonconnect-manifest.json',
  items: [TonAddressItem()],
);

void main() {
  group('BridgeProvider connect', () {
    test(
      'returns a link carrying the protocol version, id and request',
      () async {
        final ctx = buildProvider();
        addTearDown(ctx.provider.close);

        final link = await ctx.provider.connect(
          request: request,
          bridgeUrl: bridgeUrl,
          linkBase: unifiedDeepLinkBase,
        );

        final uri = Uri.parse(link);
        expect(uri.queryParameters['v'], '2');
        expect(uri.queryParameters['id'], ctx.provider.session!.clientId);
        expect(
          jsonDecode(uri.queryParameters['r']!),
          containsPair(
            'manifestUrl',
            'https://example.org/tonconnect-manifest.json',
          ),
        );
      },
    );

    test('subscribes to the bridge before returning the link', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );

      // The reply must not be able to arrive before anyone is listening.
      expect(ctx.transport.connectionCount, 1);
    });

    test('carries the return strategy when given one', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);

      final link = await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
        returnStrategy: ReturnStrategy.back,
      );

      expect(Uri.parse(link).queryParameters['ret'], 'back');
    });

    test('completes the connection when the wallet approves', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(address: '0:deadbeef'),
        ),
      );

      final event = await pending;
      expect(event.account?.address, '0:deadbeef');
      expect(event.device.appName, 'tonkeeper');
      expect(ctx.provider.isConnected, isTrue);
    });

    test('learns the wallet client id from the reply', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(),
        ),
      );
      await pending;

      expect(ctx.provider.session!.walletClientId, wallet.clientId);
    });

    test('surfaces a declined connection as UserDeclinedError', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectError(),
        ),
      );

      await expectLater(pending, throwsA(isA<UserDeclinedError>()));
      expect(ctx.provider.isConnected, isFalse);
    });

    test('refuses a second connect while one is live', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(),
        ),
      );
      await pending;

      await expectLater(
        ctx.provider.connect(
          request: request,
          bridgeUrl: bridgeUrl,
          linkBase: unifiedDeepLinkBase,
        ),
        throwsA(isA<WalletAlreadyConnectedError>()),
      );
    });

    test('awaitConnection without a pending connect throws', () {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);

      expect(
        () => ctx.provider.awaitConnection(),
        throwsA(isA<WalletNotConnectedError>()),
      );
    });
  });

  group('BridgeProvider session persistence', () {
    test('persists the session so it can be restored', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(),
        ),
      );
      await pending;

      final stored = ctx.storage.read(bridgeSessionStorageKey);
      expect(stored, isNotNull);
      expect(
        jsonDecode(stored!),
        containsPair('walletClientId', wallet.clientId),
      );
    });

    test('restores a connected session and resubscribes', () async {
      final storage = InMemoryStorage();
      final wallet = FakeWallet();

      final first = buildProvider(storage: storage);
      await first.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = first.provider.awaitConnection();
      final clientId = first.provider.session!.clientId;
      first.transport.emitMessage(
        wallet.envelopeFor(clientId, wallet.connectSuccess()),
      );
      await pending;
      await first.provider.close();

      final second = buildProvider(storage: storage);
      addTearDown(second.provider.close);

      expect(await second.provider.restoreConnection(), isTrue);
      // The same keypair comes back, so the wallet still recognises the session.
      expect(second.provider.session!.clientId, clientId);
      expect(second.transport.connectionCount, 1);
    });

    test('returns false when nothing is stored', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);

      expect(await ctx.provider.restoreConnection(), isFalse);
    });

    test(
      'discards unreadable stored state instead of failing forever',
      () async {
        final storage = InMemoryStorage()
          ..write(bridgeSessionStorageKey, 'not json at all');
        final ctx = buildProvider(storage: storage);
        addTearDown(ctx.provider.close);

        expect(await ctx.provider.restoreConnection(), isFalse);
        expect(storage.read(bridgeSessionStorageKey), isNull);
      },
    );

    test('discards a session whose handshake never completed', () async {
      final storage = InMemoryStorage();
      final ctx = buildProvider(storage: storage);
      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      await ctx.provider.close();

      final second = buildProvider(storage: storage);
      addTearDown(second.provider.close);

      expect(await second.provider.restoreConnection(), isFalse);
    });
  });

  group('BridgeProvider requests', () {
    Future<
      ({BridgeProvider provider, FakeSseTransport transport, FakeWallet wallet})
    >
    connected({InMemoryStorage? storage, http.Client? httpClient}) async {
      final ctx = buildProvider(storage: storage, httpClient: httpClient);
      final wallet = FakeWallet();
      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(),
        ),
      );
      await pending;
      return (provider: ctx.provider, transport: ctx.transport, wallet: wallet);
    }

    test(
      'posts an encrypted request and resolves on the matching reply',
      () async {
        late http.Request captured;
        final ctx = await connected(
          httpClient: MockClient((request) async {
            captured = request;
            return http.Response('', 200);
          }),
        );
        addTearDown(ctx.provider.close);

        final pending = ctx.provider.sendRequest(
          SendTransactionRequest(
            TransactionPayload.messages([
              TransactionMessage(
                address: 'EQAcceptor',
                amount: BigInt.from(100000000),
              ),
            ], network: NetworkId.mainnet),
          ),
        );
        await pumpEventQueue();

        // The bridge sees only ciphertext and a routing topic.
        expect(captured.url.queryParameters['topic'], 'sendTransaction');
        expect(captured.url.queryParameters['to'], ctx.wallet.clientId);
        expect(captured.body, isNot(contains('EQAcceptor')));

        // The wallet decrypts it and answers.
        final sent = jsonDecode(
          ctx.wallet.crypto.decrypt(
            captured.body,
            ctx.provider.session!.clientId,
          ),
        );
        final requestId = (sent as Map<String, Object?>)['id']! as String;
        ctx.transport.emitMessage(
          ctx.wallet.envelopeFor(
            ctx.provider.session!.clientId,
            ctx.wallet.response(requestId),
          ),
        );

        final response = await pending;
        expect(response, isA<WalletResponseSuccess>());
        expect((response as WalletResponseSuccess).resultString, 'te6ccg');
      },
    );

    test('assigns strictly increasing request ids', () async {
      final ids = <String>[];
      final ctx = await connected(
        httpClient: MockClient((request) async {
          ids.add(request.url.queryParameters['to']!);
          return http.Response('', 200);
        }),
      );
      addTearDown(ctx.provider.close);

      final before = ctx.provider.session!.nextRequestId;
      unawaited(ctx.provider.sendRequest(const DisconnectRequest()));
      await pumpEventQueue();
      final middle = ctx.provider.session!.nextRequestId;
      unawaited(ctx.provider.sendRequest(const DisconnectRequest()));
      await pumpEventQueue();

      expect(middle, greaterThan(before));
      expect(ctx.provider.session!.nextRequestId, greaterThan(middle));
    });

    test('continues the id counter across a restore', () async {
      final storage = InMemoryStorage();
      final first = await connected(storage: storage);
      unawaited(first.provider.sendRequest(const DisconnectRequest()));
      await pumpEventQueue();
      final reached = first.provider.session!.nextRequestId;
      await first.provider.close();

      final second = buildProvider(storage: storage);
      addTearDown(second.provider.close);
      await second.provider.restoreConnection();

      // Restarting at 1 would get every request rejected until the count
      // caught up with what the wallet already saw.
      expect(second.provider.session!.nextRequestId, reached);
    });

    test('refuses to send when no wallet is connected', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);

      await expectLater(
        ctx.provider.sendRequest(const DisconnectRequest()),
        throwsA(isA<WalletNotConnectedError>()),
      );
    });

    test('ignores a response that matches no pending request', () async {
      final ctx = await connected();
      addTearDown(ctx.provider.close);
      final errors = <Object>[];
      ctx.provider.events.listen((_) {}, onError: errors.add);

      ctx.transport.emitMessage(
        ctx.wallet.envelopeFor(
          ctx.provider.session!.clientId,
          ctx.wallet.response('9999'),
        ),
      );
      await pumpEventQueue();

      expect(errors, isEmpty);
    });
  });

  group('BridgeProvider session integrity', () {
    test(
      'ignores a message from a client that is not the session peer',
      () async {
        final ctx = buildProvider();
        addTearDown(ctx.provider.close);
        final wallet = FakeWallet();
        final impostor = FakeWallet();

        await ctx.provider.connect(
          request: request,
          bridgeUrl: bridgeUrl,
          linkBase: unifiedDeepLinkBase,
        );
        final pending = ctx.provider.awaitConnection();
        final clientId = ctx.provider.session!.clientId;
        ctx.transport.emitMessage(
          wallet.envelopeFor(clientId, wallet.connectSuccess()),
        );
        await pending;

        final events = <WalletEvent>[];
        ctx.provider.events.listen(events.add, onError: (_) {});

        // A third party cannot end a session it is not part of.
        ctx.transport.emitMessage(
          impostor.envelopeFor(clientId, impostor.disconnectEvent()),
        );
        await pumpEventQueue();

        expect(events, isEmpty);
        expect(ctx.provider.isConnected, isTrue);
      },
    );

    test('drops a replayed event instead of re-applying it', () async {
      final ctx = buildProvider();
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      final clientId = ctx.provider.session!.clientId;
      ctx.transport.emitMessage(
        wallet.envelopeFor(clientId, wallet.connectSuccess(id: 5)),
      );
      await pending;

      final events = <WalletEvent>[];
      ctx.provider.events.listen(events.add, onError: (_) {});

      // A reconnect replaying from last_event_id can redeliver an older event.
      ctx.transport.emitMessage(
        wallet.envelopeFor(clientId, wallet.disconnectEvent(id: 3)),
      );
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(ctx.provider.isConnected, isTrue);
    });

    test('ends the session on a wallet-initiated disconnect', () async {
      final storage = InMemoryStorage();
      final ctx = buildProvider(storage: storage);
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      final clientId = ctx.provider.session!.clientId;
      ctx.transport.emitMessage(
        wallet.envelopeFor(clientId, wallet.connectSuccess(id: 1)),
      );
      await pending;

      final events = <WalletEvent>[];
      ctx.provider.events.listen(events.add, onError: (_) {});
      ctx.transport.emitMessage(
        wallet.envelopeFor(clientId, wallet.disconnectEvent(id: 2)),
      );
      await pumpEventQueue();

      expect(events.single, isA<DisconnectEvent>());
      expect(ctx.provider.isConnected, isFalse);
      expect(storage.read(bridgeSessionStorageKey), isNull);
    });

    test(
      'reports an undecryptable payload without killing the session',
      () async {
        final ctx = buildProvider();
        addTearDown(ctx.provider.close);
        final wallet = FakeWallet();

        await ctx.provider.connect(
          request: request,
          bridgeUrl: bridgeUrl,
          linkBase: unifiedDeepLinkBase,
        );
        final pending = ctx.provider.awaitConnection();
        final clientId = ctx.provider.session!.clientId;
        ctx.transport.emitMessage(
          wallet.envelopeFor(clientId, wallet.connectSuccess()),
        );
        await pending;

        final errors = <Object>[];
        ctx.provider.events.listen((_) {}, onError: errors.add);

        ctx.transport.emitMessage(
          jsonEncode({
            'from': wallet.clientId,
            'message': 'bm90IGVuY3J5cHRlZA==',
          }),
        );
        await pumpEventQueue();

        expect(errors.single, isA<TonConnectSessionError>());
        expect(ctx.provider.isConnected, isTrue);
      },
    );
  });

  group('BridgeProvider disconnect', () {
    test('clears the stored session', () async {
      final storage = InMemoryStorage();
      final ctx = buildProvider(storage: storage);
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(),
        ),
      );
      await pending;

      await ctx.provider.disconnect();

      expect(ctx.provider.isConnected, isFalse);
      expect(storage.read(bridgeSessionStorageKey), isNull);
    });

    test('ends locally even when the bridge refuses the notice', () async {
      final storage = InMemoryStorage();
      final ctx = buildProvider(
        storage: storage,
        httpClient: MockClient((_) async => http.Response('gone', 502)),
      );
      addTearDown(ctx.provider.close);
      final wallet = FakeWallet();

      await ctx.provider.connect(
        request: request,
        bridgeUrl: bridgeUrl,
        linkBase: unifiedDeepLinkBase,
      );
      final pending = ctx.provider.awaitConnection();
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          ctx.provider.session!.clientId,
          wallet.connectSuccess(),
        ),
      );
      await pending;

      // A wallet that never hears the disconnect must not leave the dApp stuck
      // believing it is still connected.
      await ctx.provider.disconnect();

      expect(ctx.provider.isConnected, isFalse);
      expect(storage.read(bridgeSessionStorageKey), isNull);
    });
  });
}
