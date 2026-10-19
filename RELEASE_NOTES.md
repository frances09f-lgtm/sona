Sona 1.0.83

- AI auto-trades now use a 0.01 oz minimum: computed sizes below 0.01 oz are raised to 0.01 oz instead of opening dust positions that displayed as "0.00 oz".
- Trades are capped by the estimated free paper margin (1:500 client-side estimate), and a cycle is skipped with a clear AI-log entry and notification if the balance cannot cover the 0.01 oz minimum.
- Carries over the 1.0.82 fix: sub-0.01 values in sizes and P/L now display with 4 decimals instead of rounding to 0.00.
