import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ton_connect/ton_connect.dart';
import 'package:url_launcher/url_launcher.dart';

import '../current_platform.dart';
import 'connect_qr.dart';
import 'wallet_tile.dart';

/// Opens the wallet picker and returns the connection the user established.
///
/// Returns `null` when the user dismisses the sheet without connecting.
///
/// The sheet drives [ton] itself: it lists wallets from the registry, starts
/// the connect, and either opens the wallet app or shows a QR code depending on
/// the device. When a wallet is injected into the page — a Telegram Mini App or
/// a wallet's own browser — it is offered first and connects without any link
/// at all.
Future<WalletConnection?> showWalletPicker({
  required BuildContext context,
  required TonConnect ton,
  String? proofPayload,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<WalletConnection>(
    context: context,
    isScrollControlled: isScrollControlled,
    builder: (context) =>
        WalletPickerSheet(ton: ton, proofPayload: proofPayload),
  );
}

/// The wallet picker itself.
///
/// Prefer [showWalletPicker]; use this directly to embed the picker somewhere
/// other than a modal sheet.
class WalletPickerSheet extends StatefulWidget {
  /// Creates a picker driving [ton].
  const WalletPickerSheet({required this.ton, super.key, this.proofPayload});

  /// The client to connect.
  final TonConnect ton;

  /// Challenge for a `ton_proof` item, when the dApp authenticates the user.
  final String? proofPayload;

  @override
  State<WalletPickerSheet> createState() => _WalletPickerSheetState();
}

class _WalletPickerSheetState extends State<WalletPickerSheet> {
  late Future<List<WalletApp>> _wallets;
  List<String> _injected = const [];

  WalletApp? _pending;
  String? _link;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _injected = widget.ton.injectedWallets;
    _wallets = widget.ton.availableWallets(currentWalletPlatform);
  }

  Future<void> _connectInjected(String key) async {
    setState(() {
      _error = null;
      _link = null;
    });
    try {
      final connection = await widget.ton.connectInjected(key);
      if (mounted) Navigator.of(context).pop(connection);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _connect(WalletApp wallet) async {
    setState(() {
      _pending = wallet;
      _error = null;
      _link = null;
    });

    final String link;
    try {
      link = await widget.ton.connect(
        wallet,
        proofPayload: widget.proofPayload,
        // Bring the user back to this app once they have approved, rather than
        // leaving them looking at their wallet wondering what happened.
        returnStrategy: ReturnStrategy.back,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
      return;
    }

    if (!mounted) return;
    setState(() => _link = link);

    // On a phone the wallet is another app here, so jump straight to it. On
    // desktop and the web it is on the user's phone, and the QR is the only way
    // across.
    if (prefersDeepLink) {
      unawaited(_open(link));
    }

    try {
      final connection = await widget.ton.awaitConnection();
      if (mounted) Navigator.of(context).pop(connection);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _open(String link) async {
    try {
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } on Object {
      // A missing handler is not fatal: the QR stays on screen, and the user
      // can scan it from another device.
    }
  }

  void _back() {
    setState(() {
      _pending = null;
      _link = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              title: _pending == null ? 'Connect a wallet' : _pending!.name,
              onBack: _pending == null ? null : _back,
            ),
            Flexible(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_error case final Object error) {
      return _ErrorView(error: error, onRetry: _pending == null ? null : _back);
    }
    if (_pending != null) {
      return _link == null
          ? const _Busy(label: 'Preparing the connection…')
          : _ConnectingView(link: _link!, onOpen: () => _open(_link!));
    }
    return _walletList();
  }

  Widget _walletList() {
    return FutureBuilder<List<WalletApp>>(
      future: _wallets,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _ErrorView(error: snapshot.error!, onRetry: _reload);
        }
        if (!snapshot.hasData) {
          return const _Busy(label: 'Loading wallets…');
        }

        final wallets = snapshot.data!;
        if (wallets.isEmpty && _injected.isEmpty) {
          return const _Empty();
        }

        return ListView(
          shrinkWrap: true,
          children: [
            for (final key in _injected)
              ListTile(
                onTap: () => _connectInjected(key),
                leading: const Icon(Icons.extension_outlined),
                title: Text(_nameFor(key, wallets)),
                subtitle: const Text('Already here — connects without a QR'),
              ),
            if (_injected.isNotEmpty) const Divider(height: 1),
            for (final wallet in wallets)
              WalletTile(wallet: wallet, onTap: () => _connect(wallet)),
          ],
        );
      },
    );
  }

  /// Names an injected wallet from the registry, falling back to its key.
  ///
  /// A wallet can inject itself before the registry lists it, which is exactly
  /// when a raw key is better than hiding the wallet the user already has.
  String _nameFor(String key, List<WalletApp> wallets) {
    for (final wallet in wallets) {
      if (wallet.jsBridge?.key == key || wallet.appName == key) {
        return wallet.name;
      }
    }
    return key;
  }

  void _reload() {
    setState(() {
      _wallets = widget.ton.wallets
          .load(forceRefresh: true)
          .then((_) => widget.ton.availableWallets(currentWalletPlatform));
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          if (onBack case final VoidCallback onBack)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back',
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({required this.link, required this.onOpen});

  final String link;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectQr(link: link),
          const SizedBox(height: 16),
          Text(
            'Scan with your wallet, or open it on this device.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open wallet'),
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: link)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy link'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _Busy(label: 'Waiting for approval…', compact: true),
        ],
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label, this.compact = false});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
    return compact
        ? row
        : Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: row),
          );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _describe(error),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (onRetry case final VoidCallback onRetry) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }

  /// Turns an error into something a user can act on.
  ///
  /// A declined connection is not a failure and must not read like one — the
  /// user did that on purpose.
  static String _describe(Object error) => switch (error) {
    UserDeclinedError() => 'The connection was declined in the wallet.',
    WalletsListError() =>
      'Could not load the wallet list. Check your connection and try again.',
    TonConnectBridgeError() =>
      'Could not reach the wallet bridge. Check your connection and try again.',
    TonConnectError(:final message) => message,
    _ => 'Something went wrong connecting to the wallet.',
  };
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        'No compatible wallet is available on this device.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}
