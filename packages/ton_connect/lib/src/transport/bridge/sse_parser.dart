import 'dart:async';

import 'sse_event.dart';

/// Transforms a stream of decoded SSE lines into dispatched [SseEvent]s.
///
/// Implements the event-stream interpretation rules from the HTML standard:
/// `field: value` lines accumulate into a buffer, a blank line dispatches it,
/// lines opening with a colon are comments, and repeated `data:` lines are
/// joined with newlines.
///
/// This holds no I/O, so the bridge's framing behaviour is testable without a
/// server. Feed it lines already split on CR, LF or CRLF.
final class SseParser extends StreamTransformerBase<String, SseEvent> {
  /// Creates a parser.
  ///
  /// When [emitComments] is true, comment lines are surfaced as events with an
  /// `event` of `comment`. The bridge's default heartbeat is delivered as a
  /// non-standard event type rather than a comment, so this stays off unless a
  /// caller wants raw visibility into keep-alive traffic.
  const SseParser({this.emitComments = false});

  /// Whether to surface comment lines as `comment` events.
  final bool emitComments;

  @override
  Stream<SseEvent> bind(Stream<String> stream) {
    final buffer = _EventBuffer();
    return stream.transform(
      StreamTransformer<String, SseEvent>.fromHandlers(
        handleData: (line, sink) {
          // A blank line dispatches whatever has accumulated.
          if (line.isEmpty) {
            final event = buffer.take();
            if (event != null) sink.add(event);
            return;
          }

          if (line.startsWith(':')) {
            if (emitComments) {
              sink.add(
                SseEvent(event: 'comment', data: line.substring(1).trimLeft()),
              );
            }
            return;
          }

          final colon = line.indexOf(':');
          final (String field, String value) = colon == -1
              // A line with no colon is a field name with an empty value.
              ? (line, '')
              : (
                  line.substring(0, colon),
                  // Exactly one leading space after the colon is stripped.
                  _stripOneSpace(line.substring(colon + 1)),
                );

          buffer.add(field, value);
        },
        handleDone: (sink) {
          // The standard discards an undispatched buffer at end of stream. The
          // bridge always terminates an event with a blank line, so anything
          // left here is a truncated event and must not be delivered.
          sink.close();
        },
      ),
    );
  }

  static String _stripOneSpace(String value) =>
      value.startsWith(' ') ? value.substring(1) : value;
}

final class _EventBuffer {
  final StringBuffer _data = StringBuffer();
  bool _hasData = false;
  String? _event;
  String? _lastId;
  String? _pendingId;

  void add(String field, String value) {
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
      case 'id':
        // The standard ignores an id field whose value contains U+0000.
        if (!value.contains('\u0000')) _pendingId = value;
      case 'retry':
        // The gateway owns its own backoff policy, so a server-suggested retry
        // interval is accepted syntactically and otherwise ignored.
        break;
      default:
        // Unknown fields are ignored.
        break;
    }
  }

  SseEvent? take() {
    // `id` persists across events until the server sends a new one, so it is
    // applied even when the dispatched event carries no data.
    if (_pendingId != null) {
      _lastId = _pendingId;
      _pendingId = null;
    }
    if (!_hasData && _event == null) return null;

    final event = SseEvent(
      event: _event ?? 'message',
      data: _data.toString(),
      id: _lastId,
    );
    _data.clear();
    _hasData = false;
    _event = null;
    return event;
  }
}
