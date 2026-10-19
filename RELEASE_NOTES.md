Sona 1.0.90

- Drawn bars now match the yellow live-price line: recent 1-minute bars (including the still-forming one) are built on-device from the same Swissquote bid-tick stream that draws the line, so the last candle's close is always the line price.
- Bars connect like a real chart: every tick-built bar opens at the previous bar's close; high/low come only from real ticks in that bar's window plus that anchor; the forming bar's close is the live quote.
- Fixed the forming bar being clipped at the right edge: the scroll/zoom window now counts the drawn series, not just provider history (the v1.0.88 bug where the line sat past the last candle).
- Gap minutes with no tick coverage are skipped; nothing is fabricated during a candle-feed outage.

Verified live against the real feed across 3 consecutive minute rollovers plus a 1H->1D->1H switch and an app-resume: line == last candle close at every sample, forming bar always visible. During verification the market dropped ~3 points inside one minute (19:13 IST, confirmed against COMEX gold futures); the chart drew that minute as one continuous bar from open=prior close down to the line, which is the correct rendering.
