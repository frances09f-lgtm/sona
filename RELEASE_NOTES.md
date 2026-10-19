Sona 1.0.86

- The live price now updates every second. Sona polled the Swissquote feed every 3s while the feed itself ticks about every 1.5s in liquid hours, so over half of the ticks never showed; at 1s polling the quote, last-price line and forming candle track the market closely.
- A hung quote request can no longer freeze the price: the feed timeout is cut from 10s to 4s.
- When the Swissquote feed is unreachable, the backup price sources are retried every 10s instead of on every tick, so an outage no longer hammers the free fallback endpoints.
