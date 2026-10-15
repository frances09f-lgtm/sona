# Sona 1.0.80

- Switch between candlestick, line and OHLC bar charts. Keep the existing market timeframes/ranges, pinch to zoom, drag to pan and open a landscape full-screen view. Full-screen reflects live paper positions and returns indicator/style changes to the original chart.
- Configure EMA and RSI periods and MACD fast/slow/signal periods from Indicators → Indicator settings. Existing indicator toggles and saved chart presets remain available. Short histories show only warmed-up values; invalid candles are not invented or filled in.
- See display-only paper entry, stop-loss and take-profit levels on the chart, with buy/sell size and current estimated P/L. Stale/unavailable quotes show P/L unavailable. These overlays do not place orders or change protection limits.
- Historical candles retain the provider's OHLC instead of having their last close replaced by an unrelated current quote.

Existing compact position cards, risk sizing, journal data and Android package/signing compatibility are retained. Existing drawing tools are unchanged; this release does not introduce draggable stops or chart-based order execution.

## Important limitations
Always-on server-side TP/SL is NOT deployed. Device-local checks remain best effort and can be delayed/stopped; chart overlays do not guarantee unattended exits. The existing Supabase schema/RPC source and authenticated deployment route are still required for reliable app-independent execution.

Existing market-data sources/authentication remain unchanged; this release adds no paid feed, fabricated candles or external chart service. Actual history and supported interval availability depend on the configured feed. Automated tests and synthetic Flutter render checks are covered; physical-phone orientation/gesture behavior and authenticated account round-trips remain untested.
