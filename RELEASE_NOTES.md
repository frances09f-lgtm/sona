Sona 1.0.97

- Chart now draws only TWO strategy lines: the high and low of the most recent closed 1-hour candle, updating each hour (the many older lines are gone). Backtests still evaluate every hour.
- Fix: strategy levels no longer draw outside the chart - off-range levels are skipped and everything is clipped to the chart area, so nothing overlaps the GOLD header.
- Fix: level price labels no longer stack on top of each other.
- Fix: the Add strategy form has proper spacing - labels and boxes no longer overlap.
