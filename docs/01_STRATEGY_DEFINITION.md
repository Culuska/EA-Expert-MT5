# Stage 1 — BREG Strategy Definition

This is the source of truth. Every later stage (detector, backtester, live
EA) is judged against *this* document, not the other way around. If the
code ever disagrees with what's written here, the code is wrong.

This is written from the trader's own answers, in trading language, with no
code in it. Where I (the developer) made a technical judgment call because
the trading rule was outcome-based rather than mechanical (e.g. "next
liquidity level" needs a precise scanning method), that's flagged
explicitly as **[implementation note]** so it stays visible and
challengeable — it is not presented as if it were your rule.

## Instrument & timeframes

- **Instrument:** XAUUSD (Gold).
- **Timeframes:** M1, M5, M15, M30, H1, H4 — all active, same rule set
  applied independently on each. No timeframe is a prerequisite for
  another; an M1 signal is exactly as valid as an H4 signal.
- **Sessions:** none excluded. No session filter by default.

## 1. Break

A **Break** is a candle *closing* beyond a prior swing high (bullish) or
swing low (bearish). A wick piercing the level without the candle closing
beyond it does not count.

- No additional strength/momentum requirement on the breakout candle
  itself beyond the close.
- **[implementation note]** "Prior swing high/low" is found mechanically
  via a fractal check: a candle whose high (low) is not exceeded by
  `Swing_Left_Bars` candles before it or `Swing_Right_Bars` candles after
  it, with a minimum prominence (`Minimum_Swing_Distance`) so a flat
  cluster of candles doesn't get treated as "structure." This is a
  standard, defensible mechanical proxy for "the swing point a discretionary
  trader would circle on the chart" — it is not a claim that it's the only
  possible one.

## 2. Retest

After the Break, wait for price to come back into the broken level's zone.

- Just *returning into the zone* counts — no rejection wick, no
  consolidation, no extra confirmation candle required at the retest.
- Must happen within a **few bars** of the break (kept tight on purpose —
  a retest that takes too long to arrive is treated as a different,
  unrelated pullback, not confirmation of this break).
- If price closes back through the level with real conviction before the
  retest (or before the engulfing) — not just a brief wick — the setup is
  abandoned.

## 3. Engulfing

The confirmation candle at/after the retest must be a genuine engulfing
candle, meaning **both** of the following, not just one:

1. Its body fully covers the previous candle's body (a true full-body
   engulf, not a partial overlap).
2. It looks like a **strong, decisive candle** — not just "technically
   bigger than a small previous candle." A candle that only barely,
   technically qualifies against a tiny previous candle is a **weak
   engulfing** and does not count.

A weak engulfing is not scored down — it is simply not recognized as an
engulfing candle yet. The detector keeps watching the next couple of
candles (still within the "few bars after retest" window) for a real one
before giving up on the setup.

## 4. Entry

Enter **the instant the engulfing candle closes** — no waiting for a break
of its high/low, no pullback into it.

## 5. Stop Loss

SL sits beyond the engulfing candle's wick (the low of a bullish engulfing
candle, or the high of a bearish one), plus a small buffer so it isn't
sitting exactly on the wick tick.

## 6. Take Profit

TP targets the **next swing/liquidity level** ahead of price in the trade
direction — not a fixed reward:risk multiple picked in advance.

- **[implementation note]** "Next swing/liquidity level" is implemented as
  the nearest *already-formed* opposing swing high/low (same fractal
  definition as the break level) or the previous day's high/low, whichever
  is closer, ahead of the entry price. This only ever looks at
  already-closed historical bars — it is a target chosen from existing
  structure, not a prediction of future price.
- If no such level exists within a reasonable search window, or the
  nearest one is too close to be worth the risk, TP falls back to a fixed
  reward:risk multiple of the realized SL distance, so every trade still
  gets a valid TP rather than none at all.

## 7. Invalidation

A setup is abandoned (and the detector goes back to looking for a new one)
if:

- Price closes back through the broken level with real conviction, before
  the engulfing confirms.
- The retest doesn't arrive within a few bars of the break.
- The engulfing doesn't arrive (or never qualifies as a real, decisive
  engulf) within a few bars of the retest.

## 8. What is explicitly *not* part of this rule set

- **No liquidity sweep requirement.** A stop-hunt above/below a level
  before the break is not required to trust the break.
- **No higher-timeframe bias filter.** A lower-timeframe BREG setup is not
  checked against, or rejected because of, a higher timeframe's direction.
- **No session restriction.** Every session is tradeable.

These stay available as optional, off-by-default filters in the code
(useful for later experimentation), but they are not part of the rule set
this strategy is defined by, and must never silently gate a trade unless
explicitly turned on.

## Change log

Keep this section updated whenever the rules above change, so the code's
behavior can always be traced back to a specific, dated decision rather
than "it's always worked that way."

| Date | Change |
|---|---|
| 2026-08-16 | Initial definition from trader Q&A. |
