# Sona 1.0.82

- Fix open-position cards showing "0.00 oz" and "+$0.00": small AI trade sizes (under 0.01 oz) and sub-cent P/L now display with 4 decimals (e.g. 0.0024 oz, $0.0048) instead of rounding to zero. The two open BUY positions are real trades, not corrupted data.
- AI trade log and notification text use the same precise size formatting.

Existing chart controls, position cards, journal data, Android package and production signing compatibility are retained.

## Important limitations
This changes display formatting only; trade sizing, execution and backend behavior are unchanged. Physical-phone behavior remains untested.
