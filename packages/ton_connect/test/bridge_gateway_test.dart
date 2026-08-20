import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ton_connect/ton_connect.dart';

import 'support/fake_sse_transport.dart';

const String clientId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String walletId =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String envelope({String from = walletId, String message = 'Zm9vYmFy'}) =>
    jsonEncode({'from': from, 'message': message});

BridgeGateway buildGateway({
  required FakeSseTransport transport,
  Uri? bridgeUrl,
  http.Client? httpClient,
  Duration heartbeatTimeout = const Duration(seconds: 60),
}) {
  return BridgeGateway(
    bridgeUrl: bridgeUrl ?? Uri.parse('https://bridge.example.org/bridge'),
    clientId: clientId,
    transport: transport,
    httpClient: httpClient ?? MockClient((_) async => http.Response('', 200)),
    heartbeatTimeout: heartbeatTimeout,
  );
}

void main() {
  group('BridgeGateway URLs', () {
    test('preserves the bridge base path when resolving /events', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);

      await gateway.open();

      expect(transport.requestedUrls.single.path, '/bridge/events');
    });

    test('tolerates a bridge URL with a trailing slash', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(
        transport: transport,
        bridgeUrl: Uri.parse('https://bridge.example.org/bridge/'),
      );
      addTearDown(gateway.close);

      await gateway.open();

      expect(transport.requestedUrls.single.path, '/bridge/events');
    });

    test('subscribes with the client id', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);

      await gateway.open();

      expect(
        transport.requestedUrls.single.queryParameters['client_id'],
        clientId,
      );
    });

    test(
      'asks for heartbeats as messages so the watchdog can see them',
      () async {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        addTearDown(gateway.close);

        await gateway.open();

        expect(
          transport.requestedUrls.single.queryParameters['heartbeat'],
          'message',
        );
      },
    );

    test(
      'omits the heartbeat parameter when the transport self-heals',
      () async {
        final transport = FakeSseTransport(handlesReconnect: true);
        final gateway = buildGateway(transport: transport);
        addTearDown(gateway.close);

        await gateway.open();

        expect(
          transport.requestedUrls.single.queryParameters,
          isNot(contains('heartbeat')),
        );
      },
    );
  });

  group('BridgeGateway open', () {
    test('surfaces a first-attempt failure to the caller', () async {
      final transport = FakeSseTransport()
        ..failNextWith = const TonConnectBridgeError('nope', statusCode: 403);
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);

      await expectLater(gateway.open(), throwsA(isA<TonConnectBridgeError>()));
    });

    test('is idempotent', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);

      await gateway.open();
      await gateway.open();

      expect(transport.connectionCount, 1);
    });

    test('refuses to reopen after close', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      await gateway.close();

      await expectLater(gateway.open(), throwsA(isA<TonConnectBridgeError>()));
    });

    test('resumes from a caller-supplied last event id', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);

      await gateway.open(lastEventId: '77');

      expect(transport.requestedLastEventIds.single, '77');
    });
  });

  group('BridgeGateway messages', () {
    test('parses an envelope', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);
      await gateway.open();

      final received = gateway.messages.first;
      transport.emitMessage(envelope());

      final message = await received;
      expect(message.from, walletId);
      expect(message.message, 'Zm9vYmFy');
    });

    test('exposes trace_id when the bridge propagates it', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);
      await gateway.open();

      final received = gateway.messages.first;
      transport.emitMessage(
        jsonEncode({'from': walletId, 'message': 'Zg==', 'trace_id': 'abc'}),
      );

      expect((await received).traceId, 'abc');
    });

    test('tolerates an envelope without trace_id', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);
      await gateway.open();

      final received = gateway.messages.first;
      transport.emitMessage(envelope());

      expect((await received).traceId, isNull);
    });

    test('filters heartbeat frames delivered as messages', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);
      await gateway.open();

      final collected = <BridgeMessage>[];
      gateway.messages.listen(collected.add);

      transport.emitMessage('heartbeat');
      transport.emitMessage(envelope());
      await pumpEventQueue();

      expect(collected, hasLength(1));
      expect(collected.single.from, walletId);
    });

    test(
      'filters heartbeat frames delivered as their own event type',
      () async {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        addTearDown(gateway.close);
        await gateway.open();

        final collected = <BridgeMessage>[];
        gateway.messages.listen(collected.add);

        transport.emit(const SseEvent(event: 'heartbeat', data: ''));
        await pumpEventQueue();

        expect(collected, isEmpty);
      },
    );

    test(
      'reports a malformed envelope without dropping the connection',
      () async {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        addTearDown(gateway.close);
        await gateway.open();

        final errors = <Object>[];
        final messages = <BridgeMessage>[];
        gateway.messages.listen(messages.add, onError: errors.add);

        transport.emitMessage('{not json');
        transport.emitMessage(envelope());
        await pumpEventQueue();

        expect(errors, hasLength(1));
        expect(errors.single, isA<TonConnectParseError>());
        // The healthy message that followed still arrives.
        expect(messages, hasLength(1));
        expect(transport.connectionCount, 1);
      },
    );

    test('rejects an envelope missing required fields', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);
      await gateway.open();

      final errors = <Object>[];
      gateway.messages.listen((_) {}, onError: errors.add);

      transport.emitMessage(jsonEncode({'from': walletId}));
      await pumpEventQueue();

      expect(errors.single, isA<TonConnectParseError>());
    });

    test('tracks the last event id', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      addTearDown(gateway.close);
      await gateway.open();
      gateway.messages.listen((_) {});

      transport.emitMessage(envelope(), id: '12');
      await pumpEventQueue();

      expect(gateway.lastEventId, '12');
    });
  });

  group('BridgeGateway reconnection', () {
    test('reconnects after the server closes the stream', () {
      fakeAsync((async) {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        unawaited(gateway.open());
        async.flushMicrotasks();

        transport.endConnection();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));

        expect(transport.connectionCount, 2);
      });
    });

    test('replays from the last event id when reconnecting', () {
      fakeAsync((async) {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        unawaited(gateway.open());
        async.flushMicrotasks();
        gateway.messages.listen((_) {});

        transport.emitMessage(envelope(), id: '99');
        async.flushMicrotasks();
        transport.endConnection();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));

        // The first subscription had nothing to resume from; the retry
        // replays everything published after event 99.
        expect(transport.requestedLastEventIds, [null, '99']);
      });
    });

    test('keeps retrying while attempts keep failing', () {
      fakeAsync((async) {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        unawaited(gateway.open());
        async.flushMicrotasks();

        transport.endConnection();
        async.flushMicrotasks();

        // Each retry fails immediately, so the gateway must schedule another.
        for (var i = 0; i < 3; i++) {
          transport.failNextWith = const TonConnectBridgeError('down');
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
        }

        expect(transport.requestedUrls.length, greaterThan(3));
      });
    });

    test('does not reconnect when the transport handles it itself', () {
      fakeAsync((async) {
        final transport = FakeSseTransport(handlesReconnect: true);
        final gateway = buildGateway(transport: transport);
        unawaited(gateway.open());
        async.flushMicrotasks();

        transport.endConnection();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));

        expect(transport.connectionCount, 1);
      });
    });

    test('surfaces a stream error when the transport handles reconnection', () {
      fakeAsync((async) {
        final transport = FakeSseTransport(handlesReconnect: true);
        final gateway = buildGateway(transport: transport);
        final errors = <Object>[];
        unawaited(gateway.open());
        async.flushMicrotasks();
        gateway.messages.listen((_) {}, onError: errors.add);

        transport.failConnection(
          const TonConnectBridgeError('browser gave up'),
        );
        async.flushMicrotasks();

        expect(errors, hasLength(1));
      });
    });

    test(
      'reconnects when the bridge goes silent past the heartbeat window',
      () {
        fakeAsync((async) {
          final transport = FakeSseTransport();
          final gateway = buildGateway(
            transport: transport,
            heartbeatTimeout: const Duration(seconds: 10),
          );
          unawaited(gateway.open());
          async.flushMicrotasks();

          // The socket never reports a problem; only the silence gives it away.
          async.elapse(const Duration(seconds: 45));

          expect(transport.connectionCount, greaterThan(1));
        });
      },
    );

    test('a heartbeat keeps the watchdog from firing', () {
      fakeAsync((async) {
        final transport = FakeSseTransport();
        final gateway = buildGateway(
          transport: transport,
          heartbeatTimeout: const Duration(seconds: 10),
        );
        unawaited(gateway.open());
        async.flushMicrotasks();
        gateway.messages.listen((_) {});

        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 8));
          transport.emitMessage('heartbeat');
          async.flushMicrotasks();
        }

        expect(transport.connectionCount, 1);
      });
    });

    test('stops retrying once closed', () {
      fakeAsync((async) {
        final transport = FakeSseTransport();
        final gateway = buildGateway(transport: transport);
        unawaited(gateway.open());
        async.flushMicrotasks();

        transport.endConnection();
        async.flushMicrotasks();
        unawaited(gateway.close());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));

        expect(transport.connectionCount, 1);
      });
    });
  });

  group('BridgeGateway send', () {
    test('posts the ciphertext to the peer with ttl and topic', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await gateway.send(
        to: walletId,
        message: 'Y2lwaGVy',
        topic: 'sendTransaction',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/bridge/message');
      expect(captured.url.queryParameters, {
        'client_id': clientId,
        'to': walletId,
        'ttl': '300',
        'topic': 'sendTransaction',
      });
      expect(captured.body, 'Y2lwaGVy');
    });

    test('omits topic and trace_id when not supplied', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await gateway.send(to: walletId, message: 'Zg==');

      expect(captured.url.queryParameters.keys, ['client_id', 'to', 'ttl']);
    });

    test('passes trace_id through when supplied', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await gateway.send(to: walletId, message: 'Zg==', traceId: 'trace-1');

      expect(captured.url.queryParameters['trace_id'], 'trace-1');
    });

    test('explains a 400 as a probable ttl violation', () async {
      final client = MockClient(
        (_) async => http.Response('ttl too large', 400),
      );
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await expectLater(
        gateway.send(to: walletId, message: 'Zg=='),
        throwsA(
          isA<TonConnectBridgeError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', contains('ttl')),
        ),
      );
    });

    test('reports a payload too large', () async {
      final client = MockClient((_) async => http.Response('', 413));
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await expectLater(
        gateway.send(to: walletId, message: 'Zg=='),
        throwsA(
          isA<TonConnectBridgeError>().having((e) => e.statusCode, 'code', 413),
        ),
      );
    });

    test('reports a rate limit', () async {
      final client = MockClient((_) async => http.Response('', 429));
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await expectLater(
        gateway.send(to: walletId, message: 'Zg=='),
        throwsA(
          isA<TonConnectBridgeError>().having((e) => e.statusCode, 'code', 429),
        ),
      );
    });

    test('wraps a transport-level failure', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport, httpClient: client);
      addTearDown(gateway.close);
      await gateway.open();

      await expectLater(
        gateway.send(to: walletId, message: 'Zg=='),
        throwsA(isA<TonConnectBridgeError>()),
      );
    });
  });

  group('BridgeGateway close', () {
    test('closes an owned transport', () async {
      final transport = FakeSseTransport();
      final gateway = BridgeGateway(
        bridgeUrl: Uri.parse('https://bridge.example.org/bridge'),
        clientId: clientId,
        transport: transport,
        httpClient: MockClient((_) async => http.Response('', 200)),
      );

      await gateway.open();
      await gateway.close();

      // The gateway did not create this transport, so it must not close it.
      expect(transport.closed, isFalse);
    });

    test('is idempotent', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);

      await gateway.open();
      await gateway.close();
      await gateway.close();
    });

    test('closes the message stream', () async {
      final transport = FakeSseTransport();
      final gateway = buildGateway(transport: transport);
      await gateway.open();

      final done = gateway.messages.drain<void>();
      await gateway.close();

      await done;
    });
  });
}
