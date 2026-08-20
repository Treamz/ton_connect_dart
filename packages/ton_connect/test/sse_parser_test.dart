import 'dart:convert';

import 'package:test/test.dart';
import 'package:ton_connect/src/transport/bridge/sse_event.dart';
import 'package:ton_connect/src/transport/bridge/sse_parser.dart';

/// Feeds [raw] through the same line splitter the live connection uses.
Future<List<SseEvent>> parse(String raw, {bool emitComments = false}) {
  return Stream.value(raw)
      .transform(const LineSplitter())
      .transform(SseParser(emitComments: emitComments))
      .toList();
}

void main() {
  group('SseParser', () {
    test('parses a single data event', () async {
      final events = await parse('data: hello\n\n');

      expect(events, hasLength(1));
      expect(events.single.event, 'message');
      expect(events.single.data, 'hello');
      expect(events.single.id, isNull);
    });

    test('defaults the event type to message', () async {
      final events = await parse('data: x\n\n');

      expect(events.single.event, 'message');
    });

    test('honours an explicit event type', () async {
      final events = await parse('event: heartbeat\ndata: ping\n\n');

      expect(events.single.event, 'heartbeat');
      expect(events.single.data, 'ping');
    });

    test('joins repeated data lines with newlines', () async {
      final events = await parse('data: one\ndata: two\ndata: three\n\n');

      expect(events.single.data, 'one\ntwo\nthree');
    });

    test('strips exactly one space after the colon', () async {
      final events = await parse('data:  two spaces\n\n');

      expect(events.single.data, ' two spaces');
    });

    test('accepts a field with no space after the colon', () async {
      final events = await parse('data:tight\n\n');

      expect(events.single.data, 'tight');
    });

    test('treats a colon-less line as a field with an empty value', () async {
      final events = await parse('data\n\n');

      expect(events.single.data, '');
    });

    test('ignores comment lines by default', () async {
      final events = await parse(': keep-alive\ndata: real\n\n');

      expect(events, hasLength(1));
      expect(events.single.data, 'real');
    });

    test('surfaces comments when asked', () async {
      final events = await parse(': ping\ndata: real\n\n', emitComments: true);

      expect(events.map((e) => e.event), ['comment', 'message']);
      expect(events.first.data, 'ping');
    });

    test('dispatches multiple events in one stream', () async {
      final events = await parse('data: first\n\ndata: second\n\n');

      expect(events.map((e) => e.data), ['first', 'second']);
    });

    test('carries the id forward until the server changes it', () async {
      final events = await parse(
        'id: 1\ndata: a\n\ndata: b\n\nid: 2\ndata: c\n\n',
      );

      // The second event inherits id 1 because the server did not resend one.
      expect(events.map((e) => e.id), ['1', '1', '2']);
    });

    test('discards a truncated trailing event', () async {
      // No blank line terminates the second event.
      final events = await parse('data: complete\n\ndata: truncated');

      expect(events.map((e) => e.data), ['complete']);
    });

    test('ignores unknown fields', () async {
      final events = await parse('foo: bar\ndata: real\n\n');

      expect(events, hasLength(1));
      expect(events.single.data, 'real');
    });

    test('ignores the retry field without emitting an event', () async {
      final events = await parse('retry: 5000\n\ndata: real\n\n');

      expect(events.map((e) => e.data), ['real']);
    });

    test('emits nothing for a blank line with an empty buffer', () async {
      final events = await parse('\n\n\n');

      expect(events, isEmpty);
    });

    test('emits an event that carries a type but no data', () async {
      // The bridge's legacy heartbeat is exactly this shape.
      final events = await parse('event: heartbeat\n\n');

      expect(events, hasLength(1));
      expect(events.single.event, 'heartbeat');
      expect(events.single.data, '');
    });

    test('handles CRLF line endings', () async {
      final events = await parse('event: message\r\ndata: crlf\r\n\r\n');

      expect(events.single.data, 'crlf');
    });

    test('parses a realistic bridge message envelope', () async {
      const envelope =
          '{"from":"aa","message":"Zm9v","trace_id":"01900000-0000-7000-8000-000000000000"}';
      final events = await parse('id: 42\ndata: $envelope\n\n');

      expect(events.single.id, '42');
      expect(jsonDecode(events.single.data), isA<Map<String, Object?>>());
    });

    test('resets accumulated state between events', () async {
      final events = await parse('event: custom\ndata: a\n\ndata: b\n\n');

      expect(events[0].event, 'custom');
      // The second event must not inherit the first event's type.
      expect(events[1].event, 'message');
      expect(events[1].data, 'b');
    });
  });
}
