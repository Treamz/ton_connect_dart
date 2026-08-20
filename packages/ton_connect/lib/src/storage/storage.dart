import 'dart:async';

/// Key-value storage for session state that must outlive the process.
///
/// The core is pure Dart and cannot assume a Flutter plugin, so persistence is
/// the embedder's job. Provide an implementation backed by whatever the host
/// app already uses.
///
/// What gets stored includes the session secret key. Treat it as a credential:
/// anything that can read it can decrypt the session and impersonate the dApp
/// to the wallet. Prefer the platform keystore over plain shared preferences.
abstract interface class TonConnectStorage {
  /// Returns the value for [key], or `null` when absent.
  FutureOr<String?> read(String key);

  /// Stores [value] under [key].
  FutureOr<void> write(String key, String value);

  /// Removes [key], if present.
  FutureOr<void> delete(String key);
}

/// A [TonConnectStorage] that keeps everything in memory.
///
/// Useful in tests and for a deliberately session-scoped connection. Anything
/// stored here is lost on restart, so a real app cannot restore its connection
/// and the user reconnects every launch.
final class InMemoryStorage implements TonConnectStorage {
  /// Creates an empty store.
  InMemoryStorage();

  final Map<String, String> _values = {};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;

  @override
  void delete(String key) => _values.remove(key);
}
