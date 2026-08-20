import 'dart:convert';

import '../models/connect_request.dart';
import '../models/return_strategy.dart';

/// The TON Connect protocol version this SDK speaks.
const int protocolVersion = 2;

/// The unified deep link every wallet must accept.
///
/// A single `tc://` link addresses any wallet supporting the unified scheme, so
/// one QR code reaches all of them. Prefer it for QR codes; prefer a wallet's
/// own universal link when the user has already picked a wallet, because an
/// HTTPS link survives a device with no handler installed.
const String unifiedDeepLinkBase = 'tc://';

/// Builds the link that carries a [ConnectRequest] to a wallet.
///
/// [base] is either `tc://` for the unified deep link, or the wallet's
/// `universal_url` or `deepLink` from the registry. [clientId] is the dApp's
/// session `client_id` as hex.
///
/// The request travels in the URL because bridge keys do not exist yet — this
/// is the one message in a session that is not end-to-end encrypted. Never put
/// anything confidential in [request]; a QR code is readable by anyone pointing
/// a camera at it.
String buildConnectLink({
  required String base,
  required String clientId,
  required ConnectRequest request,
  ReturnStrategy? returnStrategy,
  String? traceId,
  String? embeddedRequest,
}) {
  final parameters = <String, String>{
    'v': '$protocolVersion',
    'id': clientId,
    'r': jsonEncode(request.toJson()),
    'ret': ?returnStrategy?.value,
    'trace_id': ?traceId,
    'e': ?embeddedRequest,
  };

  final query = parameters.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');

  // The base may already carry a query, as some wallets' universal URLs do.
  final separator = base.contains('?') ? '&' : '?';
  return '$base$separator$query';
}
