import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../models/ton_connect_error.dart';
import 'sse_event.dart';
import 'sse_transport.dart';

/// Creates the browser SSE transport.
SseTransport createPlatformSseTransport() => EventSourceSseTransport();

/// An [SseTransport] backed by the browser's `EventSource`.
///
/// The browser owns the retry loop here: on a dropped connection it reconnects
/// on its own schedule and replays with the `Last-Event-ID` header it tracked.
/// That is why [handlesReconnect] is true — the gateway must stay out of the
/// way rather than open a second connection alongside the browser's.
///
/// One consequence is that the bridge's legacy heartbeat is invisible here.
/// `EventSource` surfaces only standard `message` events, and that heartbeat
/// uses its own event type. It still keeps the socket warm, which is all the
/// heartbeat is for.
final class EventSourceSseTransport implements SseTransport {
  final Set<web.EventSource> _open = {};

  @override
  bool get handlesReconnect => true;

  @override
  Future<Stream<SseEvent>> subscribe(Uri url, {String? lastEventId}) {
    // `lastEventId` is deliberately ignored: the browser stores the last id it
    // saw and sets the header itself on reconnect. Pinning it in the URL would
    // freeze every retry at a stale position.
    final source = web.EventSource(url.toString());
    _open.add(source);

    final ready = Completer<Stream<SseEvent>>();
    final controller = StreamController<SseEvent>(
      onCancel: () {
        source.close();
        _open.remove(source);
      },
    );

    source.onopen = ((web.Event _) {
      // Subsequent `open` events are the browser's own reconnects, which the
      // caller neither sees nor needs to act on.
      if (!ready.isCompleted) ready.complete(controller.stream);
    }).toJS;

    source.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      controller.add(
        SseEvent(
          event: 'message',
          data: data.isA<JSString>() ? (data as JSString).toDart : '',
          id: event.lastEventId.isEmpty ? null : event.lastEventId,
        ),
      );
    }).toJS;

    source.onerror = ((web.Event _) {
      // `EventSource` reports a dropped connection and a fatal failure through
      // the same event. `readyState` tells them apart: CONNECTING means the
      // browser is already retrying, so it is not the caller's problem.
      if (source.readyState != web.EventSource.CLOSED) return;

      const failure = TonConnectBridgeError(
        'The browser closed the bridge event stream and will not retry.',
      );
      _open.remove(source);
      if (ready.isCompleted) {
        controller.addError(failure);
        unawaited(controller.close());
      } else {
        // Failing before `open` means the subscription never existed, so the
        // error belongs to the future rather than the stream.
        ready.completeError(failure);
        unawaited(controller.close());
      }
    }).toJS;

    return ready.future;
  }

  @override
  Future<void> close() async {
    for (final source in _open) {
      source.close();
    }
    _open.clear();
  }
}
