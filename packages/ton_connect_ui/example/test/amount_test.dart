import 'package:flutter_test/flutter_test.dart';
import 'package:merchant_terminal/amount.dart';
import 'package:merchant_terminal/terminal_config.dart';

/// Types [keys] into a fresh amount.
TypedAmount type(String keys, {Tender tender = Tender.usdt}) {
  var amount = TypedAmount(tender);
  for (final key in keys.split('')) {
    amount = amount.append(key);
  }
  return amount;
}

void main() {
  group('TypedAmount entry', () {
    test('starts empty', () {
      const amount = TypedAmount(Tender.usdt);

      expect(amount.isEmpty, isTrue);
      expect(amount.units, BigInt.zero);
      expect(amount.display, '0.00');
    });

    test('fills from the right, like a till', () {
      expect(type('1').display, '0.01');
      expect(type('12').display, '0.12');
      expect(type('123').display, '1.23');
      expect(type('12345').display, '123.45');
    });

    test('ignores a leading zero', () {
      // Otherwise the keypad accumulates zeros that shift nothing.
      expect(type('0').isEmpty, isTrue);
      expect(type('001').display, '0.01');
    });

    test('groups thousands', () {
      expect(type('123456789').display, '1 234 567.89');
    });

    test('backspaces', () {
      expect(type('12345').backspace().display, '12.34');
    });

    test('backspacing an empty amount is a no-op', () {
      expect(const TypedAmount(Tender.usdt).backspace().isEmpty, isTrue);
    });

    test('clears', () {
      expect(type('12345').clear().isEmpty, isTrue);
    });

    test('stops accepting digits past a price that still reads as one', () {
      final long = type('9' * 40);

      expect(long.display.replaceAll(RegExp(r'[ .]'), '').length, lessThan(40));
    });
  });

  group('TypedAmount units', () {
    test('scales a typed price to USDT elementary units', () {
      // The cashier types 12.34; USDT carries six decimals, so 12_340_000.
      expect(type('1234').units, BigInt.from(12340000));
    });

    test('scales the same price to TON nanocoins', () {
      // 2.50 TON is 2_500_000_000 nanocoins — the same keystrokes, a different
      // number on chain, which is the whole reason units and cents are
      // separate.
      final amount = type('250', tender: Tender.ton);

      expect(amount.display, '2.50');
      expect(amount.units, BigInt.from(2500000000));
    });

    test('keeps exact minor units for an amount a double would mangle', () {
      // 2.55 has no exact binary floating-point representation. Rounding it
      // even once per sale is what breaks end-of-day reconciliation, so the
      // amount never leaves integer arithmetic.
      final amount = type('255');

      expect(amount.display, '2.55');
      expect(amount.cents, BigInt.from(255));
      expect(amount.units, BigInt.from(2550000));
    });

    test('scales the largest enterable price exactly', () {
      // This terminal caps entry below what a signed 64-bit integer holds, so
      // the width is not what forces BigInt here. Correctness is: the scaling
      // is exact rather than approximate, and a jetton carrying more decimals
      // than TON would leave 64 bits behind entirely.
      final largest = type('9' * 11, tender: Tender.ton);

      expect(largest.display, '999 999 999.99');
      expect(largest.units, BigInt.parse('99999999999${'0' * 7}'));
    });
  });

  group('TypedAmount tender', () {
    test('switching tender keeps the price and rescales the units', () {
      final usdt = type('1234');
      final ton = usdt.withTender(Tender.ton);

      // The price is the price. Only the on-chain representation changes.
      expect(usdt.display, '12.34');
      expect(ton.display, '12.34');
      expect(usdt.units, BigInt.from(12340000));
      expect(ton.units, BigInt.from(12340000000));
    });

    test('reports the tender it was built with', () {
      expect(type('1', tender: Tender.ton).tender, Tender.ton);
    });

    test('renders as amount and ticker', () {
      expect(type('1234').toString(), '12.34 USDT');
    });
  });

  group('Tender', () {
    test('pins the on-chain decimals per asset', () {
      // Nine for TON, six for USDT. Assuming one for the other is a factor of a
      // thousand in the customer's favour, or the merchant's.
      expect(Tender.ton.decimals, 9);
      expect(Tender.usdt.decimals, 6);
    });
  });
}
