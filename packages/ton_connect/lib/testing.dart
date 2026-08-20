/// Test doubles for driving TON Connect without a network or a wallet.
///
/// Import this in tests only. It lets a dApp exercise its own connect, send and
/// disconnect flows against a scripted wallet, including the paths that are
/// awkward to reach for real — a declined transaction, a wallet that hangs up,
/// a bridge that drops the connection.
library;

export 'src/testing/fake_injected_bridge.dart';
export 'src/testing/fake_sse_transport.dart';
export 'src/testing/fake_wallet.dart';
