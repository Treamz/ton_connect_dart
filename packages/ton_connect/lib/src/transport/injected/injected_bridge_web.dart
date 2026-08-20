import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../models/ton_connect_error.dart';
import 'injected_bridge.dart';

@JS('Object.keys')
external JSArray<JSString> _objectKeys(JSObject target);

/// The property a wallet exposes its TON Connect binding under.
const String _bindingProperty = 'tonconnect';

/// Finds the `window` keys of every wallet that injected itself into this page.
///
/// Enumerates the global object rather than probing the registry's known keys,
/// so a wallet shipping a new build is found without waiting for a registry
/// update. Cross-check the result against the registry to name and draw it.
List<String> findInjectedWalletKeys() {
  final keys = <String>[];
  for (final name in _objectKeys(globalContext).toDart) {
    final key = name.toDart;
    // Reading some window properties throws — cross-origin frames especially —
    // and one hostile or unusual property must not cost the whole scan.
    try {
      final candidate = globalContext.getProperty<JSAny?>(name);
      if (candidate.isA<JSObject>() &&
          (candidate! as JSObject).has(_bindingProperty)) {
        keys.add(key);
      }
    } on Object {
      continue;
    }
  }
  return keys;
}

/// Opens the binding a wallet injected under [key], or `null` when absent.
InjectedBridge? openInjectedBridge(String key) {
  final JSObject binding;
  try {
    final wallet = globalContext.getProperty<JSAny?>(key.toJS);
    if (!wallet.isA<JSObject>()) return null;
    final candidate = (wallet! as JSObject).getProperty<JSAny?>(
      _bindingProperty.toJS,
    );
    if (!candidate.isA<JSObject>()) return null;
    binding = candidate! as JSObject;
  } on Object {
    return null;
  }
  return WebInjectedBridge(key, binding);
}

/// An [InjectedBridge] over a wallet's injected JavaScript object.
final class WebInjectedBridge implements InjectedBridge {
  /// Wraps the JavaScript binding a wallet injected under [key].
  WebInjectedBridge(this.key, this._binding) {
    _subscribe();
  }

  @override
  final String key;

  final JSObject _binding;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  JSFunction? _unsubscribe;

  @override
  int get protocolVersion =>
      _binding.getProperty<JSNumber?>('protocolVersion'.toJS)?.toDartInt ?? 2;

  @override
  bool get isWalletBrowser =>
      _binding.getProperty<JSBoolean?>('isWalletBrowser'.toJS)?.toDart ?? false;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  void _subscribe() {
    void onEvent(JSAny? event) {
      final decoded = _asJsonObject(event);
      if (decoded != null) _events.add(decoded);
    }

    try {
      _unsubscribe = _binding.callMethod<JSFunction?>(
        'listen'.toJS,
        onEvent.toJS,
      );
    } on Object {
      // A wallet without `listen` still handles requests; it just never
      // volunteers a disconnect. Losing that is better than refusing to
      // connect at all.
      _unsubscribe = null;
    }
  }

  @override
  Future<Map<String, Object?>> connect(
    int protocolVersion,
    Map<String, Object?> request,
  ) => _invoke('connect', [protocolVersion.toJS, request.jsify()]);

  @override
  Future<Map<String, Object?>> restoreConnection() =>
      _invoke('restoreConnection', const []);

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) =>
      _invoke('send', [request.jsify()]);

  Future<Map<String, Object?>> _invoke(String method, List<JSAny?> args) async {
    final JSAny? result;
    try {
      result = switch (args.length) {
        0 => _binding.callMethod<JSAny?>(method.toJS),
        1 => _binding.callMethod<JSAny?>(method.toJS, args[0]),
        _ => _binding.callMethod<JSAny?>(method.toJS, args[0], args[1]),
      };
    } on Object catch (e) {
      throw TonConnectBridgeError(
        'The injected wallet "$key" rejected $method: $e',
      );
    }

    final JSAny? settled;
    if (result.isA<JSPromise<JSAny?>>()) {
      try {
        settled = await (result! as JSPromise<JSAny?>).toDart;
      } on Object catch (e) {
        // A rejected promise is how an injected wallet reports a refusal.
        throw TonConnectBridgeError(
          'The injected wallet "$key" failed $method: $e',
        );
      }
    } else {
      settled = result;
    }

    final decoded = _asJsonObject(settled);
    if (decoded == null) {
      throw TonConnectParseError(
        'The injected wallet "$key" returned a non-object from $method.',
      );
    }
    return decoded;
  }

  @override
  Future<void> close() async {
    try {
      _unsubscribe?.callAsFunction();
    } on Object {
      // Nothing useful to do if the wallet's unsubscribe throws.
    }
    _unsubscribe = null;
    await _events.close();
  }
}

/// Converts a JS value into a JSON-shaped Dart map, or `null` if it is not one.
///
/// `dartify` hands back `Map<Object?, Object?>`, while every parser in this
/// package tests for `Map<String, Object?>`. Without this rebuild those checks
/// reject perfectly good wallet messages, so the conversion has to run all the
/// way down rather than only at the top level.
Map<String, Object?>? _asJsonObject(JSAny? value) {
  final dartified = value.dartify();
  final normalized = _normalize(dartified);
  return normalized is Map<String, Object?> ? normalized : null;
}

Object? _normalize(Object? value) => switch (value) {
  final Map<Object?, Object?> map => <String, Object?>{
    for (final entry in map.entries)
      if (entry.key case final Object key) '$key': _normalize(entry.value),
  },
  final List<Object?> list => [for (final item in list) _normalize(item)],
  _ => value,
};
