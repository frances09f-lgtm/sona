Sona 1.0.87

- The yellow live-price line, its price tag, the forming candle and the big price number now all use one basis - bid - matching XM/MetaTrader, where OTC charts are built on bid prices.
- The latest candle now always meets the live line: when the free candle feed lags (its last bar already closed), Sona draws the still-forming bar from the live quote, opening at the last real close. Provider history is never rewritten, and if the candle feed is down (over 3 bars of lag) no bar is fabricated.
- The chart's OHLC readout shows the live forming bar, so its C value equals the line price.
