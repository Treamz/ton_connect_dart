import 'dart:async';

import 'package:ton_connect/ton_connect.dart';

/// An [InjectedBridge] the test drives directly.
final class FakeInjectedBridge implements InjectedBridge {
  FakeInjectedBridge({
    this.key = 'tonkeeper',
    this.protocolVersion = 2,
    this.isWalletBrowser = true,
  });

  @override
  final String key;

  @override
  final int protocolVersion;

  @override
  final bool isWalletBrowser;

  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  /// Requests passed to [send], oldest first.
  final List<Map<String, Object?>> sentRequests = [];

  /// Connect requests passed to [connect], oldest first.
  final List<Map<String, Object?>> connectRequests = [];

  /// How many times [restoreConnection] was called.
  int restoreCalls = 0;

  /// Whether [close] was called.
  bool closed = false;

  /// What [connect] resolves with.
  Map<String, Object?>? connectResponse;

  /// What [restoreConnection] resolves with.
  Map<String, Object?>? restoreResponse;

  /// What [send] resolves with, given the request it received.
  Map<String, Object?> Function(Map<String, Object?> request)? onSend;

  /// Makes the next call of any kind fail.
  Object? failNextWith;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Delivers a wallet-initiated event.
  void emit(Map<String, Object?> event) => _events.add(event);

  Object? _takeFailure() {
    final failure = failNextWith;
    failNextWith = null;
    return failure;
  }

  @override
  Future<Map<String, Object?>> connect(
    int protocolVersion,
    Map<String, Object?> request,
  ) async {
    connectRequests.add(request);
    final failure = _takeFailure();
    if (failure != null) throw failure;
    return connectResponse ?? (throw StateError('No connectResponse set.'));
  }

  @override
  Future<Map<String, Object?>> restoreConnection() async {
    restoreCalls++;
    final failure = _takeFailure();
    if (failure != null) throw failure;
    return restoreResponse ?? (throw StateError('No restoreResponse set.'));
  }

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) async {
    sentRequests.add(request);
    final failure = _takeFailure();
    if (failure != null) throw failure;
    final handler = onSend;
    if (handler != null) return handler(request);
    return {'result': 'te6ccg', 'id': request['id']};
  }

  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }
}
