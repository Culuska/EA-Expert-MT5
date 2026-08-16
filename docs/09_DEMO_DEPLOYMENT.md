# Stage 9 — Demo Deployment Checklist

Once Stage 8's optimization has given you an inputs set per timeframe you
actually trust, this stage is about proving the EA behaves the same way
on a live-streaming demo account as it did in the Strategy Tester — not
about proving profitability again (that was Stage 3/8's job).

## Before you attach it to a demo chart

- [ ] Confirm the EA compiles clean in MetaEditor (F7) — no warnings you
      don't understand.
- [ ] `Debug_Mode = true` for the whole demo period. You want the full
      journal trail.
- [ ] Set `InpMagicNumber` to a value not used by any other EA on this
      account, if you run more than one.
- [ ] Double-check the `LogPointConversions()` output on attach against
      what your demo broker actually shows for XAUUSD digits/spread —
      demo servers sometimes use different quote conventions than live.
- [ ] Set `Max_Spread_Points` and `SL_Buffer_Points` etc. based on what
      you actually observe on *this* broker's demo feed, not just the
      shipped defaults.
- [ ] Decide `Risk_Per_Trade`, `Max_Trades_Per_Day`, `Max_Open_Trades`,
      `Max_Consecutive_Losses` for real — these are trading decisions,
      tell me the numbers and I'll set the inputs.
- [ ] Decide `One_Trade_Total` vs `One_Trade_Per_Timeframe` for how you
      want concurrent signals across timeframes handled.

## What to actively watch during the demo run

- **AutoTrading is enabled** (toolbar button) and the EA's smiley-face
  icon is not red — a common reason "nothing happens" is AutoTrading
  being off, not a bug.
- **Every trade the EA takes**, compared against the chart at the time —
  does the break/retest/engulfing it acted on match what you'd have
  called yourself? This is the same visual check as Stage 2, just now
  under live spread/latency conditions instead of tester conditions.
- **SL/TP placement** on actual filled orders — right-click the position
  → confirm SL sits beyond the engulfing wick as expected, TP sits at the
  structure level the journal says it targeted (or the fixed-R:R
  fallback, with a journal line explaining why).
- **Lot sizing** scales sensibly with your demo balance and
  `Risk_Per_Trade` — not a fixed number.
- **The journal for any repeated warnings** — "insufficient free margin,"
  "invalid stops," "order failed" lines that show up over and over point
  to a broker-specific setting (stop level, minimum lot, filling mode)
  that needs tuning before this ever touches live capital.

## Minimum bar before considering live

There's no universally "correct" number, but as a floor:

- At least a few weeks of demo running across your actual trading
  timeframes, with enough closed trades per timeframe (not just open
  ones) to say something statistically meaningful — a handful of trades
  proves the plumbing works, not that the edge survived contact with
  live spread/slippage.
- No unexplained journal errors in that window.
- Demo results roughly in line with what Stage 3/8 predicted — if demo
  is wildly worse, something about live conditions (spread, slippage,
  broker-specific stop/freeze levels) isn't accounted for and needs
  fixing before Stage 10.
