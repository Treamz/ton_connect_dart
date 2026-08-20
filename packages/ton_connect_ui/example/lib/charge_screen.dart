import 'package:flutter/material.dart';
import 'package:ton_connect_ui/ton_connect_ui.dart';

import 'amount.dart';
import 'receipt_screen.dart';
import 'terminal_config.dart';

/// The till: enter an amount, pick a tender, take the payment.
class ChargeScreen extends StatefulWidget {
  /// Creates the till screen.
  const ChargeScreen({required this.ton, super.key});

  /// The client this terminal takes payments through.
  final TonConnect ton;

  @override
  State<ChargeScreen> createState() => _ChargeScreenState();
}

class _ChargeScreenState extends State<ChargeScreen> {
  TypedAmount _amount = const TypedAmount(Tender.usdt);
  bool _charging = false;

  /// Builds the payment the customer is about to approve.
  ///
  /// A jetton goes as a structured item so the wallet can show "10 USDT" rather
  /// than an opaque cell, and so it computes the TON needed to carry the
  /// transfer itself. Native TON goes as a raw message, which every wallet
  /// accepts.
  TransactionPayload _payload() {
    final expiry = DateTime.now().add(paymentWindow);
    return switch (_amount.tender) {
      Tender.ton => TransactionPayload.messages(
        [TransactionMessage(address: merchantAddress, amount: _amount.units)],
        network: terminalNetwork,
        validUntil: expiry,
      ),
      Tender.usdt => TransactionPayload.items(
        [
          JettonTransferItem(
            master: usdtMaster,
            destination: merchantAddress,
            amount: _amount.units,
          ),
        ],
        network: terminalNetwork,
        validUntil: expiry,
      ),
    };
  }

  Future<void> _charge() async {
    final payload = _payload();
    setState(() => _charging = true);

    try {
      // The payment rides along in the connect link, so a wallet advertising
      // EmbeddedRequest asks the customer once instead of twice. Wallets
      // without the feature ignore it and the fallback below takes over.
      final connection = await showWalletPicker(
        context: context,
        ton: widget.ton,
        embeddedRequest: EmbeddedRequest.sendTransaction(payload),
      );
      if (connection == null || !mounted) return;

      final embedded = connection.embeddedResponse;
      final boc = embedded != null
          ? _bocFrom(embedded)
          // The wallet connected but did not act on the embedded request, so
          // ask over the bridge. The customer approves a second time.
          : await widget.ton.sendTransaction(payload, ttl: paymentWindow);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReceiptScreen(
            amount: _amount,
            payer: connection.account,
            boc: boc,
            oneScan: embedded != null,
          ),
        ),
      );
      if (mounted) setState(() => _amount = _amount.clear());
    } on UserDeclinedError {
      _say('The customer declined the payment.');
    } on FeatureNotSupportedError catch (error) {
      _say(error.message);
    } on TonConnectError catch (error) {
      _say(error.message);
    } finally {
      if (mounted) setState(() => _charging = false);
      // Each sale is its own session: a terminal must not stay connected to one
      // customer's wallet while the next customer steps up.
      await widget.ton.disconnect();
    }
  }

  /// Reads the BoC out of the wallet's embedded response.
  static String _bocFrom(Map<String, Object?> response) {
    if (response['error'] case final Map<String, Object?> error) {
      throw TonConnectProtocolError.fromCode(
        error['code'] as int? ?? 0,
        error['message'] as String? ?? 'The wallet refused the payment.',
      );
    }
    return response['result'] as String? ?? '';
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Charge')),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            Text(
              _amount.display,
              style: theme.textTheme.displayMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<Tender>(
              segments: [
                for (final tender in Tender.values)
                  ButtonSegment(value: tender, label: Text(tender.label)),
              ],
              selected: {_amount.tender},
              onSelectionChanged: (selected) =>
                  setState(() => _amount = _amount.withTender(selected.first)),
            ),
            const Spacer(),
            _Keypad(
              onDigit: (d) => setState(() => _amount = _amount.append(d)),
              onBackspace: () => setState(() => _amount = _amount.backspace()),
              onClear: () => setState(() => _amount = _amount.clear()),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _amount.isEmpty || _charging ? null : _charge,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                  ),
                  child: Text(
                    _charging ? 'Waiting…' : 'Take payment',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.onDigit,
    required this.onBackspace,
    required this.onClear,
  });

  final void Function(String digit) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '<'],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          for (final row in rows)
            Row(
              children: [
                for (final key in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: _Key(
                        label: key,
                        onPressed: switch (key) {
                          'C' => onClear,
                          '<' => onBackspace,
                          _ => () => onDigit(key),
                        },
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18),
      ),
      child: Text(label, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}
