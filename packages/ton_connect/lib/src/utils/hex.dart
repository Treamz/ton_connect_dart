import 'dart:typed_data';

const String _hexDigits = '0123456789abcdef';

/// Encodes [bytes] as lowercase hex.
String hexEncode(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer
      ..write(_hexDigits[(byte >> 4) & 0x0f])
      ..write(_hexDigits[byte & 0x0f]);
  }
  return buffer.toString();
}

/// Decodes a hex string into bytes.
///
/// Accepts upper and lower case. Throws [FormatException] on an odd length or
/// a non-hex character.
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) {
    throw FormatException(
      'Hex string must have an even length',
      hex,
      hex.length,
    );
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final high = _digit(hex, i * 2);
    final low = _digit(hex, i * 2 + 1);
    out[i] = (high << 4) | low;
  }
  return out;
}

int _digit(String hex, int index) {
  final code = hex.codeUnitAt(index);
  if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10; // a-f
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10; // A-F
  throw FormatException('Invalid hex character', hex, index);
}
