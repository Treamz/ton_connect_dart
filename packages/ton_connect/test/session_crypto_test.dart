import 'dart:convert';

import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

void main() {
  group('SessionCrypto', () {
    test('session id is 64 lowercase hex characters', () {
      final session = SessionCrypto();
      expect(session.sessionId, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('generates a distinct keypair per instance', () {
      expect(SessionCrypto().sessionId, isNot(SessionCrypto().sessionId));
    });

    test('round-trips a message between two parties', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();
      const plaintext = '{"method":"sendTransaction","id":"1"}';

      final encrypted = app.encrypt(plaintext, wallet.sessionId);

      expect(wallet.decrypt(encrypted, app.sessionId), plaintext);
    });

    test('round-trips non-ASCII payloads', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();
      const plaintext = 'Оплата 10 USDT — счёт №42 ✅';

      expect(
        wallet.decrypt(app.encrypt(plaintext, wallet.sessionId), app.sessionId),
        plaintext,
      );
    });

    test('lays the wire format out as nonce ++ ciphertext', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();
      const plaintext = 'hello';

      final raw = base64.decode(app.encrypt(plaintext, wallet.sessionId));

      // 24-byte nonce, then the box: plaintext plus a 16-byte Poly1305 tag.
      expect(raw.length, 24 + plaintext.length + 16);
    });

    test('draws a fresh nonce for every message', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();

      final first = base64.decode(app.encrypt('same', wallet.sessionId));
      final second = base64.decode(app.encrypt('same', wallet.sessionId));

      expect(first.sublist(0, 24), isNot(second.sublist(0, 24)));
      expect(first, isNot(second));
    });

    test('restoring from a secret key preserves the session id', () {
      final original = SessionCrypto();
      final restored = SessionCrypto.fromSecretKey(original.secretKeyHex);

      expect(restored.sessionId, original.sessionId);
    });

    test('a restored session decrypts traffic sent to the original', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();
      final encrypted = wallet.encrypt('resumed', app.sessionId);

      final restored = SessionCrypto.fromSecretKey(app.secretKeyHex);

      expect(restored.decrypt(encrypted, wallet.sessionId), 'resumed');
    });

    test('rejects a message from the wrong sender', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();
      final impostor = SessionCrypto();
      final encrypted = impostor.encrypt('spoofed', app.sessionId);

      expect(
        () => app.decrypt(encrypted, wallet.sessionId),
        throwsA(isA<TonConnectSessionError>()),
      );
    });

    test('rejects tampered ciphertext instead of returning plaintext', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();
      final raw = base64.decode(
        app.encrypt('transfer 1 TON', wallet.sessionId),
      );
      raw[raw.length - 1] ^= 0x01;

      expect(
        () => wallet.decrypt(base64.encode(raw), app.sessionId),
        throwsA(isA<TonConnectSessionError>()),
      );
    });

    test('rejects a payload shorter than the nonce', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();

      expect(
        () => wallet.decrypt(base64.encode(List.filled(24, 0)), app.sessionId),
        throwsA(isA<TonConnectSessionError>()),
      );
    });

    test('rejects malformed base64', () {
      final app = SessionCrypto();
      final wallet = SessionCrypto();

      expect(
        () => wallet.decrypt('not base64!!', app.sessionId),
        throwsA(isA<TonConnectSessionError>()),
      );
    });

    test('rejects a peer client_id of the wrong length', () {
      final app = SessionCrypto();

      expect(
        () => app.encrypt('hello', 'abcdef'),
        throwsA(isA<TonConnectSessionError>()),
      );
    });

    test('rejects a non-hex peer client_id', () {
      final app = SessionCrypto();

      expect(
        () => app.encrypt('hello', 'z' * 64),
        throwsA(isA<TonConnectSessionError>()),
      );
    });

    test('rejects a secret key of the wrong length', () {
      expect(
        () => SessionCrypto.fromSecretKey('00' * 16),
        throwsA(isA<TonConnectSessionError>()),
      );
    });
  });
}
