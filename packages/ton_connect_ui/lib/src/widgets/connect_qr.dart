import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

/// Renders a TON Connect link as a QR code.
///
/// Draws the modules directly rather than rasterising an image, so the code
/// stays crisp at any size and costs one repaint when the link changes.
///
/// Give it the shortest link that reaches the wallet you mean. A connect URL
/// carries the whole `ConnectRequest` as URL-encoded JSON, so a long manifest
/// URL or `ton_proof` payload pushes the code into a higher version with finer
/// modules — which a phone camera has a harder time reading across a shop
/// counter. The unified `tc://` link is the shortest form and reaches every
/// wallet.
class ConnectQr extends StatelessWidget {
  /// Creates a QR view for [link].
  const ConnectQr({
    required this.link,
    super.key,
    this.size = 240,
    this.foreground,
    this.background,
    this.padding = 16,
    this.moduleRadiusFactor = 0.35,
    this.logo,
    this.logoSize = 56,
  });

  /// The link to encode.
  final String link;

  /// Side length of the drawn code, excluding [padding].
  final double size;

  /// Colour of the dark modules. Defaults to the ambient text colour.
  final Color? foreground;

  /// Colour behind the code.
  ///
  /// A QR code needs real contrast with its surroundings. Leave this opaque:
  /// scanners fail on a code painted straight onto a busy background.
  final Color? background;

  /// Quiet zone drawn around the code.
  ///
  /// The standard asks for four modules of margin. Removing it entirely is a
  /// common way to make a code that looks fine and scans badly.
  final double padding;

  /// How round each module is, from 0 (square) to 0.5 (a dot).
  final double moduleRadiusFactor;

  /// Optional widget centred on the code, usually a wallet or TON mark.
  ///
  /// A logo occludes modules, so supplying one raises the error-correction
  /// level to compensate.
  final Widget? logo;

  /// Side length reserved for [logo].
  ///
  /// Keep it small relative to [size]. Even at the highest error-correction
  /// level a logo past roughly a quarter of the width starts costing scans.
  final double logoSize;

  @override
  Widget build(BuildContext context) {
    final resolvedForeground =
        foreground ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF000000);
    final resolvedBackground = background ?? const Color(0xFFFFFFFF);

    final code = QrCode(
      // `fromString` splits the link into the most efficient encoding modes
      // rather than forcing byte mode, which keeps the code a version smaller
      // and its modules that much easier to scan.
      payload: QrPayload.fromString(link),
      // A logo punches a hole in the data; the highest level is what buys the
      // modules back.
      errorCorrectLevel: logo == null
          ? QrErrorCorrectLevel.medium
          : QrErrorCorrectLevel.high,
    );

    return Container(
      width: size + padding * 2,
      height: size + padding * 2,
      padding: EdgeInsets.all(padding),
      color: resolvedBackground,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _QrPainter(
              image: QrImage(code),
              moduleCount: code.moduleCount,
              foreground: resolvedForeground,
              radiusFactor: moduleRadiusFactor.clamp(0, 0.5),
            ),
          ),
          if (logo case final Widget logo)
            Container(
              width: logoSize,
              height: logoSize,
              // The backing square is what keeps the logo readable over dark
              // modules, and marks the occluded area as deliberate.
              padding: const EdgeInsets.all(6),
              color: resolvedBackground,
              child: logo,
            ),
        ],
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter({
    required this.image,
    required this.moduleCount,
    required this.foreground,
    required this.radiusFactor,
  });

  final QrImage image;
  final int moduleCount;
  final Color foreground;
  final double radiusFactor;

  @override
  void paint(Canvas canvas, Size size) {
    final module = size.width / moduleCount;
    final paint = Paint()
      ..color = foreground
      ..isAntiAlias = true;
    final radius = Radius.circular(module * radiusFactor);

    for (var row = 0; row < moduleCount; row++) {
      for (var col = 0; col < moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        // Overdraw each module by a hair. Without it, antialiasing leaves pale
        // seams between neighbours that read as lighter areas to a scanner.
        final rect = Rect.fromLTWH(
          col * module,
          row * module,
          module + 0.5,
          module + 0.5,
        );
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.foreground != foreground ||
      oldDelegate.radiusFactor != radiusFactor;
}
