// Connects a TON wallet from the console and asks it to pay.
//
// Run it with `dart run example/main.dart`. It prints a connect link, waits for
// a wallet to answer, then requests a small transfer. Paste the link into a
// phone, or render it as a QR code — `package:ton_connect_ui` does that part
// for Flutter apps.
//
// Nothing here is Flutter-specific: the same code runs in a server, a CLI, or
// a bot.
import 'dart:io';

import 'package:ton_connect/ton_connect.dart';

/// Where the wallet fetches this app's identity from.
///
/// It must be publicly reachable — the wallet, not this program, downloads it,
/// so a localhost URL fails on the user's phone.
const String manifestUrl =
    'https://raw.githubusercontent.com/Treamz/ton_connect_dart/main/'
    'packages/ton_connect_ui/example/tonconnect-manifest.json';

/// Where to send the demonstration payment.
///
/// Replace with your own address in the non-bounceable friendly form — the one
/// starting `UQ`. The address below is deliberately obvious nonsense so that a
/// copy-paste run cannot move real money.
const String recipient = 'UQ_REPLACE_WITH_YOUR_OWN_ADDRESS';

Future<void> main() async {
  final ton = TonConnect(
    manifestUrl: manifestUrl,
    // A real app stores sessions somewhere durable and private: the session
    // secret key lives here, and anything holding it can impersonate this app
    // to the wallet. In memory means the user reconnects every run.
    storage: InMemoryStorage(),
  );

  try {
    final wallet = await _chooseWallet(ton);
    if (wallet == null) return;

    // The bridge subscription is live before this returns, so the wallet's
    // answer cannot arrive unheard.
    final link = await ton.connect(wallet);
    stdout
      ..writeln('\nOpen this in ${wallet.name}, or show it as a QR code:\n')
      ..writeln(link)
      ..writeln('\nWaiting for approval…');

    final connection = await ton.awaitConnection();
    stdout
      ..writeln('Connected ${connection.account.address}')
      ..writeln(
        'Wallet: ${connection.device.appName} '
        '${connection.device.appVersion}',
      );

    await _pay(ton, connection);
  } on UserDeclinedError {
    // Declining is an ordinary outcome, not a failure to report as one.
    stdout.writeln('The user declined.');
  } on TonConnectError catch (error) {
    stderr.writeln('TON Connect failed: ${error.message}');
    exitCode = 1;
  } finally {
    await ton.close();
  }
}

/// Lists the wallets available on a phone and takes a pick.
Future<WalletApp?> _chooseWallet(TonConnect ton) async {
  final wallets = await ton.availableWallets(WalletPlatform.ios);
  if (wallets.isEmpty) {
    stderr.writeln('The registry listed no usable wallet.');
    return null;
  }

  stdout.writeln('Wallets:');
  for (var i = 0; i < wallets.length; i++) {
    stdout.writeln('  ${i + 1}. ${wallets[i].name}');
  }
  stdout.write('Pick one [1]: ');

  final answer = stdin.readLineSync()?.trim() ?? '';
  final index = answer.isEmpty ? 1 : int.tryParse(answer) ?? 0;
  if (index < 1 || index > wallets.length) {
    stderr.writeln('That is not one of the wallets listed.');
    return null;
  }
  return wallets[index - 1];
}

/// Asks the connected wallet for a small transfer.
Future<void> _pay(TonConnect ton, WalletConnection connection) async {
  if (recipient.startsWith('UQ_REPLACE')) {
    stdout.writeln('\nSet `recipient` to your own address to try a payment.');
    return;
  }

  // The wallet's own features decide what it will accept. This SDK refuses a
  // method the wallet did not advertise before anything goes over the wire, so
  // checking here only makes the reason friendlier.
  if (!connection.device.supports<SendTransactionFeature>()) {
    stdout.writeln('\n${connection.device.appName} cannot send transactions.');
    return;
  }

  stdout.writeln('\nAsking for 0.01 TON. Approve it in the wallet…');
  final boc = await ton.sendTransaction(
    TransactionPayload.messages(
      [
        TransactionMessage(
          address: recipient,
          // Nanocoins. 0.01 TON, kept as an integer — a payment amount should
          // never go through a double.
          amount: BigInt.from(10000000),
        ),
      ],
      // Always explicit. Left unset, the wallet uses whichever network it is
      // on, and a testnet payment looks exactly like a real one from here.
      network: connection.account.network,
      // A request left on a confirmation screen must not still be valid when
      // the user finds it an hour later.
      validUntil: DateTime.now().add(const Duration(minutes: 5)),
    ),
  );

  stdout
    ..writeln('Broadcast: $boc')
    ..writeln(
      '\nThat is a receipt that the wallet sent it, not that it landed. '
      'Anything holding real money should watch the chain for the '
      'transaction before treating the payment as settled.',
    );
}
