# Sona 1.0.81

- Fix unnecessary chart-history truncation on ordinary candle intervals, including 1H, 4H and 1D. All candles returned by the configured provider are retained so EMA, RSI and MACD can use the available history.
- Explicit date-range selections keep their existing inclusive cutoff behavior. Short or sparse provider responses are not padded or fabricated.
- Includes regression coverage for interval history, range boundaries, indicator warmup and switching from a date range to candle intervals.

Existing chart controls, position cards, journal data, Android package and production signing compatibility are retained.

## Important limitations
This repair cannot provide history absent from the market-data provider. Reliable app-independent stop-loss/take-profit remains blocked by missing backend integration; device-local protection is still best effort. This release does not change backend execution or place trades. Physical-phone behavior and authenticated provider round-trips remain untested.
