# Query optimization (Koinju ClickHouse)

Koinju's tables are huge: `api.trade` is ~40 TB, `public_data.candle_1m` (source for `api.ohlcv`) ~4 TB. A query that doesn't constrain the scan will time out, throttle the connection, or burn the day's quota.

## Core rules

1. **Always bound the time-range.** Every query on `api.trade`, `api.ohlcv*`, `api.funding_rate`, `api.option_chain` MUST include a `>= now() - INTERVAL N {DAY,HOUR}` (or equivalent) on the time column:
   - `start` for `ohlcv*`
   - `timestamp` for `trade`, `option_chain`, `option_smile`, `volatility_index`
   - `funding_timestamp` for `funding_rate`

2. **Pick the largest candle duration that still gives enough resolution.** A 1-year average needs `candle_duration_in_minutes = 1440` (≈365 rows), never raw trades. Intraday charts: `15` or `60` is plenty.

3. **Prefer convenience views when you can.** `api.ohlcv_1m` and `api.ohlcv_1h` skip the parameterized scan and let the planner prune partitions more aggressively than `api.ohlcv(candle_duration_in_minutes = X)`. **There is no `api.ohlcv_1d`** — for daily candles, the parameterized view (`candle_duration_in_minutes = 1440`) is the only path.

4. **Aggregate server-side.** `SELECT avg(close)` returns one row; `SELECT close` then averaging in pandas streams millions.

5. **`argMax` for "value at the latest timestamp" per group.** Faster than `ORDER BY timestamp DESC LIMIT 1` with `GROUP BY`:

   ```sql
   SELECT exchange, market, argMax(close, start) AS latest_close
   FROM api.ohlcv_1m
   WHERE start >= now() - INTERVAL 1 HOUR
   GROUP BY exchange, market;
   ```

6. **No `SELECT *`.** ClickHouse is column-store — name the columns you need.

7. **Constrain `exchange` and `market`** when possible: these are the leading columns of the sort key on most tables, so `WHERE exchange IN (...)` is essentially free.

8. **`SETTINGS max_execution_time = 30`** on exploratory queries — fail fast.

9. **Never `FINAL`.** These tables don't need it and it forces extra merges.

10. **VWAP, not arithmetic mean,** when "average" should weight by volume:

    ```sql
    SELECT sum(close * volume) / sum(volume) AS vwap
    FROM api.ohlcv(candle_duration_in_minutes = 1440)
    WHERE market = 'LINK-USDT'
      AND exchange = 'binance'
      AND start >= now() - INTERVAL 365 DAY;
    ```

## Worked example: 1-year average price of LINK-USDT

**Naive — scans ~hundreds of GB of trades:**

```sql
SELECT avg(price)
FROM api.trade
WHERE market = 'LINK-USDT'
  AND timestamp >= now() - INTERVAL 365 DAY;
```

**Optimized — scans 365 rows:**

```sql
SELECT avg(close)                              AS arith_mean,
       sum(close * volume) / sum(volume)        AS vwap
FROM api.ohlcv(candle_duration_in_minutes = 1440)
WHERE market   = 'LINK-USDT'
  AND exchange = 'binance'
  AND start   >= now() - INTERVAL 365 DAY
SETTINGS max_execution_time = 30;
```

Single-exchange is usually what you want — mixing exchanges blends liquidity profiles and adds noise. If the user *does* want a cross-exchange average, weight by exchange volume:

```sql
SELECT sum(close * volume) / sum(volume) AS cross_vwap
FROM api.ohlcv(candle_duration_in_minutes = 1440)
WHERE market = 'LINK-USDT'
  AND start >= now() - INTERVAL 365 DAY;
```

## Profiling

- `EXPLAIN PLAN <query>` — shows the planner's choices.
- `EXPLAIN ESTIMATE <query>` — reports rows and bytes the scan will read **before** running. Use this to sanity-check expensive queries.
- `SELECT query, read_rows, read_bytes, query_duration_ms FROM system.query_log WHERE event_time > now() - INTERVAL 1 HOUR AND query LIKE '%<your-tag>%' ORDER BY event_time DESC LIMIT 5` — recent query stats (if you have access).

## Anti-patterns to flag in user code

- `ORDER BY <time> DESC LIMIT 1` with `GROUP BY` → use `argMax`.
- `WHERE toDate(start) = today()` → use `start >= today()` (function on the column blocks index use).
- `WHERE market LIKE 'BTC%'` for the latest BTC futures → name the specific market(s) or use `api.future_markets` to enumerate first.
- Joining `api.trade` to itself on `timestamp` without a tight range → almost always a mistake; aggregate first, then join.
