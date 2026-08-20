# merchant_terminal

A new Flutter project.

## What this shows

- Building a payment as a **structured jetton item**, so the wallet shows "12.34 USDT" rather than an opaque cell and works out the TON needed to carry the transfer itself.
- **`EmbeddedRequest`**, which folds the payment into the connect link so the customer approves once instead of twice — with a fallback over the bridge for wallets that do not support it.
- Money handling that never touches a `double`. The cashier types cents; `units` scales to the asset's own precision, which is six places for USDT and nine for TON.

## Before you charge anything

`merchantAddress` ships as the **zero address** — a burn address. Anything sent
to it is destroyed, and because the address is non-bounceable, nothing comes
back. `terminalNetwork` is mainnet, so those would be real funds.

The terminal refuses to take a payment until you replace it. Set your own
address in `lib/terminal_config.dart`, in the non-bounceable friendly form.
For a first live test, switch `terminalNetwork` to `NetworkId.testnet` and use
testnet coins.

## What a real terminal still needs

The BoC the wallet returns is a receipt that the payment was **broadcast**, not that it **settled**. A terminal handling real money watches the chain for the transaction and reconciles against it before handing over the goods. This example says so on the receipt screen rather than pretending otherwise.

It also uses `InMemoryStorage`, so sessions do not survive a restart. Sessions hold the session secret key — put them somewhere private, such as the platform keystore.
