import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

/// A snapshot of the real published registry.
///
/// Parsing the actual file, rather than a hand-written sample, is what catches
/// a shape this SDK assumed but the registry never had.
late final String realRegistry;

/// Locates the fixture without depending on the working directory.
///
/// `dart test packages/ton_connect` from the workspace root runs with the root
/// as the working directory, so a path relative to the package would not
/// resolve. Going through the package URI works from either.
Future<String> _loadFixture(String name) async {
  final packageUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ton_connect/ton_connect.dart'),
  );
  if (packageUri == null) {
    throw StateError('Could not resolve the ton_connect package URI.');
  }
  return File.fromUri(
    packageUri.resolve('../test/fixtures/$name'),
  ).readAsString();
}

String registryOf(List<Map<String, Object?>> entries) => jsonEncode(entries);

Map<String, Object?> entry({
  String appName = 'tonkeeper',
  String name = 'Tonkeeper',
  List<Map<String, Object?>>? bridge,
  List<String> platforms = const ['ios', 'android'],
  String? universalUrl = 'https://app.tonkeeper.com/ton-connect',
  String? deepLink,
}) => {
  'app_name': appName,
  'name': name,
  'image': 'https://example.org/icon.png',
  'about_url': 'https://example.org',
  'bridge':
      bridge ??
      [
        {'type': 'sse', 'url': 'https://bridge.example.org/bridge'},
      ],
  'platforms': platforms,
  'features': [
    {'name': 'SendTransaction', 'maxMessages': 4},
  ],
  'universal_url': ?universalUrl,
  'deepLink': ?deepLink,
};

WalletsListManager managerFor(
  String body, {
  int status = 200,
  TonConnectStorage? storage,
}) => WalletsListManager(
  storage: storage,
  httpClient: MockClient((_) async => http.Response(body, status)),
);

