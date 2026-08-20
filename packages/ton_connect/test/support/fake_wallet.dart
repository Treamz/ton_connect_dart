import 'dart:convert';

import 'package:ton_connect/ton_connect.dart';

/// Stands in for the wallet side of a session.
///
/// Holds a real [SessionCrypto], so everything it produces is encrypted the
/// way a wallet would encrypt it rather than hand-waved past.
final class FakeWallet {
  FakeWallet() : crypto = SessionCrypto();

  final SessionCrypto crypto;

  String get clientId => crypto.sessionId;

  /// Builds a bridge envelope carrying [payload] encrypted for [dAppClientId].
  String envelopeFor(String dAppClientId, Map<String, Object?> payload) =>
      jsonEncode({
        'from': clientId,
        'message': crypto.encrypt(jsonEncode(payload), dAppClientId),
      });

  /// A `connect` event.
  ///
  /// [features] defaults to a plain `SendTransaction` wallet; pass an explicit
  /// list to model one that advertises more, or less.
  Map<String, Object?> connectSuccess({
    int id = 1,
    String? address,
    String appName = 'tonkeeper',
    List<Map<String, Object?>>? features,
    bool withProof = false,
  }) => {
    'event': 'connect',
    'id': id,
    'payload': {
      'items': [
        {
          'name': 'ton_addr',
          'address': address ?? '0:abc',
          'network': '-239',
          'publicKey': 'ff',
          'walletStateInit': 'te6',
        },
        if (withProof)
          {
            'name': 'ton_proof',
            'proof': {
              'timestamp': '1770000000',
              'domain': {'lengthBytes': 11, 'value': 'example.org'},
              'signature': 'c2ln',
              'payload': 'nonce-1',
            },
          },
      ],
      'device': {
        'platform': 'iphone',
        'appName': appName,
        'appVersion': '5.0.0',
        'maxProtocolVersion': 2,
        'features':
            features ??
            [
              {'name': 'SendTransaction', 'maxMessages': 4},
            ],
      },
    },
  };

  Map<String, Object?> connectError({int id = 1, int code = 300}) => {
    'event': 'connect_error',
    'id': id,
    'payload': {'code': code, 'message': 'User declined the connection'},
  };

  Map<String, Object?> response(String requestId, {String result = 'te6ccg'}) =>
      {'result': result, 'id': requestId};

  Map<String, Object?> errorResponse(
    String requestId, {
    int code = 300,
    String message = 'User declined the transaction',
  }) => {
    'error': {'code': code, 'message': message},
    'id': requestId,
  };

  Map<String, Object?> disconnectEvent({int id = 2}) => {
    'event': 'disconnect',
    'id': id,
    'payload': <String, Object?>{},
  };
}
