import 'package:meta/meta.dart';

import 'ton_connect_error.dart';

/// Platform the connected wallet application runs on.
enum DevicePlatform {
  /// iPhone.
  iphone,

  /// iPad.
  ipad,

  /// Android phone or tablet.
  android,

  /// Windows desktop.
  windows,

  /// macOS desktop.
  mac,

  /// Linux desktop.
  linux,

  /// Browser extension or web wallet.
  browser;

  /// Parses a platform name from `DeviceInfo.platform`.
  ///
  /// Returns `null` for values this SDK revision does not know, so that a newer
  /// wallet platform degrades to "unknown" instead of failing the connect.
  static DevicePlatform? tryParse(String value) {
    for (final platform in DevicePlatform.values) {
      if (platform.name == value) return platform;
    }
    return null;
  }
}

/// Structured item type a wallet accepts in `sendTransaction` / `signMessage`.
enum TransactionItemType {
  /// A plain TON transfer item.
  ton,

  /// A jetton transfer item.
  jetton,

  /// An NFT transfer item.
  nft;

  /// Parses an item type, returning `null` for unknown values.
  static TransactionItemType? tryParse(String value) {
    for (final type in TransactionItemType.values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// Data type a wallet accepts in `signData`.
enum SignDataType {
  /// UTF-8 text shown to the user verbatim.
  text,

  /// Opaque binary payload.
  binary,

  /// A serialised TON cell.
  cell;

  /// Parses a sign-data type, returning `null` for unknown values.
  static SignDataType? tryParse(String value) {
    for (final type in SignDataType.values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// A capability advertised by the wallet in `DeviceInfo.features`.
///
/// The specification requires SDKs to treat an absent feature as unsupported
/// and refuse to send the corresponding request. Unknown feature names are kept
/// as [UnknownFeature] rather than dropped, so forward-compatible wallets stay
/// inspectable.
@immutable
sealed class WalletFeature {
  const WalletFeature();

  /// The feature name as it appears on the wire.
  String get name;

  /// Parses one entry of the `features` array.
  ///
  /// Older wallets sent bare strings instead of objects; those are surfaced as
  /// [UnknownFeature] carrying the name, since a string entry cannot describe
  /// the parameters this SDK needs to build a valid request.
  factory WalletFeature.fromJson(Object? json) {
    if (json is String) return UnknownFeature(json, const {});
    if (json is! Map<String, Object?>) {
      throw const TonConnectParseError('Feature entry must be an object.');
    }
    final name = json['name'];
    if (name is! String) {
      throw const TonConnectParseError(
        'Feature entry is missing a string "name".',
      );
    }
    return switch (name) {
      'SendTransaction' => SendTransactionFeature(
        maxMessages: _requireInt(json, 'maxMessages'),
        extraCurrencySupported: json['extraCurrencySupported'] == true,
        itemTypes: _itemTypes(json['itemTypes']),
      ),
      'SignMessage' => SignMessageFeature(
        maxMessages: _requireInt(json, 'maxMessages'),
        extraCurrencySupported: json['extraCurrencySupported'] == true,
        itemTypes: _itemTypes(json['itemTypes']),
      ),
      'SignData' => SignDataFeature(
        types: switch (json['types']) {
          final List<Object?> raw =>
            raw.whereType<String>().map(SignDataType.tryParse).nonNulls.toSet(),
          _ => const <SignDataType>{},
        },
      ),
      'EmbeddedRequest' => const EmbeddedRequestFeature(),
      _ => UnknownFeature(name, json),
    };
  }

  static int _requireInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is int) return value;
    throw TonConnectParseError(
      'Feature "${json['name']}" is missing integer "$key".',
    );
  }

  static Set<TransactionItemType>? _itemTypes(Object? raw) {
    // Absent `itemTypes` means "raw messages only" and is meaningfully
    // different from an empty list, so it stays null.
    if (raw is! List<Object?>) return null;
    return raw
        .whereType<String>()
        .map(TransactionItemType.tryParse)
        .nonNulls
        .toSet();
  }
}

/// The wallet can process `sendTransaction`.
final class SendTransactionFeature extends WalletFeature {
  /// Creates a `SendTransaction` feature descriptor.
  const SendTransactionFeature({
    required this.maxMessages,
    this.extraCurrencySupported = false,
    this.itemTypes,
  });

  @override
  String get name => 'SendTransaction';

  /// Maximum number of messages accepted in a single transaction.
  final int maxMessages;

  /// Whether the wallet supports extra currencies.
  final bool extraCurrencySupported;

  /// Structured item types the wallet accepts.
  ///
  /// `null` means the wallet predates structured items and accepts only the raw
  /// `messages` array.
  final Set<TransactionItemType>? itemTypes;
}

/// The wallet can process `signMessage`.
final class SignMessageFeature extends WalletFeature {
  /// Creates a `SignMessage` feature descriptor.
  const SignMessageFeature({
    required this.maxMessages,
    this.extraCurrencySupported = false,
    this.itemTypes,
  });

  @override
  String get name => 'SignMessage';

  /// Maximum number of messages accepted in a single request.
  final int maxMessages;

  /// Whether the wallet supports extra currencies.
  final bool extraCurrencySupported;

  /// Structured item types the wallet accepts, or `null` for raw messages only.
  final Set<TransactionItemType>? itemTypes;
}

/// The wallet can process `signData`.
final class SignDataFeature extends WalletFeature {
  /// Creates a `SignData` feature descriptor.
  const SignDataFeature({required this.types});

  @override
  String get name => 'SignData';

  /// Payload types the wallet is willing to sign.
  final Set<SignDataType> types;
}

/// The wallet can process an embedded request carried in the connect URL.
final class EmbeddedRequestFeature extends WalletFeature {
  /// Creates an `EmbeddedRequest` feature descriptor.
  const EmbeddedRequestFeature();

  @override
  String get name => 'EmbeddedRequest';
}

/// A feature this SDK revision does not model, preserved verbatim.
final class UnknownFeature extends WalletFeature {
  /// Creates an unknown feature carrying its raw [json].
  const UnknownFeature(this.name, this.json);

  @override
  final String name;

  /// The raw feature object as received.
  final Map<String, Object?> json;
}

/// Metadata describing the wallet application on the other side of the session.
@immutable
final class DeviceInfo {
  /// Creates device info.
  const DeviceInfo({
    required this.platform,
    required this.rawPlatform,
    required this.appName,
    required this.appVersion,
    required this.maxProtocolVersion,
    required this.features,
  });

  /// Parses `DeviceInfo` from the connect event payload.
  factory DeviceInfo.fromJson(Map<String, Object?> json) {
    final rawPlatform = json['platform'];
    if (rawPlatform is! String) {
      throw const TonConnectParseError(
        'DeviceInfo is missing a string "platform".',
      );
    }
    final rawFeatures = json['features'];
    return DeviceInfo(
      platform: DevicePlatform.tryParse(rawPlatform),
      rawPlatform: rawPlatform,
      appName: json['appName'] as String? ?? '',
      appVersion: json['appVersion'] as String? ?? '',
      maxProtocolVersion: json['maxProtocolVersion'] as int? ?? 2,
      features: rawFeatures is List<Object?>
          ? List<WalletFeature>.unmodifiable(
              rawFeatures.map(WalletFeature.fromJson),
            )
          : const <WalletFeature>[],
    );
  }

  /// The wallet's platform, or `null` if unrecognised — see [rawPlatform].
  final DevicePlatform? platform;

  /// The platform string exactly as sent by the wallet.
  final String rawPlatform;

  /// The wallet's `app_name` from the wallets registry.
  final String appName;

  /// The wallet application version.
  final String appVersion;

  /// Highest TON Connect protocol version the wallet supports.
  final int maxProtocolVersion;

  /// Capabilities advertised by the wallet.
  final List<WalletFeature> features;

  /// Returns the advertised feature of type [T], or `null` when absent.
  T? feature<T extends WalletFeature>() {
    for (final feature in features) {
      if (feature is T) return feature;
    }
    return null;
  }

  /// Whether the wallet advertises a feature of type [T].
  bool supports<T extends WalletFeature>() => feature<T>() != null;

  @override
  String toString() => 'DeviceInfo($appName $appVersion on $rawPlatform)';
}
