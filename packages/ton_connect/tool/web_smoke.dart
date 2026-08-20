// A compile-only smoke test for the web target.
//
// The browser transports — `EventSource` for the bridge and the injected
// `window.<wallet>.tonconnect` binding — are selected by conditional import and
// never execute under the VM, so no amount of `dart test` touches them. This
// entrypoint exists so CI can compile them with dart2js: a js_interop signature
// that stopped matching, or a conditional import that quietly fell back to the
// stub, fails the build here instead of in someone's browser.
//
// It is never run. Every call is here to keep the compiler from tree-shaking
// away the code being checked.
library;

import 'package:ton_connect/ton_connect.dart';

Future<void> main() async {
  final ton = TonConnect(
    manifestUrl: 'https://example.org/tonconnect-manifest.json',
  );

  for (final key in ton.injectedWallets) {
    final connection = await ton.connectInjected(key);
    print(connection.account.address);
  }

  if (await ton.restoreConnection()) {
    print(
      await ton.sendTransaction(
        TransactionPayload.messages([
          TransactionMessage(address: 'EQAa', amount: BigInt.one),
        ], network: NetworkId.mainnet),
      ),
    );
  }

  for (final wallet in await ton.availableWallets(WalletPlatform.chrome)) {
    print(await ton.connect(wallet, returnStrategy: ReturnStrategy.back));
  }

  // Exercise the bridge transport directly: the facade reaches it through a
  // gateway, and this keeps the EventSource path itself alive in the output.
  final transport = createSseTransport();
  final events = await transport.subscribe(
    Uri.parse('https://bridge.example.org/bridge/events'),
  );
  events.listen((event) => print(event.data));

  await ton.disconnect();
  await ton.close();
}
