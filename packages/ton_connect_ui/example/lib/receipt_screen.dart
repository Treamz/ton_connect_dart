import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ton_connect_ui/ton_connect_ui.dart';

import 'amount.dart';

/// What the terminal shows after the wallet has signed.
class ReceiptScreen extends StatelessWidget {
  /// Creates a receipt.
  const ReceiptScreen({
    required this.amount,
    required this.payer,
    required this.boc,
    required this.oneScan,
    super.key,
  });

  /// What was charged.
  final TypedAmount amount;

  /// The account that paid.
  final Account payer;

  /// Base64 BoC of the external message the wallet broadcast.
  final String boc;

  /// Whether the wallet handled connect and payment in a single approval.
  final bool oneScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                '${amount.display} ${amount.tender.label}',
                style: theme.textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                oneScan ? 'Approved in one scan' : 'Approved',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 32),
            _Row(label: 'From', value: _short(payer.address)),
            _Row(
              label: 'Network',
              value: payer.network.isMainnet
                  ? 'mainnet'
                  : 'global_id ${payer.network.globalId}',
            ),
            const SizedBox(height: 24),

            // The one thing a merchant must not misread on this screen.
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.info_outline, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Not settled yet',
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'The wallet signed and broadcast this payment. That is a '
                      'receipt that it was sent, not proof that it landed. A '
                      'terminal handling real money watches the chain for the '
                      'transaction — and reconciles against it — before handing '
                      'over the goods.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Signed message', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(
              boc.isEmpty ? '(empty)' : boc,
              maxLines: 4,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: boc)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Next customer'),
            ),
          ],
        ),
      ),
    );
  }

  /// Shortens an address for a receipt line.
  static String _short(String address) => address.length <= 16
      ? address
      : '${address.substring(0, 8)}…${address.substring(address.length - 6)}';
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
