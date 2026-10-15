# Sona 1.0.79

- Open positions now start as compact History-style cards showing instrument, amount, direction and live P/L. Tap the card or chevron to reveal Close Trade, the full risk breakdown, position details and TP/SL controls.
- Closing a trade still requires confirmation. No trading logic, account data or backend behavior changed in this layout update.

## Included from 1.0.78

- Risk-based paper-trade sizing: choose USD or a percentage of paper balance and a stop distance; review estimated loss, gain and reward/risk. Buy/sell protection levels are validated consistently.
- Accurate manual journal: quantity, total costs and setup tags; versioned note metadata preserves existing backend schema and historical records. Legacy unknown sizes are not invented and recorded PnL remains intact.
- Separate simulated/manual performance, date filters, setup breakdown and chronological drawdown.
- Safer device auto-exits: timestamp/freshness checks, cross-isolate durable close claims and conservative handling of uncertain results. Existing Android identity, production signing and data compatibility retained.

## Important limitation
Always-on server-side TP/SL is NOT deployed. Android device checks are best effort, can be delayed/stopped, and limits remain device-local. Do not rely on this app for guaranteed unattended exits. Enabling reliable app-independent paper execution requires the existing Supabase schema/RPC source and an authenticated deployment route; this repository contains an isolated backend proposal, not an installed scheduler. No live account data or backend schema was changed.

Journal persistence uses the existing note field; live authenticated account round-trip has not been tested. Risk estimates exclude fees/swap and gaps/slippage can exceed the stop estimate.

Automated Flutter/widget tests and synthetic phone-width rendering are covered. Physical Android device behavior is not yet tested. Release workflow verifies package, version and the existing production signing certificate before publishing.
