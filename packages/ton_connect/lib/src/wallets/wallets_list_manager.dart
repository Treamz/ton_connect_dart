import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ton_connect_error.dart';
import '../models/wallet_app.dart';
import '../storage/storage.dart';

/// The canonical wallets registry.
const String defaultWalletsListUrl =
    'https://raw.githubusercontent.com/ton-connect/wallets-list/main/wallets-v2.json';

/// Storage key holding the last registry successfully fetched.
const String walletsListCacheKey = 'ton_connect:wallets_list';

/// Fetches and caches the public wallets registry.
///
/// The registry is a remote file, which makes it a single point of failure for
/// the wallet picker: a dApp that cannot fetch it has nothing to show. So a
/// successful fetch is cached, and a later failure falls back to that copy
/// rather than leaving the user with an empty list.
final class WalletsListManager {
  /// Creates a manager.
  ///
  /// Pass a storage to make the cache outlive the process. Without one the
  /// cache is per-instance, and a first launch while offline shows nothing.
  WalletsListManager({
    this.url = defaultWalletsListUrl,
    this._storage,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  /// Where the registry is fetched from.
  final String url;

  final TonConnectStorage? _storage;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  List<WalletApp>? _cached;

  /// Returns the registry, fetching it if it has not been loaded yet.
  ///
  /// Set [forceRefresh] to bypass the in-memory copy.
  ///
  /// Throws [WalletsListError] only when the fetch fails and no cached copy
  /// exists anywhere.
  Future<List<WalletApp>> load({bool forceRefresh = false}) async {
    if (!forceRefresh && _cached != null) return _cached!;

    try {
      final response = await _httpClient.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw WalletsListError(
          'The wallets registry returned HTTP ${response.statusCode}.',
        );
      }
      final wallets = _parse(response.body);
      _cached = wallets;
      await _storage?.write(walletsListCacheKey, response.body);
      return wallets;
    } on Object catch (error) {
      final fallback = await _loadCached();
      if (fallback != null) return fallback;
      throw error is WalletsListError
          ? error
          : WalletsListError('Could not fetch the wallets registry: $error');
    }
  }

  Future<List<WalletApp>?> _loadCached() async {
    if (_cached != null) return _cached;
    final raw = await _storage?.read(walletsListCacheKey);
    if (raw == null) return null;
    try {
      return _cached = _parse(raw);
    } on TonConnectError {
      // A cache we can no longer parse is not worth keeping.
      await _storage?.delete(walletsListCacheKey);
      return null;
    }
  }

  /// Parses the registry.
  ///
  /// A malformed entry is skipped rather than failing the whole list: the
  /// registry is community-edited, and one bad entry should not cost the user
  /// every other wallet.
  List<WalletApp> _parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw WalletsListError(
        'The wallets registry is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! List<Object?>) {
      throw const WalletsListError('The wallets registry is not a JSON array.');
    }

    final wallets = <WalletApp>[];
    for (final entry in decoded.whereType<Map<String, Object?>>()) {
      try {
        wallets.add(WalletApp.fromJson(entry));
      } on FormatException {
        continue;
      } on TonConnectParseError {
        continue;
      }
    }

    if (wallets.isEmpty) {
      throw const WalletsListError(
        'The wallets registry contained no usable entries.',
      );
    }
    return List.unmodifiable(wallets);
  }

  /// Returns the wallets available on [platform] that support the HTTP bridge.
  ///
  /// This is what a wallet picker shows. Entries without a bridge and a link
  /// base are dropped: tapping one could not start a connection.
  Future<List<WalletApp>> forPlatform(WalletPlatform platform) async {
    final wallets = await load();
    return List.unmodifiable([
      for (final wallet in wallets)
        if (wallet.platforms.contains(platform) && wallet.supportsBridge)
          wallet,
    ]);
  }

  /// Returns the entry named [appName], or `null` when it is not listed.
  Future<WalletApp?> byAppName(String appName) async {
    for (final wallet in await load()) {
      if (wallet.appName == appName) return wallet;
    }
    return null;
  }

  /// Releases resources this manager owns.
  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}
