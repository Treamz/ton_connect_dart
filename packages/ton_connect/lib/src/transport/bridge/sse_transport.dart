import 'sse_event.dart';

/// Opens server-sent event streams for the bridge.
///
/// Implementations differ per platform in a way the gateway must know about:
/// the browser's `EventSource` reconnects on its own and replays via
/// `Last-Event-ID`, while a native HTTP client does not. See
/// [handlesReconnect].
abstract interface class SseTransport {
  /// Subscribes to [url].
  ///
  /// The returned future completes once the connection is established — after
  /// response headers on a native client, on `open` in the browser — and the
  /// stream it yields then carries events. Splitting the two lets a caller
  /// wait until it is genuinely subscribed before it publishes a connect link,
  /// rather than guessing from the first event to arrive.
  ///
  /// The future fails when the connection cannot be established. The stream
  /// completes when the server closes a connection this transport will not
  /// re-establish, and emits an error for a failure the caller must react to.
  /// Cancelling the stream's subscription MUST close the connection.
  ///
  /// [lastEventId] is applied by transports that do not manage their own
  /// replay. Transports that do ignore it, because the browser supplies the
  /// header from its own bookkeeping.
  Future<Stream<SseEvent>> subscribe(Uri url, {String? lastEventId});

  /// Whether this transport re-establishes dropped connections itself.
  ///
  /// When true the gateway must not run its own reconnect loop, or every drop
  /// would open two connections. When false the gateway owns backoff and
  /// `last_event_id` replay.
  bool get handlesReconnect;

  /// Releases any resources this transport owns.
  Future<void> close();
}
