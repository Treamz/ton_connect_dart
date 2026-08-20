/// A TON network identifier — the stringified network `global_id`.
///
/// The protocol carries this on every `network` field. [mainnet] and [testnet]
/// name the two baseline values, but any TON network `global_id` is valid and
/// MUST be passed through verbatim, so this is a thin wrapper over the raw
/// string rather than a closed enum.
extension type const NetworkId._(String _value) implements Object {
  /// Wraps a stringified TON network `global_id`.
  ///
  /// Any value is accepted. The protocol names two networks but requires SDKs
  /// to pass any other `global_id` through unchanged.
  const NetworkId(String globalId) : this._(globalId);

  /// The TON mainnet, `global_id` `-239`.
  static const NetworkId mainnet = NetworkId('-239');

  /// The TON testnet, `global_id` `-3`.
  static const NetworkId testnet = NetworkId('-3');

  /// The network's `global_id`, exactly as it travels on the wire.
  String get globalId => _value;

  /// Whether this identifies the TON mainnet.
  bool get isMainnet => globalId == mainnet.globalId;

  /// Whether this identifies the TON testnet.
  bool get isTestnet => globalId == testnet.globalId;
}
