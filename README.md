# TON Connect for Dart & Flutter

A TON Connect 2 SDK for Dart and Flutter, written against the [normative protocol specification](https://github.com/ton-blockchain/ton-connect).

> **Status: early development.** The core protocol layer is being built bottom-up and is not yet usable end-to-end. Nothing is published to pub.dev yet. See [Roadmap](#roadmap).

## Why this exists

TON Connect is an open protocol, but the only first-party SDK is JavaScript. The Dart ports that exist are unmaintained forks, and all of them predate the **2026.05.18** protocol revision, which added:

- the `signMessage` RPC method,
- structured `items` arrays for `sendTransaction` and `signMessage`, with `ton` / `jetton` / `nft` types,
- `NETWORK_ID` — any TON network `global_id`, replacing the two-value network enum,
- the `EmbeddedRequest` feature and the `e` connect-URL parameter,
- `trace_id` propagation across the bridge.

The goal is a Dart SDK that implements the protocol as it is today, with a modern Dart surface — sealed types, exhaustive `switch`, no `dynamic` — and a wallet-picker UI that Flutter apps do not currently have.

## Packages

| Package | What it is | State |
|---|---|---|
| `ton_connect` | Pure Dart core: encrypted sessions, HTTP bridge, injected JS bridge, wallet registry, universal links | in progress |
| `ton_connect_ui` | Flutter wallet-picker modal and native universal-link return handling | not started |

Both target mobile **and** Web / Telegram Mini Apps. The core carries two transports from the start: the encrypted HTTP bridge, and the injected `window.<wallet>.tonconnect` binding used when a dApp runs inside a wallet's webview.

## Design notes

**The bridge is untrusted.** It sees ciphertext and routing addresses, nothing else. Every message after the initial connect is sealed with NaCl `crypto_box` under a per-session X25519 keypair, laid out as `nonce(24) ++ box` exactly as [`spec/session.md`](https://github.com/ton-blockchain/ton-connect/blob/main/spec/session.md) requires. A message that fails authentication is discarded — never parsed as plaintext.

**Unknown values degrade, they do not throw.** A wallet running a newer protocol revision than this SDK will send platforms, features and connect items it does not recognise. These are preserved as `UnknownFeature`, `UnknownItemReply` and `UnknownProtocolError` rather than failing the connect.

**Absent features are refused locally.** The specification requires SDKs to treat a feature the wallet did not advertise as unsupported. Requests for such methods fail before anything is sent.

**Transport parsing is separable from I/O.** The SSE framing logic is a pure `StreamTransformer` over lines, so the bridge's edge cases — multi-line `data`, `id` carry-forward, truncated trailing events, heartbeat frames — are tested without a server.

**Reconnection lives in one place, and knows which place that is.** On native platforms the gateway owns retry: exponential backoff with full jitter, replay from `last_event_id`, and a watchdog that treats silence past the keep-alive window as a dead connection — the case where a phone switches networks and the socket never notices. In the browser, `EventSource` already does all of this, so the transport declares that it self-heals and the gateway stands down rather than opening a second connection alongside it.

## Development

Requires Dart 3.12+. The repository is a pub workspace; there is no `melos`.

```bash
dart pub get
```

The workspace root has no `test/` directory, so tests run per package:

```bash
dart analyze && dart test packages/ton_connect
```

## Roadmap

- [x] Session crypto — X25519 keypairs, `crypto_box`, session restore
- [x] Protocol models — connect request/event, `DeviceInfo`, features, `ton_proof`, error codes
- [x] SSE framing
- [x] SSE connection — `dart:io` and browser `EventSource`
- [x] `BridgeGateway` — reconnect with `last_event_id`, heartbeat handling
- [ ] Bridge and injected providers
- [ ] Wallet registry
- [ ] `TonConnect` facade and RPC methods
- [ ] Universal links and deep links
- [ ] `ton_connect_ui` — wallet-picker modal
- [ ] Example: offline merchant terminal

## License

MIT — see [LICENSE](LICENSE).
