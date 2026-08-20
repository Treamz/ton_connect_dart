import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:merchant_terminal/terminal_config.dart';
import 'package:ton_connect_ui/ton_connect_ui.dart';

void main() {
  group('network and tenders', () {
    test('USDT is only offered where its master contract exists', () {
      // The USDT master is a fixed mainnet address. Offering the tender on
      // another network would build a transfer aimed at a contract that is
      // not there.
      expect(usdtMasterFor(NetworkId.mainnet), isNotNull);
      expect(usdtMasterFor(NetworkId.testnet), isNull);
      expect(tendersFor(NetworkId.mainnet), [Tender.ton, Tender.usdt]);
      expect(tendersFor(NetworkId.testnet), [Tender.ton]);
    });

    test('an unknown network falls back to TON only', () {
      expect(tendersFor(const NetworkId('-42')), [Tender.ton]);
    });

    test('the terminal is configured for testnet', () {
      // Flip this and the assertion above together when going live.
      expect(terminalNetwork.isMainnet, isFalse);
    });
  });

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
