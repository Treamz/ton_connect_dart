import 'package:meta/meta.dart';

/// Where the wallet sends the user after they approve or reject.
///
/// This is the difference between a payment that lands the cashier back in the
/// till app and one that strands them in the wallet.
@immutable
final class ReturnStrategy {
  const ReturnStrategy._(this.value);

  /// Return to whatever opened the wallet. The default.
  static const ReturnStrategy back = ReturnStrategy._('back');

  /// Stay in the wallet after the user acts.
  ///
  /// Right when the dApp is watching the chain rather than waiting on the
  /// wallet's reply — a terminal that confirms from an incoming transaction
  /// does not need the user bounced back.
  static const ReturnStrategy none = ReturnStrategy._('none');

  /// Return to a specific URL.
  ///
  /// A dApp running as a web page SHOULD NOT pass its own page URL here.
  factory ReturnStrategy.url(String url) = ReturnStrategy._;

  /// The wire value for the `ret` parameter.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ReturnStrategy && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ReturnStrategy($value)';
}
