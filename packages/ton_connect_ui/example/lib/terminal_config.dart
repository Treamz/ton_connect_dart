import 'package:ton_connect_ui/ton_connect_ui.dart';

/// URL of this terminal's `tonconnect-manifest.json`.
///
/// The wallet fetches it to show the customer who is asking for money, so it
/// has to be publicly reachable. A localhost URL works in a simulator and fails
/// on the customer's phone, which is exactly the wrong place to find out.
const String terminalManifestUrl =
    'https://raw.githubusercontent.com/Treamz/ton_connect_dart/main/'
    'packages/ton_connect_ui/example/tonconnect-manifest.json';

/// Where takings are collected.
///
/// **This is a placeholder and money sent to it is destroyed.** It is the zero
/// address: no such account exists, and the non-bounceable form means nothing
/// comes back. Replace it with the merchant's own address before charging
/// anything. [merchantAddressIsPlaceholder] keeps the terminal from taking a
/// payment until you do.
///
/// Use the **non-bounceable** friendly form for a wallet contract: the bounce
/// flag is read out of the address itself, and a bounceable address would
/// return the payment if the receiving wallet is not deployed yet.
const String merchantAddress =
    'UQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJKZ';

/// Whether [merchantAddress] is still the burn-address placeholder.
///
/// A comment saying "replace this" is not a safeguard. An example that ships
/// pointed at the zero address on mainnet must not be one tap away from
/// destroying real money, so the terminal checks rather than trusts.
bool get merchantAddressIsPlaceholder =>
    merchantAddress == 'UQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJKZ';

/// The network this terminal takes payments on.
///
/// Always sent explicitly. Left unset, the wallet would use whichever network
/// it happens to be on, and a testnet payment would look exactly like a real
/// one on this screen.
const NetworkId terminalNetwork = NetworkId.mainnet;

/// How long the customer has to approve before the request expires.
///
/// A payment request left sitting on a confirmation screen must not still be
/// valid when the customer finds it later.
const Duration paymentWindow = Duration(minutes: 5);

/// What the terminal can charge in.
enum Tender {
  /// Native TON.
  ton('TON', 9),

  /// USDT, the jetton most TON payments are actually denominated in.
  usdt('USDT', 6);

  const Tender(this.label, this.decimals);

  /// Ticker shown on the keypad.
  final String label;

  /// Decimal places this asset uses on chain.
  ///
  /// TON has nine; USDT on TON has six. Getting this wrong overcharges or
  /// undercharges by a factor of a thousand, so it is pinned per tender rather
  /// than assumed.
  final int decimals;
}

/// The USDT jetton master contract on mainnet.
const String usdtMaster = 'EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs';
