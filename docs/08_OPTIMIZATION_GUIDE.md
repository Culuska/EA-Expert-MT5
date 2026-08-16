# Stage 8 — Optimization Guide

This is a process document, not code. It tells you how to run the MT5
Strategy Tester optimizer against `BREG_EA.mq5` (or Stage 3's virtual
engine for a lighter-weight first pass) without fooling yourself with an
overfit result.

## Optimize per timeframe, never all at once

The project's own premise is that M1, M5, M15, M30, H1 and H4 are
different animals under the same rules — an M1 parameter set will
typically be too loose for M1 noise if borrowed from H1, and an H1
parameter set will typically be too tight to ever trigger on M1's smaller
moves. Optimize with only **one** `Enable_*` timeframe on at a time
(or `Primary_Timeframe` set to that one timeframe), one full pass per
timeframe you intend to trade.

## What to optimize, and sane ranges to start from

Only optimize inputs that materially change *when* a setup is recognized
or where SL/TP sit — not everything the file exposes.

| Input | Why it matters | Suggested range to scan |
|---|---|---|
| `Swing_Left_Bars` / `Swing_Right_Bars` | Controls how "major" a swing point has to be | 2–6, tested together |
| `Minimum_Swing_Distance` | Noise filter on swing prominence | 50–200 (XAUUSD points) |
| `Retest_Max_Bars` | How long you're willing to wait for the retest | 3–10 |
| `Retest_Tolerance_Points` | How close price must come | 40–150 |
| `Engulfing_Min_Avg_Body_Ratio` | How "decisive" the engulf must be | 1.0–1.6 |
| `SL_Buffer_Points` | SL padding beyond the wick | 50–200 |
| `RiskReward` (fallback only) | Only matters when `TP_Method = TP_FIXED_RR`, or as the fallback | 1.5–4.0 |

Leave `Use_Strict_Engulfing = true`, `TP_Method = TP_NEXT_STRUCTURE`,
`Use_HTF_Filter = false`, `Use_Liquidity_Filter = false` fixed during
optimization — those are strategy-definition decisions from Stage 1, not
free parameters to fit to history.

## Optimization criteria — don't just maximize net profit

MT5's default "Balance" optimization criterion will happily hand you a
curve-fit set of inputs that traded 4 times in 2 years for a huge
percentage gain. Use **Custom criterion** or eyeball the full results
table and prefer parameter sets with:

- A reasonable number of trades for the date range (dozens+, not single
  digits) — few trades means the "optimum" is noise.
- Profit factor and win rate that don't collapse under a small nudge to
  a neighboring parameter value (if `Retest_Max_Bars = 5` is great but
  `4` and `6` are both terrible, that's a sign of overfitting, not edge).
- Consistent performance across sub-periods (right-click the report →
  check the equity curve isn't one lucky quarter carrying the whole
  result).

## Walk-forward, not just in-sample

1. Optimize on the first ~70% of your available history.
2. Lock the resulting inputs and run (not optimize) on the remaining
   ~30%, a period the optimizer never saw.
3. If performance degrades sharply out-of-sample, the "optimal" inputs
   were fit to noise — go back to a simpler, less-tuned parameter set.

## Recommended order

1. Run Stage 3 (`03_BREG_Backtest_Engine.mq5`) first for a fast, cheap
   read on raw signal quality (win rate / avg R) per timeframe before
   spending optimizer time on the full execution-and-risk EA.
2. Once a timeframe's virtual stats look genuinely tradeable, optimize
   the small parameter set above on `BREG_EA.mq5` for that timeframe.
3. Repeat per timeframe. Keep a written record of the inputs you land on
   for each — that becomes your live configuration per timeframe (see
   Stage 9/10).
