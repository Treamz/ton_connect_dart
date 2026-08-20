import 'package:test/test.dart';
import 'package:ton_connect/testing.dart';
import 'package:ton_connect/ton_connect.dart';

const ConnectRequest request = ConnectRequest(
  manifestUrl: 'https://example.org/tonconnect-manifest.json',
  items: [TonAddressItem()],
);

/// Builds a connected provider over [bridge].
Future<InjectedProvider> connected(FakeInjectedBridge bridge) async {
  bridge.connectResponse = FakeWallet().connectSuccess();
  final provider = InjectedProvider(bridge);
  await provider.connect(request);
  return provider;
}

void main() {
  group('InjectedProvider connect', () {
    test('returns the connected account', () async {
      final bridge = FakeInjectedBridge()
        ..connectResponse = FakeWallet().connectSuccess(address: '0:deadbeef');
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      final event = await provider.connect(request);

      expect(event.account?.address, '0:deadbeef');
      expect(event.device.appName, 'tonkeeper');
      expect(provider.isConnected, isTrue);
    });

    test(
      'passes the request and the wallet protocol version through',
      () async {
        final bridge = FakeInjectedBridge()
          ..connectResponse = FakeWallet().connectSuccess();
        final provider = InjectedProvider(bridge);
        addTearDown(provider.close);

        await provider.connect(request);

        expect(bridge.connectRequests.single, {
          'manifestUrl': 'https://example.org/tonconnect-manifest.json',
          'items': [
            {'name': 'ton_addr'},
          ],
        });
      },
    );

    test('throws when the user declines', () async {
      final bridge = FakeInjectedBridge()
        ..connectResponse = FakeWallet().connectError();
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      await expectLater(
        provider.connect(request),
        throwsA(isA<UserDeclinedError>()),
      );
      expect(provider.isConnected, isFalse);
    });

    test('exposes the wallet key and browser flag', () {
      final bridge = FakeInjectedBridge(
        key: 'mytonwallet',
        isWalletBrowser: false,
      );
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      expect(provider.key, 'mytonwallet');
      expect(provider.isWalletBrowser, isFalse);
    });
  });

  group('InjectedProvider restoreConnection', () {
    test('returns the connection the wallet still remembers', () async {
      final bridge = FakeInjectedBridge()
        ..restoreResponse = FakeWallet().connectSuccess(address: '0:restored');
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      final event = await provider.restoreConnection();

      expect(event?.account?.address, '0:restored');
      expect(provider.isConnected, isTrue);
    });

    test('returns null when the wallet does not know the dApp', () async {
      // Code 100 is how a wallet says "I have not approved you" — the ordinary
      // answer on a first visit, not a failure to report.
      final bridge = FakeInjectedBridge()
        ..restoreResponse = FakeWallet().connectError(code: 100);
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      expect(await provider.restoreConnection(), isNull);
      expect(provider.isConnected, isFalse);
    });

    test('still throws on a decline that is not UNKNOWN_APP', () async {
      final bridge = FakeInjectedBridge()
        ..restoreResponse = FakeWallet().connectError(code: 300);
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      await expectLater(
        provider.restoreConnection(),
        throwsA(isA<UserDeclinedError>()),
      );
    });
  });

  group('InjectedProvider requests', () {
    test('sends the request and returns the wallet response', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);

      final response = await provider.sendRequest(
        SendTransactionRequest(
          TransactionPayload.messages([
            TransactionMessage(address: 'EQAa', amount: BigInt.from(1000)),
          ], network: NetworkId.mainnet),
        ),
      );

      expect(bridge.sentRequests.single['method'], 'sendTransaction');
      expect(response, isA<WalletResponseSuccess>());
      expect((response as WalletResponseSuccess).resultString, 'te6ccg');
    });

    test('assigns strictly increasing request ids', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);

      await provider.sendRequest(const DisconnectRequest());
      await provider.sendRequest(const DisconnectRequest());

      final ids = bridge.sentRequests
          .map((r) => int.parse(r['id']! as String))
          .toList();
      expect(ids[1], greaterThan(ids[0]));
    });

    test('refuses to send before connecting', () async {
      final provider = InjectedProvider(FakeInjectedBridge());
      addTearDown(provider.close);

      await expectLater(
        provider.sendRequest(const DisconnectRequest()),
        throwsA(isA<WalletNotConnectedError>()),
      );
    });

    test('rejects a response answering a different request', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      // The JS bridge resolves each call with its own answer, so a mismatched
      // id means the wallet confused two requests.
      bridge.onSend = (_) => {'result': 'te6', 'id': '999'};

      await expectLater(
        provider.sendRequest(const DisconnectRequest()),
        throwsA(isA<TonConnectParseError>()),
      );
    });

    test('surfaces a wallet error response', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      bridge.onSend = (request) =>
          FakeWallet().errorResponse(request['id']! as String);

      final response = await provider.sendRequest(const DisconnectRequest());

      expect(response, isA<WalletResponseError>());
      expect((response as WalletResponseError).error, isA<UserDeclinedError>());
    });

    test('propagates a bridge failure', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      bridge.failNextWith = const TonConnectBridgeError('wallet went away');

      await expectLater(
        provider.sendRequest(const DisconnectRequest()),
        throwsA(isA<TonConnectBridgeError>()),
      );
    });
  });

  group('InjectedProvider events', () {
    test('ends the session on a wallet-initiated disconnect', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      final events = <WalletEvent>[];
      provider.events.listen(events.add, onError: (_) {});

      bridge.emit(FakeWallet().disconnectEvent(id: 2));
      await pumpEventQueue();

      expect(events.single, isA<DisconnectEvent>());
      expect(provider.isConnected, isFalse);
    });

    test('ignores an event that does not advance the counter', () async {
      final bridge = FakeInjectedBridge();
      // The connect event set the baseline at id 1.
      final provider = await connected(bridge);
      addTearDown(provider.close);
      final events = <WalletEvent>[];
      provider.events.listen(events.add, onError: (_) {});

      bridge.emit(FakeWallet().disconnectEvent(id: 1));
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(provider.isConnected, isTrue);
    });

    test('reports an event with no integer id', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      final errors = <Object>[];
      provider.events.listen((_) {}, onError: errors.add);

      bridge.emit({'event': 'disconnect', 'payload': <String, Object?>{}});
      await pumpEventQueue();

      expect(errors.single, isA<TonConnectParseError>());
    });

    test('reports an event type it does not know', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      final errors = <Object>[];
      provider.events.listen((_) {}, onError: errors.add);

      bridge.emit({
        'event': 'somethingNew',
        'id': 9,
        'payload': <String, Object?>{},
      });
      await pumpEventQueue();

      expect(errors.single, isA<TonConnectParseError>());
    });
  });

  group('InjectedProvider disconnect', () {
    test('tells the wallet and clears the connection', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);

      await provider.disconnect();

      expect(bridge.sentRequests.single['method'], 'disconnect');
      expect(provider.isConnected, isFalse);
    });

    test('clears the connection even when the wallet refuses', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);
      addTearDown(provider.close);
      bridge.failNextWith = const TonConnectBridgeError('gone');

      await provider.disconnect();

      expect(provider.isConnected, isFalse);
    });

    test('is a no-op when nothing is connected', () async {
      final bridge = FakeInjectedBridge();
      final provider = InjectedProvider(bridge);
      addTearDown(provider.close);

      await provider.disconnect();

      expect(bridge.sentRequests, isEmpty);
    });

    test('closing releases the bridge', () async {
      final bridge = FakeInjectedBridge();
      final provider = await connected(bridge);

      await provider.close();

      expect(bridge.closed, isTrue);
    });
  });

  group('injected discovery', () {
    test('finds no injected wallet off the web', () {
      // Native platforms reach wallets over the HTTP bridge; reporting an empty
      // page here is the correct answer, not an error.
      expect(injectedWalletKeys(), isEmpty);
      expect(hasInjectedWallet, isFalse);
      expect(openInjected('tonkeeper'), isNull);
    });
  });
}
