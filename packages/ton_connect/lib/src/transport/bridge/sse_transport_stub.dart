import 'sse_transport.dart';

/// Fallback for platforms with neither `dart:io` nor `dart:js_interop`.
///
/// Reaching this means the conditional import found no usable implementation,
/// which no supported Dart platform should do.
SseTransport createPlatformSseTransport() => throw UnsupportedError(
  'No SSE transport is available on this platform: it provides neither '
  'dart:io nor dart:js_interop.',
);
