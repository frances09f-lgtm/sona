Sona 1.0.88

- The real reason the yellow line would not sit on the candles: TwelveData returns candle times in the exchange timezone (Sydney, UTC+11) with no timezone marker, so on an IST phone every candle was stamped about 8 hours in the future. The chart refused to fold the live quote into a "future" candle, so the line floated away from the last bar and the axis clock showed odd times (like 21:15 at 3:46 PM).
- Candles are now fetched in UTC and converted to phone-local time: the axis clock reads correctly, and the live quote folds into the real forming bar every tick - the yellow line and the latest candle always meet, on every timeframe.
