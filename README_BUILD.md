# Sona - Flutter app

Mirror of https://gold-trade-journal.netlify.app/ as a native Android app.
Same Supabase backend, same PIN (no backend changes needed).

## Build the APK (one command)

Install Flutter stable (3.47+), Android SDK, then:

    flutter pub get && flutter build apk --release

Output: build/app/outputs/flutter-apk/app-release.apk

Debug variant (installs alongside, no signing needed):

    flutter build apk --debug

## First run

1. Install the APK, open "Sona".
2. Enter your PIN (same as the web app).
3. Bottom tabs: Trade (live XAU/USD price, Buy/Sell), Positions (open + history),
   Add (manual XM log), Stats (equity curve, reset).

## Market data (V2)

- Live XAU/USD bid/ask from the Swissquote public feed (no key needed),
  refreshed every 20s. Gold-api/goldprice.org are mid-only fallbacks.
- Execution is broker-true: buys open at ask / close at bid, sells the
  reverse; the spread is a real cost inside PnL.
- Real candles from Twelve Data (free tier). Pass the key at build time -
  it is never committed:

      flutter build apk --release --dart-define=MARKET_DATA_API_KEY=your_key

  Without the key the chart panel says it is not configured instead of
  drawing demo data. Get a free key at https://twelvedata.com (XAU/USD
  spot works on the free plan, 8 credits/min, 800/day).

Notes:
- TP/SL switches, price alerts, journal notes and the last-known paper
  state are stored on-device. Android background checks are best effort and may be delayed or stopped; always-on server protection is not deployed.
- INTERNET permission is declared; release builds sign with the debug key by default
  (fine for personal use - add your own signing config for distribution).

## Naming and compatibility

The project and visible app name are Sona. The Android application ID and
namespace remain `com.ambi.gold_paper_trading` so renaming does not create a
separate app identity. Backend URLs, stored preferences, signing configuration
are unchanged. Release version is incremented for compatible upgrades. The web app above is an existing backend
reference, not a newly deployed Sona site.

## Sona 1.0.78 scope and compatibility

This source reconciles the previously released terminal feature branch with the renamed main project, then adds risk-based order entry, quantity/cost-aware journal records and separate manual/simulated performance views. Version is taken from pubspec rather than an unrelated Actions run count. Android application ID, production keystore, PIN account backend and existing storage keys are unchanged.

- Paper order sheet supports USD or percent-of-paper-balance risk sizing using stop distance, a directional TP/SL check and loss/gain/reward-to-risk preview. These are estimates, not broker margin guarantees or guaranteed stop fills. The original server-side paper account refresh and order validation still apply.
- Journal quantities, total costs, setup tags and PnL mode are encoded into a versioned suffix of the existing note field, avoiding assumptions about undeployed backend columns. Notes round-trip intact. Old records retain their recorded PnL and unknown size; editing notes does not guess size. Manually overridden PnL is already net and is not charged twice.
- Performance selects simulated fills OR manual journal (never double-counting both), with date ranges and manual setup breakdowns, chronological drawdown and existing summary measures.
- Automatic exits now require finite, uncrossed, genuinely timestamped quotes. A durable SQLite device-wide ledger deduplicates foreground/background closes and preserves uncertain requests rather than retrying. Successful records retain quote time, observed time, fill and reason locally. It cannot dedupe other devices without backend guarantees.
- **Always-on server protection is not deployed.** Device WorkManager checks remain best effort, approximately 15-minute minimum and subject to Android/OEM delays/stops. Edits to limits remain local to this device. A foreground service is not a server scheduler or a reliable substitute. The order screen states this limitation. See `backend/proposal` for the isolated additive migration and the exact missing backend integration.

No live account data was used for development/tests; screenshot fixtures are synthetic Flutter rendering, not physical-phone captures. No Supabase schema/data was deployed or modified. New quantity/cost fields require the existing j_save RPC to preserve its note text; static client contract is unchanged, but end-to-end live-account persistence was not tested without scoped credentials.
