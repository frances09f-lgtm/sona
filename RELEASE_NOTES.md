Sona 1.0.89

- The forming candle is now built from the same live tick stream that drives the yellow line (the app records every Swissquote bid tick and aggregates the current minute's open/high/low/close from it). Line and candle share one source, so they cannot diverge - verified against the live feed: line == last candle close at every sampled tick, on both 1H and 1D, and after app resume.
- Fixed the forming bar being clipped: the chart's scroll/zoom window now counts the drawn series (including the live bar), not just the provider history - this is why v1.0.88's line sat below the last candles.
- When the candle feed lags, recent one-minute bars are aggregated from real ticks (gap minutes with no ticks are skipped; nothing is fabricated during a feed outage).
