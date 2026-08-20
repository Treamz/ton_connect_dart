import 'package:flutter/foundation.dart';
import 'package:ton_connect/ton_connect.dart';

/// The registry platform matching the device this app is running on.
///
/// Used to filter the wallet picker: offering an iOS-only wallet to an Android
/// user is a dead end, and the registry is explicit about which platforms each
/// wallet ships on.
///
/// On the web this reports [WalletPlatform.chrome] as a stand-in for "a
/// browser". The registry distinguishes Chrome, Firefox and Safari extensions,
/// but a web dApp reaches those through the injected bridge rather than a link,
/// so the distinction does not change what the picker can offer.
WalletPlatform get currentWalletPlatform {
  if (kIsWeb) return WalletPlatform.chrome;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => WalletPlatform.ios,
    TargetPlatform.android => WalletPlatform.android,
    TargetPlatform.macOS => WalletPlatform.macos,
    TargetPlatform.windows => WalletPlatform.windows,
    TargetPlatform.linux || TargetPlatform.fuchsia => WalletPlatform.linux,
  };
}

/// Whether this device can plausibly open a wallet app by tapping a link.
///
/// True on phones, where the wallet is another app on the same device. False on
/// desktop and the web, where the wallet usually lives on the user's phone and
/// the connection starts from a QR code instead.
bool get prefersDeepLink =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);
