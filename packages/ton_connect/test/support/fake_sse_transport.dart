import 'dart:async';

import 'package:ton_connect/ton_connect.dart';

/// An [SseTransport] that hands the test direct control of each connection.
final class FakeSseTransport implements SseTransport {
  /// Creates a fake transport.
  ///
  /// Set [handlesReconnect] to model the browser's `EventSource`, which retries
  /// on its own and so must suppress the gateway's retry loop.
  FakeSseTransport({this.handlesReconnect = false});

  @override
  final bool handlesReconnect;

  /// URLs passed to [subscribe], oldest first.
  final List<Uri> requestedUrls = [];

  /// `lastEventId` values passed to [subscribe], oldest first.
  final List<String?> requestedLastEventIds = [];

  final List<StreamController<SseEvent>> _connections = [];

  /// Makes the next [subscribe] call fail with this error.
  Object? failNextWith;

  /// How many connections have been opened.
  int get connectionCount => _connections.length;

  /// Whether [close] has been called.
  bool closed = false;

  /// The most recently opened connection.
  StreamController<SseEvent> get current => _connections.last;

  @override
  Future<Stream<SseEvent>> subscribe(Uri url, {String? lastEventId}) async {
    requestedUrls.add(url);
    requestedLastEventIds.add(lastEventId);

    final failure = failNextWith;
    if (failure != null) {
      failNextWith = null;
      throw failure;
    }

    final controller = StreamController<SseEvent>();
    _connections.add(controller);
    return controller.stream;
  }

  /// Delivers [event] on the current connection.
  void emit(SseEvent event) => current.add(event);

  /// Delivers a bridge envelope on the current connection.
  void emitMessage(String data, {String? id}) =>
      emit(SseEvent(event: 'message', data: data, id: id));

  /// Ends the current connection as the server closing it.
  void endConnection() => current.close();

  /// Fails the current connection.
  void failConnection(Object error) => current.addError(error);

  @override
  Future<void> close() async {
    closed = true;
    for (final connection in _connections) {
      if (!connection.isClosed) await connection.close();
    }
  }
}
