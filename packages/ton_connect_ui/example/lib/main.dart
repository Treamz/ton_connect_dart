import 'package:flutter/material.dart';
import 'package:ton_connect_ui/ton_connect_ui.dart';

import 'charge_screen.dart';
import 'terminal_config.dart';

void main() => runApp(const MerchantTerminalApp());

/// A point-of-sale terminal for TON.
///
/// The cashier enters an amount, the customer scans one code, and the wallet
/// approves the connection and the payment together. That single scan is what
/// the `EmbeddedRequest` feature buys — without it the customer approves twice,
/// which at a counter is the difference between a queue moving and a queue
/// waiting.
class MerchantTerminalApp extends StatefulWidget {
  /// Creates the app.
  const MerchantTerminalApp({super.key});

  @override
  State<MerchantTerminalApp> createState() => _MerchantTerminalAppState();
}

class _MerchantTerminalAppState extends State<MerchantTerminalApp> {
  late final TonConnect _ton;

  @override
  void initState() {
    super.initState();
    _ton = TonConnect(
      manifestUrl: terminalManifestUrl,
      // A real terminal must persist sessions somewhere durable, and somewhere
      // private: the session secret key lives here. See the note in
      // TonConnectStorage.
      storage: InMemoryStorage(),
    );
  }

  @override
  void dispose() {
    _ton.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Merchant Terminal',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0098EA),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF0098EA),
        brightness: Brightness.dark,
      ),
      home: ChargeScreen(ton: _ton),
    );
  }
}
