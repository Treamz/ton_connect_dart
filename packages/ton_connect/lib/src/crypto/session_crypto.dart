import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pinenacl/x25519.dart'
    show Box, EncryptedMessage, PrivateKey, PublicKey;

import '../models/ton_connect_error.dart';
import '../utils/hex.dart';

/// The X25519 keypair backing one TON Connect session.
///
/// Per the session specification each side generates one keypair per session.
/// The public key, hex-encoded, is the `client_id` used to address the peer on
/// the HTTP bridge; the secret key never leaves the device.
///
/// A session is the pair of two `client_id` values. Generating a new keypair
/// therefore starts a new session — restoring a persisted connection MUST reuse
/// the stored secret key, which is what [SessionCrypto.fromSecretKey] is for.
@immutable
final class SessionCrypto {
  /// Generates a fresh session keypair from the platform's secure RNG.
  SessionCrypto() : this._(PrivateKey.generate());

  /// Restores a session keypair from a previously persisted secret key.
  ///
  /// [secretKeyHex] must be the 64-character hex encoding of the 32-byte
  /// X25519 secret key, as returned by [secretKeyHex].
  factory SessionCrypto.fromSecretKey(String secretKeyHex) {
    final Uint8List bytes;
    try {
      bytes = hexDecode(secretKeyHex);
    } on FormatException catch (e) {
      throw TonConnectSessionError(
        'Session secret key is not valid hex: ${e.message}',
      );
    }
    if (bytes.length != _keyLength) {
      throw TonConnectSessionError(
        'Session secret key must be $_keyLength bytes, got ${bytes.length}.',
      );
    }
    return SessionCrypto._(PrivateKey(bytes));
  }

  SessionCrypto._(this._privateKey);

  static const int _keyLength = 32;
  static const int _nonceLength = 24;

  final PrivateKey _privateKey;

  /// This session's `client_id`: the 64-character lowercase hex encoding of the
  /// 32-byte X25519 public key.
  String get sessionId => hexEncode(Uint8List.fromList(_privateKey.publicKey));

  /// The 32-byte X25519 secret key as lowercase hex.
  ///
  /// Persist this to restore the session after a restart. Treat it as a
  /// credential: anything holding it can decrypt the session's traffic.
  String get secretKeyHex => hexEncode(Uint8List.fromList(_privateKey));

  /// Encrypts [message] for the peer identified by [receiverClientId].
  ///
  /// Returns the base64 encoding of `nonce ++ ciphertext`, ready to be used as
  /// the body of `POST /message`. A fresh 24-byte nonce is drawn per call.
  String encrypt(String message, String receiverClientId) {
    final box = _boxFor(receiverClientId);
    final encrypted = box.encrypt(Uint8List.fromList(utf8.encode(message)));
    // `EncryptedMessage` is laid out as nonce ++ ciphertext, which is exactly
    // the `M` of the session spec — no reassembly needed.
    return base64.encode(Uint8List.fromList(encrypted));
  }

  /// Decrypts a base64 `nonce ++ ciphertext` payload from [senderClientId].
  ///
  /// Throws [TonConnectSessionError] if the payload is malformed or fails
  /// authentication. A failure means the message MUST be discarded — never
  /// fall back to treating it as plaintext.
  String decrypt(String encodedMessage, String senderClientId) {
    final Uint8List raw;
    try {
      raw = base64.decode(encodedMessage);
    } on FormatException catch (e) {
      throw TonConnectSessionError(
        'Bridge message is not valid base64: ${e.message}',
      );
    }
    if (raw.length <= _nonceLength) {
      throw TonConnectSessionError(
        'Bridge message is truncated: ${raw.length} bytes, '
        'need more than $_nonceLength.',
      );
    }

    final box = _boxFor(senderClientId);
    try {
      // `EncryptedMessage.fromList` splits `M` at the 24-byte nonce boundary,
      // which is the layout the session spec mandates.
      final plaintext = box.decrypt(EncryptedMessage.fromList(raw));
      return utf8.decode(plaintext);
    } on Object catch (e) {
      // Deliberately broad: pinenacl signals a failed Poly1305 check by
      // throwing a bare String, not an Exception, so `on Exception` would let
      // authentication failures escape uncaught. Every failure here means the
      // same thing — the message is unauthenticated and must be discarded.
      throw TonConnectSessionError('Failed to decrypt bridge message: $e');
    }
  }

  Box _boxFor(String peerClientId) {
    final Uint8List peerKey;
    try {
      peerKey = hexDecode(peerClientId);
    } on FormatException catch (e) {
      throw TonConnectSessionError(
        'Peer client_id is not valid hex: ${e.message}',
      );
    }
    if (peerKey.length != _keyLength) {
      throw TonConnectSessionError(
        'Peer client_id must decode to $_keyLength bytes, got ${peerKey.length}.',
      );
    }
    return Box(myPrivateKey: _privateKey, theirPublicKey: PublicKey(peerKey));
  }

  @override
  String toString() => 'SessionCrypto(sessionId: $sessionId)';
}
