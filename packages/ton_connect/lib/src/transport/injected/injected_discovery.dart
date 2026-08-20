import 'injected_bridge.dart';
import 'injected_bridge_stub.dart'
    if (dart.library.js_interop) 'injected_bridge_web.dart';

/// The `window` keys of wallets that injected themselves into this page.
///
/// Empty off the web, and empty in a browser with no wallet present. Match the
/// keys against the `key` of a registry entry's JS bridge to name and draw each
/// one.
List<String> injectedWalletKeys() => findInjectedWalletKeys();

/// Opens the binding a wallet injected under [key], or `null` when there is
/// none.
InjectedBridge? openInjected(String key) => openInjectedBridge(key);

/// Whether any wallet injected itself into this page.
///
/// A dApp opened inside a wallet's browser or a Telegram Mini App should prefer
/// the injected wallet over the QR flow: the wallet is already here, and
/// sending the user out to scan a code would be absurd.
bool get hasInjectedWallet => injectedWalletKeys().isNotEmpty;
