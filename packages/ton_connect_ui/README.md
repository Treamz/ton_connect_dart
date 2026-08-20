# ton_connect_ui

Flutter UI for [TON Connect](https://github.com/ton-blockchain/ton-connect): a wallet-picker modal backed by the public wallet registry, QR and deep-link connect flows, and the widgets around them.

> **Status: early development.** Not yet published. See the [repository README](https://github.com/Treamz/ton_connect_dart) for the roadmap.

```dart
final connection = await showWalletPicker(context: context, ton: ton);
if (connection != null) {
  print('Connected ${connection.account.address}');
}
```

The sheet lists the wallets available on this device, starts the connect, and either opens the wallet app or shows a QR code depending on where the wallet is likely to be. Inside a Telegram Mini App or a wallet's own browser it offers the injected wallet first and connects with no link at all.

## Testing against it

Widget tests that drive `TonConnect` must close it inside the test body, because the bridge keeps a heartbeat watchdog armed and the test binding asserts on any timer that outlives the widget tree. Close it through `tester.runAsync`: a `testWidgets` body runs under fake async, where awaiting a future that completes off the widget pipeline never progresses.

```dart
await tester.runAsync(() => ton.close());
```

`package:ton_connect/testing.dart` provides the fakes for driving a scripted wallet without a network.

## License

MIT
