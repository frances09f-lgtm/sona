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
