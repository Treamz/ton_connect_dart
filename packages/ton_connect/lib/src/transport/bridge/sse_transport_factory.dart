import 'sse_transport.dart';
import 'sse_transport_stub.dart'
    if (dart.library.io) 'sse_transport_io.dart'
    if (dart.library.js_interop) 'sse_transport_web.dart';

/// Creates the [SseTransport] appropriate for the current platform.
///
/// Resolves to an HTTP-client transport on native platforms and an
/// `EventSource` transport on the web.
SseTransport createSseTransport() => createPlatformSseTransport();
