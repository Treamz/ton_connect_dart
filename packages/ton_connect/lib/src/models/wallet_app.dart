import 'package:meta/meta.dart';

import 'device_info.dart';

/// A platform a wallet is available on.
enum WalletPlatform {
  /// iOS app.
  ios,

  /// Android app.
  android,

  /// Chrome extension.
  chrome,

  /// Firefox extension.
  firefox,

  /// Safari extension.
  safari,

  /// macOS desktop app.
  macos,

  /// Windows desktop app.
  windows,

  /// Linux desktop app.
  linux;

  /// Parses a platform name, returning `null` for unknown values.
  static WalletPlatform? tryParse(String value) {
    for (final platform in WalletPlatform.values) {
      if (platform.name == value) return platform;
    }
    return null;
  }

  /// Whether this is a phone or tablet platform.
  bool get isMobile => this == ios || this == android;

  /// Whether this is a browser extension.
  bool get isExtension => this == chrome || this == firefox || this == safari;

  /// Whether this is a desktop application.
  bool get isDesktop => this == macos || this == windows || this == linux;
}

/// How a wallet can be reached.
@immutable
sealed class WalletBridge {
  const WalletBridge();
}

/// The wallet is reachable over the encrypted HTTP bridge.
@immutable
final class SseWalletBridge extends WalletBridge {
  /// Creates an SSE bridge entry.
  const SseWalletBridge(this.url);

  /// Base URL of the wallet's bridge.
  final String url;
}

/// The wallet injects a bridge object into the page.
///
/// Used when the dApp runs inside the wallet's own browser, or when the wallet
/// is a browser extension. With a [key] of `tonkeeper`, the bridge object lives
/// at `window.tonkeeper.tonconnect`.
@immutable
final class JsWalletBridge extends WalletBridge {
  /// Creates a JS bridge entry.
  const JsWalletBridge(this.key);

  /// The `window` property the wallet injects itself into.
  final String key;
}

/// One entry from the public wallets registry.
///
/// The [features] here are a static claim about what the wallet binary can do.
/// They are useful for filtering the picker, but they are not authoritative for
/// a live session — the `DeviceInfo.features` the wallet reports on connect is.
/// The specification requires SDKs to refuse a method the runtime features omit
/// even when this entry claims it.
@immutable
final class WalletApp {
  /// Creates a registry entry.
  const WalletApp({
    required this.appName,
    required this.name,
    required this.imageUrl,
    required this.aboutUrl,
    required this.bridges,
    required this.platforms,
    required this.features,
    this.universalUrl,
    this.deepLink,
    this.tonDns,
  });

  /// Parses one registry entry.
  ///
  /// Throws [FormatException] when a required field is missing, so the manager
  /// can skip a single malformed entry instead of failing the whole list.
  factory WalletApp.fromJson(Map<String, Object?> json) {
    final appName = json['app_name'];
    final name = json['name'];
    final image = json['image'];
    final aboutUrl = json['about_url'];
    if (appName is! String || name is! String || image is! String) {
      throw const FormatException(
        'Wallet entry is missing "app_name", "name" or "image".',
      );
    }

    final bridges = <WalletBridge>[];
    final rawBridges = json['bridge'];
    if (rawBridges is List<Object?>) {
      for (final entry in rawBridges.whereType<Map<String, Object?>>()) {
        switch (entry['type']) {
          case 'sse' when entry['url'] is String:
            bridges.add(SseWalletBridge(entry['url']! as String));
          case 'js' when entry['key'] is String:
            bridges.add(JsWalletBridge(entry['key']! as String));
        }
      }
    }
    if (bridges.isEmpty) {
      throw FormatException('Wallet "$appName" lists no usable bridge.');
    }

    final rawPlatforms = json['platforms'];
    final platforms = rawPlatforms is List<Object?>
        ? rawPlatforms
              .whereType<String>()
              .map(WalletPlatform.tryParse)
              .nonNulls
              .toSet()
        : const <WalletPlatform>{};

    final rawFeatures = json['features'];
    final features = rawFeatures is List<Object?>
        ? rawFeatures.map(WalletFeature.fromJson).toList(growable: false)
        : const <WalletFeature>[];

    return WalletApp(
      appName: appName,
      name: name,
      imageUrl: image,
      aboutUrl: aboutUrl is String ? aboutUrl : '',
      bridges: List.unmodifiable(bridges),
      platforms: Set.unmodifiable(platforms),
      features: List.unmodifiable(features),
      universalUrl: json['universal_url'] as String?,
      deepLink: json['deepLink'] as String?,
      tonDns: json['tondns'] as String?,
    );
  }

  /// Wallet identifier, matching the `DeviceInfo.appName` it reports.
  final String appName;

  /// Display name for the wallet picker.
  final String name;

  /// HTTPS URL of the wallet's PNG icon.
  final String imageUrl;

  /// HTTPS URL of the wallet's info page.
  final String aboutUrl;

  /// Ways this wallet can be reached.
  final List<WalletBridge> bridges;

  /// Platforms the wallet runs on.
  final Set<WalletPlatform> platforms;

  /// Statically advertised capabilities. Not authoritative for a live session.
  final List<WalletFeature> features;

  /// HTTPS base for the wallet's universal link.
  ///
  /// Present whenever the wallet offers an SSE bridge. Prefer it over
  /// [deepLink] when jumping to the app: an HTTPS link degrades to a web page
  /// when the wallet is not installed, where a custom scheme dead-ends.
  final String? universalUrl;

  /// Custom-scheme deep link, such as `tonkeeper-tc://`.
  final String? deepLink;

  /// The wallet's TON DNS name. Reserved for future protocol use.
  final String? tonDns;

  /// The wallet's HTTP bridge, when it has one.
  SseWalletBridge? get sseBridge {
    for (final bridge in bridges) {
      if (bridge is SseWalletBridge) return bridge;
    }
    return null;
  }

  /// The wallet's injected bridge, when it has one.
  JsWalletBridge? get jsBridge {
    for (final bridge in bridges) {
      if (bridge is JsWalletBridge) return bridge;
    }
    return null;
  }

  /// The best link base for a bridge connection, or `null` when there is none.
  String? get linkBase => universalUrl ?? deepLink;

  /// Whether this wallet can be connected over the HTTP bridge.
  bool get supportsBridge => sseBridge != null && linkBase != null;

  @override
  String toString() => 'WalletApp($appName)';
}
