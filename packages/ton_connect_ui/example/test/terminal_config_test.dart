import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:merchant_terminal/terminal_config.dart';

void main() {
  group('merchant address', () {
    test('the shipped placeholder is recognised as one', () {
      // If this ever fails because someone edited the address without
      // clearing the guard, the terminal would start charging to whatever is
      // there — which is the whole thing this check exists to prevent.
      expect(merchantAddressIsPlaceholder, isTrue);
    });

    test('the placeholder really is the burn address', () {
      final raw = base64Url.decode(
        merchantAddress + '=' * ((4 - merchantAddress.length % 4) % 4),
      );
      final account = raw.sublist(2, 34);

      // Workchain 0, account all zeroes: no such contract exists, so anything
      // sent here is destroyed.
      expect(raw[1], 0);
      expect(account.every((byte) => byte == 0), isTrue);
      // Bit 0x40 is the non-bounceable flag — nothing comes back either.
      expect(raw[0] & 0x40, 0x40);
    });
  });
}
