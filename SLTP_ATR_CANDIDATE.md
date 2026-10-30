# Sona SL/TP width - investigation and candidate fix (2026-10-30)

## User report
22:05 IST: "Sona is placing sl and tp too high / Check and fix."

## Cause (code-level)
clampTargets() in lib/ai_brain.dart used fixed percent-of-price rails: stop
distance 0.3% min / 0.6% default / 2% max of entry price, TP >= 1.5x stop
distance. Unchanged since v23. On XAU/USD near $3900 with recent 15-minute
volatility (ATR14 about $9.5 measured on a Yahoo GC=F futures proxy), these
rails place stops $11.70-$78.02 and targets $17.55-$117 from entry - wide
relative to 15-minute price movement. Consistent with the report; his exact
placed values were not recoverable (paper account PIN-gated, telemetry
counts-only, AI log on-device), so this is a plausible cause, not a proven
reproduction of his case.

## Candidate change (branch feature/technical-summary-gauge, v1.2.12+113)
When ATR14 of the decision candles is usable (finite and > 0), stop distance
bands become 0.8x-2.5x ATR14 (default 1.2x); TP keeps >= 1.5R. The
multipliers are a design choice, not calibrated to outcomes. ATR comes from
the same 15-minute XAU/USD candles the model already sees on both paths:
auto-trade decide() (auto_trade.dart:333) and advice advise()
(main.dart:4977), buyRef=ask / sellRef=bid on both.

Guard rails:
- ATR unusable (missing, NaN, infinite, <= 0): the legacy percent rails
  apply unchanged and still produce the original wide levels.
- Absolute sanity window: the ATR-derived distance is clamped to 0.02%-2%
  of price. This bound is ARBITRARY. It only keeps outputs finite and
  non-degenerate against huge or near-zero ATR readings. It is not a
  validated safety threshold and is not calibrated against spread.

## Validation (2026-10-30, Flutter 3.47.9 stable, local)
- flutter test: 267 passed, 1 skipped, 0 failed. Includes 8 ATR clamp tests
  (bands, TP >= 1.5R, legacy fallback, NaN/inf/zero/negative ATR -> legacy,
  outlier ATR -> 2% cap, tiny ATR -> 0.02% floor). Legacy-path tests
  unchanged.
- flutter analyze: 0 errors; 15 warnings + 87 info, all pre-existing in
  unrelated files; none in the changed files.
- A first programmatic harness run caught 4 real edge bugs (infinite ATR,
  outlier ATR x2, tiny ATR) that the guards above fix; re-run 31/31 pass.

## Known limitations (unresolved; pre-existing unless noted)
1. Fallback still wide: without usable ATR the original fixed-percent rails
   apply and the complaint can still occur on that path.
2. Candle freshness is not validated anywhere: the last-bar timestamp is
   never compared to now, so stale candles silently feed ATR and the other
   indicators. Quote freshness IS enforced for auto-trade (auto_trade.dart
   _fetchQuote rejects a stale tick).
3. No spread-vs-stop validation exists anywhere; the 0.02% floor is not
   established as above spread.
4. Multipliers uncalibrated; tighter stops change loss behavior (more
   frequent stop-outs are possible).
5. Volatility grounding used a Yahoo futures proxy, not the app's Twelve
   Data spot feed; fit against live app data is unverified.
6. The user's exact on-device levels were unrecoverable.

## Status
Pushed to feature/technical-summary-gauge and byte-verified:
lib/ai_brain.dart, test/ai_brain_test.dart, pubspec.yaml (1.2.12+113).
CI held: no build dispatched, no release, no updater. Blocked only on build
authority for the signed test APK (standing debug-first gate) and user go.
