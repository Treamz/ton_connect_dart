import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ton_connect/testing.dart';
import 'package:ton_connect_ui/ton_connect_ui.dart';

final Map<String, Object?> tonkeeperEntry = {
  'app_name': 'tonkeeper',
  'name': 'Tonkeeper',
  'image': 'https://example.org/tonkeeper.png',
  'about_url': 'https://tonkeeper.com',
  'universal_url': 'https://app.tonkeeper.com/ton-connect',
  'bridge': [
    {'type': 'sse', 'url': 'https://bridge.example.org/bridge'},
  ],
  'platforms': ['ios', 'android', 'macos', 'windows', 'linux', 'chrome'],
  'features': [
    {'name': 'SendTransaction', 'maxMessages': 4},
  ],
};

Map<String, Object?> entryNamed(String name) => {
  ...tonkeeperEntry,
  'app_name': name.toLowerCase(),
  'name': name,
};

({TonConnect ton, FakeSseTransport transport}) buildClient({
  List<Map<String, Object?>>? registry,
  int registryStatus = 200,
}) {
  final transport = FakeSseTransport();
  final ton = TonConnect(
    manifestUrl: 'https://example.org/tonconnect-manifest.json',
    storage: InMemoryStorage(),
    transport: transport,
    httpClient: MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode(registry ?? [tonkeeperEntry]),
          registryStatus,
        );
      }
      return http.Response('', 200);
    }),
  );
  return (ton: ton, transport: transport);
}

Future<void> pumpSheet(WidgetTester tester, TonConnect ton) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: WalletPickerSheet(ton: ton)),
    ),
  );
  await tester.pump();
}

/// Advances a fixed number of frames.
///
/// `pumpAndSettle` is unusable on this screen: every waiting state shows a
/// progress indicator, which schedules frames forever, so settling never
/// happens and the pump spins until its ten-minute timeout.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Closes [ton] and drains the frames its teardown schedules.
///
/// Two constraints meet here. The bridge gateway keeps a heartbeat watchdog
/// armed while a session is open, and the widget-test binding asserts if any
/// timer outlives the tree — so closing cannot wait for a tearDown callback,
/// which runs after that check. But a `testWidgets` body runs under fake async,
/// where awaiting a future that completes off the widget pipeline never
/// progresses: even a bare broadcast `StreamController.close()` hangs there.
/// `runAsync` steps out to the real event loop, which is where the close
/// actually completes.
Future<void> closeClient(WidgetTester tester, TonConnect ton) async {
  await tester.runAsync(() => ton.close());
  await tester.pump();
}

void main() {
  // The wallet tiles load their icons with Image.network. The test binding
  // already answers those with an immediate 400, so the tiles fall back to
  // initials. Clearing HttpOverrides here would send them at the real network
  // and hang the suite.

  group('WalletPickerSheet listing', () {
    testWidgets('shows a spinner while the registry loads', (tester) async {
      final ctx = buildClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WalletPickerSheet(ton: ctx.ton)),
        ),
      );

      expect(find.text('Loading wallets…'), findsOneWidget);
      await settle(tester);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('lists the wallets for this platform', (tester) async {
      final ctx = buildClient(
        registry: [entryNamed('Tonkeeper'), entryNamed('MyTonWallet')],
      );

      await pumpSheet(tester, ctx.ton);
      await settle(tester);

      expect(find.text('Tonkeeper'), findsOneWidget);
      expect(find.text('MyTonWallet'), findsOneWidget);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('offers a retry when the registry cannot be loaded', (
      tester,
    ) async {
      final ctx = buildClient(registryStatus: 503);

      await pumpSheet(tester, ctx.ton);
      await settle(tester);

      expect(
        find.textContaining('Could not load the wallet list'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('says so when no wallet fits this platform', (tester) async {
      final ctx = buildClient(
        registry: [
          {
            ...tonkeeperEntry,
            'platforms': const <String>['fuchsia-only'],
          },
        ],
      );

      await pumpSheet(tester, ctx.ton);
      await settle(tester);

      expect(
        find.text('No compatible wallet is available on this device.'),
        findsOneWidget,
      );

      await closeClient(tester, ctx.ton);
    });
  });

  group('WalletPickerSheet connecting', () {
    testWidgets('shows a QR once a wallet is picked', (tester) async {
      final ctx = buildClient();
      await pumpSheet(tester, ctx.ton);
      await settle(tester);

      await tester.tap(find.text('Tonkeeper'));
      await settle(tester);

      expect(find.byType(ConnectQr), findsOneWidget);
      expect(find.text('Waiting for approval…'), findsOneWidget);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('titles the connecting view with the wallet name', (
      tester,
    ) async {
      final ctx = buildClient();
      await pumpSheet(tester, ctx.ton);
      await settle(tester);

      await tester.tap(find.text('Tonkeeper'));
      await settle(tester);

      // The header replaces the generic prompt, so the user can see which
      // wallet the code is for.
      expect(find.text('Connect a wallet'), findsNothing);
      expect(find.text('Tonkeeper'), findsOneWidget);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('goes back to the list', (tester) async {
      final ctx = buildClient();
      await pumpSheet(tester, ctx.ton);
      await settle(tester);
      await tester.tap(find.text('Tonkeeper'));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle(tester);

      expect(find.text('Connect a wallet'), findsOneWidget);
      expect(find.byType(ConnectQr), findsNothing);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('returns the connection once the wallet approves', (
      tester,
    ) async {
      final ctx = buildClient();
      final wallet = FakeWallet();
      WalletConnection? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showWalletPicker(
                    context: context,
                    ton: ctx.ton,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.text('Tonkeeper'));
      await settle(tester);

      // The wallet answers on the bridge.
      ctx.transport.emitMessage(
        wallet.envelopeFor(
          _clientId(ctx.transport),
          wallet.connectSuccess(address: '0:cafe'),
        ),
      );
      await settle(tester);

      expect(result?.account.address, '0:cafe');
      expect(find.byType(WalletPickerSheet), findsNothing);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('reports a decline as a choice, not a crash', (tester) async {
      final ctx = buildClient();
      final wallet = FakeWallet();
      await pumpSheet(tester, ctx.ton);
      await settle(tester);
      await tester.tap(find.text('Tonkeeper'));
      await settle(tester);

      ctx.transport.emitMessage(
        wallet.envelopeFor(_clientId(ctx.transport), wallet.connectError()),
      );
      await settle(tester);

      expect(
        find.text('The connection was declined in the wallet.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await closeClient(tester, ctx.ton);
    });

    testWidgets('copies the link to the clipboard', (tester) async {
      final ctx = buildClient();
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );

      await pumpSheet(tester, ctx.ton);
      await settle(tester);
      await tester.tap(find.text('Tonkeeper'));
      await settle(tester);
      await tester.tap(find.text('Copy link'));
      await settle(tester);

      expect(
        copied.single,
        startsWith('https://app.tonkeeper.com/ton-connect?'),
      );

      await closeClient(tester, ctx.ton);
    });
  });
}

String _clientId(FakeSseTransport transport) =>
    transport.requestedUrls.last.queryParameters['client_id']!;
