/// The wallet object a wallet injects into the page.
///
/// Mirrors the `TonConnectBridge` interface from the specification, reduced to
/// decoded JSON so the provider above it is ordinary Dart and testable off the
/// browser.
///
/// Unlike the HTTP bridge, this carries no encryption: the dApp and the wallet
/// are the same device and there is no untrusted relay between them. There are
/// no session keys here, and nothing to persist — the binding either exists in
/// the page or it does not.
abstract interface class InjectedBridge {
  /// The `window` property the wallet injected itself into.
  String get key;

  /// Highest TON Connect protocol version the wallet supports.
  int get protocolVersion;

  /// Whether the page is open inside the wallet's own browser.
  ///
  /// True inside a wallet webview or a Telegram Mini App opened by the wallet;
  /// false for a browser extension on an ordinary page.
  bool get isWalletBrowser;

  /// Wallet-initiated events — the decoded `WalletEvent` objects.
  Stream<Map<String, Object?>> get events;

  /// Sends a connect request, returning the decoded `ConnectEvent`.
  Future<Map<String, Object?>> connect(
    int protocolVersion,
    Map<String, Object?> request,
  );

  /// Attempts to restore a prior approval, returning the decoded `ConnectEvent`.
  ///
  /// Returns a `connect_error` with code 100 when the wallet does not recognise
  /// the dApp. Unlike [connect] this needs no user gesture, which is why it is
  /// the right call on startup.
  Future<Map<String, Object?>> restoreConnection();

  /// Sends an `AppRequest`, returning the decoded `WalletResponse`.
  Future<Map<String, Object?>> send(Map<String, Object?> request);

  /// Stops listening to the wallet.
  Future<void> close();
}