void main() {
  setUpAll(() async {
    realRegistry = await _loadFixture('wallets-v2.json');
  });

  group('WalletsListManager parsing', () {
    test('parses every entry of the published registry', () async {
      final wallets = await managerFor(realRegistry).load();

      expect(wallets, hasLength(35));
      expect(wallets.map((w) => w.appName), contains('tonkeeper'));
    });

    test('reads Tonkeeper out of the published registry', () async {
      final manager = managerFor(realRegistry);

      final tonkeeper = await manager.byAppName('tonkeeper');

      expect(tonkeeper, isNotNull);
      expect(tonkeeper!.name, 'Tonkeeper');
      expect(tonkeeper.sseBridge, isNotNull);
      expect(tonkeeper.universalUrl, isNotNull);
      expect(tonkeeper.supportsBridge, isTrue);
      expect(tonkeeper.platforms, contains(WalletPlatform.ios));
    });

    test('recognises both bridge kinds in the published registry', () async {
      final wallets = await managerFor(realRegistry).load();

      expect(wallets.where((w) => w.sseBridge != null), hasLength(30));
      expect(wallets.where((w) => w.jsBridge != null), hasLength(23));
    });

    test('parses an injected bridge key', () async {
      final wallets = await managerFor(
        registryOf([
          entry(
            bridge: [
              {'type': 'js', 'key': 'tonkeeper'},
            ],
            universalUrl: null,
          ),
        ]),
      ).load();

      expect(wallets.single.jsBridge?.key, 'tonkeeper');
    });

    test('keeps a wallet listing both bridges', () async {
      final wallets = await managerFor(
        registryOf([
          entry(
            bridge: [
              {'type': 'sse', 'url': 'https://bridge.example.org/bridge'},
              {'type': 'js', 'key': 'tonkeeper'},
            ],
          ),
        ]),
      ).load();

      expect(wallets.single.sseBridge, isNotNull);
      expect(wallets.single.jsBridge, isNotNull);
    });

    test('skips a malformed entry rather than losing the whole list', () async {
      final wallets = await managerFor(
        registryOf([
          {'name': 'Broken', 'image': 'https://example.org/i.png'},
          entry(appName: 'good', name: 'Good'),
        ]),
      ).load();

      // The registry is community-edited; one bad entry must not cost the user
      // every other wallet.
      expect(wallets, hasLength(1));
      expect(wallets.single.appName, 'good');
    });

    test('skips an entry with no usable bridge', () async {
      final wallets = await managerFor(
        registryOf([
          entry(appName: 'bridgeless', bridge: const []),
          entry(appName: 'fine'),
        ]),
      ).load();

      expect(wallets.map((w) => w.appName), ['fine']);
    });

    test('ignores platforms it does not recognise', () async {
      final wallets = await managerFor(
        registryOf([
          entry(platforms: const ['ios', 'holographic-visor']),
        ]),
      ).load();

      expect(wallets.single.platforms, {WalletPlatform.ios});
    });

    test('rejects a registry that is not JSON', () async {
      await expectLater(
        managerFor('<html>404</html>').load(),
        throwsA(isA<WalletsListError>()),
      );
    });

    test('rejects a registry that is not an array', () async {
      await expectLater(
        managerFor('{"wallets": []}').load(),
        throwsA(isA<WalletsListError>()),
      );
    });

    test('rejects a registry with no usable entries', () async {
      await expectLater(
        managerFor(registryOf([])).load(),
        throwsA(isA<WalletsListError>()),
      );
    });

    test('reports a failed fetch', () async {
      await expectLater(
        managerFor('', status: 503).load(),
        throwsA(isA<WalletsListError>()),
      );
    });
  });

  group('WalletsListManager caching', () {
    test('serves a cached copy when the network fails', () async {
      final storage = InMemoryStorage();
      await managerFor(realRegistry, storage: storage).load();

      // A new manager, now offline, must still be able to show a picker.
      final offline = WalletsListManager(
        storage: storage,
        httpClient: MockClient(
          (_) async => throw http.ClientException('offline'),
        ),
      );

      expect(await offline.load(), hasLength(35));
    });

    test('reuses the in-memory copy instead of refetching', () async {
      var fetches = 0;
      final manager = WalletsListManager(
        httpClient: MockClient((_) async {
          fetches++;
          return http.Response(realRegistry, 200);
        }),
      );

      await manager.load();
      await manager.load();

      expect(fetches, 1);
    });

    test('refetches when asked to', () async {
      var fetches = 0;
      final manager = WalletsListManager(
        httpClient: MockClient((_) async {
          fetches++;
          return http.Response(realRegistry, 200);
        }),
      );

      await manager.load();
      await manager.load(forceRefresh: true);

      expect(fetches, 2);
    });

    test(
      'discards an unparseable cache instead of serving it forever',
      () async {
        final storage = InMemoryStorage()
          ..write(walletsListCacheKey, 'garbage');
        final manager = WalletsListManager(
          storage: storage,
          httpClient: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );

        await expectLater(manager.load(), throwsA(isA<WalletsListError>()));
        expect(storage.read(walletsListCacheKey), isNull);
      },
    );
  });

  group('WalletsListManager filtering', () {
    test('returns only wallets for the requested platform', () async {
      final manager = managerFor(
        registryOf([
          entry(appName: 'mobile', platforms: const ['ios', 'android']),
          entry(appName: 'desktop', platforms: const ['macos']),
        ]),
      );

      final wallets = await manager.forPlatform(WalletPlatform.ios);

      expect(wallets.map((w) => w.appName), ['mobile']);
    });

    test('drops wallets that cannot start a bridge connection', () async {
      final manager = managerFor(
        registryOf([
          entry(appName: 'linkable'),
          // An extension with only a JS bridge cannot be reached by a link.
          entry(
            appName: 'extension-only',
            bridge: [
              {'type': 'js', 'key': 'ext'},
            ],
            universalUrl: null,
          ),
        ]),
      );

      final wallets = await manager.forPlatform(WalletPlatform.ios);

      expect(wallets.map((w) => w.appName), ['linkable']);
    });

    test(
      'accepts a deep link as the link base when there is no universal URL',
      () async {
        final manager = managerFor(
          registryOf([entry(universalUrl: null, deepLink: 'tonkeeper-tc://')]),
        );

        final wallets = await manager.forPlatform(WalletPlatform.ios);

        expect(wallets.single.linkBase, 'tonkeeper-tc://');
      },
    );

    test('prefers the universal URL over the deep link', () async {
      final manager = managerFor(
        registryOf([
          entry(
            universalUrl: 'https://app.tonkeeper.com/ton-connect',
            deepLink: 'tonkeeper-tc://',
          ),
        ]),
      );

      // An HTTPS link degrades to a web page when the wallet is missing; a
      // custom scheme dead-ends.
      expect(
        (await manager.load()).single.linkBase,
        'https://app.tonkeeper.com/ton-connect',
      );
    });

    test('finds nothing for an app name that is not listed', () async {
      expect(await managerFor(realRegistry).byAppName('nope'), isNull);
    });
  });
}
