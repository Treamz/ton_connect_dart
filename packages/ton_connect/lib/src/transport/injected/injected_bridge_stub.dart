import 'injected_bridge.dart';

/// No wallet can inject itself outside a browser.
///
/// Native platforms reach wallets over the HTTP bridge instead, so this
/// reports an empty page rather than failing: "no injected wallet here" is the
/// correct answer on iOS, not an error.
List<String> findInjectedWalletKeys() => const [];

/// Always `null` off the web.
InjectedBridge? openInjectedBridge(String key) => null;
