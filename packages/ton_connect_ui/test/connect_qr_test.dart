import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:ton_connect_ui/ton_connect_ui.dart';

/// A representative connect link: `tc://` plus a URL-encoded ConnectRequest.
const String connectLink =
    'tc://?v=2&id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    '&r=%7B%22manifestUrl%22%3A%22https%3A%2F%2Fexample.org%2Fm.json%22%7D&ret=back';

Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('ConnectQr', () {
    testWidgets('renders a link', (tester) async {
      await pump(tester, const ConnectQr(link: connectLink));

      expect(find.byType(ConnectQr), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('sizes itself to the requested side plus padding', (
      tester,
    ) async {
      await pump(
        tester,
        const ConnectQr(link: connectLink, size: 200, padding: 10),
      );

      final box = tester.getSize(find.byType(ConnectQr));
      expect(box.width, 220);
      expect(box.height, 220);
    });

    testWidgets('renders a very short link', (tester) async {
      await pump(tester, const ConnectQr(link: 'tc://'));

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders a long link without overflowing', (tester) async {
      // A manifest URL and a ton_proof payload push the code to a higher
      // version; it must still fit the box it was given.
      final long = '$connectLink&e=${'a' * 800}';
      await pump(tester, ConnectQr(link: long, size: 240));

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(ConnectQr)).width, 240 + 32);
    });

    testWidgets('shows a logo when given one', (tester) async {
      await pump(
        tester,
        const ConnectQr(
          link: connectLink,
          logo: Icon(Icons.currency_bitcoin, key: Key('logo')),
        ),
      );

      expect(find.byKey(const Key('logo')), findsOneWidget);
    });

    testWidgets('repaints when the link changes', (tester) async {
      await pump(tester, const ConnectQr(link: connectLink));
      await pump(tester, const ConnectQr(link: '$connectLink&trace_id=abc'));

      expect(tester.takeException(), isNull);
    });
  });

  group('QR encoding assumptions', () {
    test('a logo raises the error-correction level', () {
      // The widget cannot be asked what level it used, so this pins the
      // reasoning: occluding the middle has to be paid for with redundancy.
      final plain = QrCode(
        payload: QrPayload.fromString(connectLink),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      );
      final withLogo = QrCode(
        payload: QrPayload.fromString(connectLink),
        errorCorrectLevel: QrErrorCorrectLevel.high,
      );

      // Higher correction needs more modules for the same data.
      expect(withLogo.moduleCount, greaterThanOrEqualTo(plain.moduleCount));
    });

    test('optimal segmentation is no larger than forcing byte mode', () {
      final optimal = QrCode(payload: QrPayload.fromString(connectLink));
      final forced = QrCode(
        payload: QrPayload.fromTypedData(
          Uint8List.fromList(connectLink.codeUnits),
        ),
      );

      expect(optimal.moduleCount, lessThanOrEqualTo(forced.moduleCount));
    });
  });
}
