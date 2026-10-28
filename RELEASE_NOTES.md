# Sona 1.2.10

## Fixed
- Risk-based order sizing now floors to the supported 1 oz (0.01-lot) step, so the displayed order size stays within the selected stop-risk budget. Budgets below the 1 oz minimum are rejected.

## Includes all of 1.2.9

## New
- Backtest results now show two more numbers: profit factor (gross winning
  points / gross losing points, shown as a dash when there are no losses
  instead of an invented "Infinity") and max drawdown (the deepest
  peak-to-trough drop of the running points total). Both come from the same
  simulated trades already shown; the backtest is still display-only and
  never touches the paper account.

## Includes all of 1.2.8
- Trade from Friday with confirmation; honest update-check failures; daily
  and weekly chart fixes.

# Sona 1.2.8

## New
- Trade from Friday: say or type "buy gold 0.1 lot", "sell 0.05 lot SL 4150
  TP 4080" or "close my trade" in Friday (v1.0.161+). Friday shows a
  confirmation; after you confirm, Sona opens briefly, places or closes the
  PAPER trade itself with your PIN session and all its usual checks (live
  price, market hours, daily limits, margin, TP/SL sides), then hands the
  screen back to Friday with the fill or the exact reason it refused.
- Only Friday can send orders to Sona (checked by app identity), one at a
  time, and each order runs once: an order older than 60 seconds is refused.
  Friday never gets your PIN. Paper trading only - no broker, no real money.

# Sona 1.2.7

## Fixed
- "Check for updates" no longer claims Sona is up to date when the check
  itself failed, for example without internet or on a rate limit. It now
  says the check could not be completed and to try again.

# Sona 1.2.6

## Fixed
- Day, week, 3-month and 1-year charts showed "zero usable candles" instead of
  a chart. Twelve Data sends daily and weekly bars as plain dates, and the app
  dropped them. All 14 timeframe and range views now verified against the real
  feed.

# Sona 1.2.5

## Fixed
- Chart time axis: labels no longer repeat the same bare date ("10/6 10/6 10/6")
  across multi-day views. The axis now shows clock times within a day and the
  date only where the day rolls over, on both the trade chart and the
  fullscreen chart editor.

- Test harness now runs Bar Replay through the same candle-slicing path the
  phone uses, so replay regressions cannot hide behind test-only data feeds.
  Verified replay start snap, stepping, and the last-price line tracking the
  replay price.
