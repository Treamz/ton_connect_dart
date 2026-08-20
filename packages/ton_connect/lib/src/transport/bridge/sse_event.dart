import 'package:meta/meta.dart';

/// One dispatched server-sent event.
@immutable
final class SseEvent {
  /// Creates a server-sent event.
  const SseEvent({required this.event, required this.data, this.id});

  /// The event type, defaulting to `message` when the stream omits it.
  final String event;

  /// The event payload — `data:` lines joined with newlines.
  final String data;

  /// The last `id:` seen on the stream, if any.
  ///
  /// The bridge gateway replays from this value via `last_event_id` after a
  /// dropped connection.
  final String? id;

  @override
  String toString() => 'SseEvent($event, id: $id, ${data.length} bytes)';
}
