import 'terminal_config.dart';

/// An amount as the cashier typed it.
///
/// Two different precisions meet here and must not be confused. The cashier
/// types a price in cents — two decimal places, like any till. The chain wants
/// the asset's own precision, which is six places for USDT and nine for TON.
/// [units] is where one becomes the other; everything else works in cents.
///
/// Money never touches a `double` on either side. `2.55` has no exact binary
/// floating-point representation, and a terminal that rounds a cent per sale is
/// a terminal that fails reconciliation at the end of the day.
final class TypedAmount {
  /// Creates an empty amount for [tender].
  const TypedAmount(this.tender, [this._digits = '']);

  /// How many decimal places the cashier enters.
  static const int entryDecimals = 2;

  /// What is being charged.
  final Tender tender;

  /// The digits entered so far, most significant first, no separator.
  final String _digits;

  /// Whether nothing has been entered.
  bool get isEmpty => _digits.isEmpty;

  /// The price in cents, exactly as typed.
  BigInt get cents => _digits.isEmpty ? BigInt.zero : BigInt.parse(_digits);

  /// The amount in the asset's smallest on-chain unit.
  ///
  /// Scaling up from cents is exact: every supported asset has at least two
  /// decimal places, so this only ever appends zeros.
  BigInt get units =>
      cents * BigInt.from(10).pow(tender.decimals - entryDecimals);

  /// Appends [digit], ignoring input past a price that still reads as one.
  TypedAmount append(String digit) {
    if (_digits.length >= 11) return this;
    if (_digits.isEmpty && digit == '0') return this;
    return TypedAmount(tender, _digits + digit);
  }

  /// Removes the last digit.
  TypedAmount backspace() => _digits.isEmpty
      ? this
      : TypedAmount(tender, _digits.substring(0, _digits.length - 1));

  /// Clears the amount.
  TypedAmount clear() => TypedAmount(tender);

  /// Switches tender, keeping the price.
  ///
  /// The price is the price: 12.34 stays 12.34 across a tender change, and only
  /// [units] differs, because the two assets carry different precision on
  /// chain.
  TypedAmount withTender(Tender next) => TypedAmount(next, _digits);

  /// The price formatted for the display.
  String get display {
    final padded = _digits.padLeft(entryDecimals + 1, '0');
    final whole = padded.substring(0, padded.length - entryDecimals);
    final fraction = padded.substring(padded.length - entryDecimals);
    return '${_group(whole)}.$fraction';
  }

  static String _group(String whole) {
    final buffer = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(whole[i]);
    }
    return buffer.toString();
  }

  @override
  String toString() => '$display ${tender.label}';
}
