# BREG EA — Break → Retest → Engulfing Expert Advisor (MT5)

A professional, multi-timeframe MetaTrader 5 Expert Advisor implementing the
**BREG** price-action strategy: **BR**eak → Retest → **E**n**g**ulfing → Entry.

File: [`MQL5/Experts/BREG/BREG_EA.mq5`](MQL5/Experts/BREG/BREG_EA.mq5)

## Installation

1. Copy `MQL5/Experts/BREG/BREG_EA.mq5` into your terminal's
   `MQL5/Experts/BREG/` folder (or open it directly from this repo path if
   the repo is checked out inside your MT5 data folder).
2. Open it in MetaEditor and compile (F7). It has no external dependencies
   beyond the standard `Trade\Trade.mqh` include that ships with every MT5
   installation.
3. Attach it to any chart/symbol. The chart's timeframe is irrelevant — the
   EA scans whichever timeframes you enable independently of the chart
   period.

## Why the EA is not "restricted" to any one timeframe

`Enable_M1` … `Enable_H4` each independently turn a timeframe's BREG
detector on or off. `Primary_Timeframe = AUTO` (default) runs the full
BREAK→RETEST→ENGULFING pipeline **separately and simultaneously** on every
enabled timeframe. A setup completing on M1 has no dependency on M5, M15,
H1 or H4 having anything in progress — each timeframe owns its own state
machine, its own break level, its own retest, and its own engulfing check.
Setting `Primary_Timeframe` to a specific value overrides this and restricts
the EA to that single timeframe.

`Use_HTF_Filter` is **off by default**. When off, HTF direction is never
consulted — a bullish M1 BREG setup can fire a BUY even while H1/H4 are
bearish. Turning it on adds an *optional* directional check (`STRICT`
rejects conflicting setups outright; `PREFERENCE` merely withholds the +10
scoring bonus, never blocks the trade).

## Architecture

The EA is organized into named modules mirroring the discretionary BREG
workflow, each implemented as its own function:

| Module | Responsibility |
|---|---|
| `InitializeEA` | Builds the active timeframe list, creates ATR/MA indicator handles, configures `CTrade`, parses the manual news list. |
| `DetectSwingStructure` / `FindSwingHigh` / `FindSwingLow` | Fractal swing detection with `Swing_Left_Bars`/`Swing_Right_Bars` confirmation and a `Minimum_Swing_Distance` prominence filter so noise isn't mistaken for structure. Adapts per timeframe because the same left/right/distance inputs are applied independently to each timeframe's own bar data. |
| `DetectBreak` / `ValidateBreak` / `CreateSetupFromBreak` | Confirms a **closed-bar** break beyond the swing level by at least `Minimum_Break_Distance` points (wicks alone never qualify), optionally requires displacement, records the break level/time, and opens a new `BregSetup` record. |
| `DetectRetest` / `ValidateRetest` | Waits (up to `Retest_Max_Bars`) for price to return into a tolerance zone around the broken level (`Retest_Tolerance_Points`, bounded by `Retest_Min_Depth`/`Retest_Max_Depth`). A strong closed-bar push back through the level by more than the tolerance + `Retest_Invalidation_Buffer_Points` cancels the setup early. |
| `DetectEngulfing` / `EvaluateEngulfing` / `CheckIntrabarEngulfing` | Confirms a full-body engulfing candle within `Engulfing_Max_Bars_After_Retest` bars of the retest. `Use_Strict_Engulfing` + `Engulfing_Min_Body_Ratio` gate the minimum body-size ratio. The intrabar variant re-runs the same check against the still-forming bar for `Entry_Mode = INTRABAR_AGGRESSIVE`. |
| `CalculateSetupScore` | 0–110 point score: Break +30, Retest quality +5..+25, Engulfing quality +12..+25, HTF alignment +10, Liquidity sweep +10, Displacement +10. Setups below `Minimum_Setup_Score` are invalidated instead of traded. |
| `CheckHTFContext` | Optional HTF EMA/price bias check (see above). |
| `CheckLiquidity` | Optional PDH/PDL, equal-highs/lows and wick-sweep detection feeding the scoring bonus only — never a hard filter. |
| `CalculateStopLoss` / `CalculateTakeProfit` | Four SL placement modes (`STRUCTURE`, `ENGULFING_WICK`, `RETEST_SWING`, `ATR`) plus buffer; TP derived purely from the realized SL distance × `RiskReward`. |
| `CalculateLotSize` | Uses `SYMBOL_TRADE_TICK_VALUE`/`SYMBOL_TRADE_TICK_SIZE`/volume step-min-max from `SymbolInfoDouble` — no hard-coded per-symbol assumptions, works on any instrument. |
| `CheckRiskLimits` / `CanOpenNewTrade` | Enforces `Max_Trades_Per_Day`, `Max_Open_Trades`, `Max_Consecutive_Losses`, and the `One_Trade_Total` vs `One_Trade_Per_Timeframe` policy (each timeframe trades under its own `MagicNumber + tfIndex`, which is what makes per-timeframe accounting possible). |
| `CheckSpread` / `CheckSession` | Optional spread ceiling and London/New York/Asian session windows. |
| `ExecuteTrade` | Final permission/spread/session/news gate, stop-level clamping, volume normalization, and the actual `CTrade` market order. |
| `ManageTrade` | Sanity-checks open EA positions each tick. |
| `DrawSetup` / `DrawDashboard` | Chart objects for BOS/RETEST/ENGULFING/BUY/SELL/SL/TP plus a live per-timeframe dashboard panel. |
| `SendAlert` | Routes to `Print`, `Alert`, and/or `SendNotification` depending on `Debug_Mode`/`Enable_Alerts`/`Enable_Push_Notifications`. |
| `ResetSetup` / `InvalidateSetup` | Returns a timeframe's state machine to `IDLE` after a trade or a cancellation, optionally clearing invalidated-setup drawings. |

## State machine

Each enabled timeframe runs its own instance of:

```
IDLE → BREAK_DETECTED → WAITING_FOR_RETEST → RETEST_DETECTED →
WAITING_FOR_ENGULFING → ENTRY_READY → TRADE_EXECUTED → (back to IDLE)
                                              ↘ SETUP_INVALIDATED → IDLE
```

Transitions are logged with `Debug_Mode = true`, e.g.:

```
[BREG][M5] State: IDLE -> BREAK_DETECTED
[BREG][M5] State: BREAK_DETECTED -> WAITING_FOR_RETEST
[BREG][M5] Retest detected @ 1.09231 (depth=12.0 pts)
[BREG][M5] State: RETEST_DETECTED -> WAITING_FOR_ENGULFING
[BREG][M5] Bullish engulfing detected
[BREG][M5] Setup score = 85
[BREG][M5] State: WAITING_FOR_ENGULFING -> ENTRY_READY
[BREG][M5] State: ENTRY_READY -> TRADE_EXECUTED | BUY executed @ 1.09255 SL=1.09180 TP=1.09480 lot=0.34
```

## Non-repainting guarantees

* All swing/break/retest/engulfing evaluation reads only closed bars
  (`shift >= 1`), triggered once per timeframe exactly when a new bar opens
  (`iTime(symbol, tf, 0)` changing is the new-bar signal).
* `Entry_Mode = CLOSED_CANDLE` (default) only arms `ENTRY_READY` after the
  engulfing candle has fully closed; the order is sent on the following
  tick(s), i.e. at/near that next candle's open.
* `Entry_Mode = INTRABAR_AGGRESSIVE` is the sole, explicitly opt-in
  exception: it evaluates the still-forming bar every tick. This is by
  design more aggressive/less deterministic and is documented as such.
* Nothing is written to history after the fact — invalidated or executed
  setups are reset, not rewritten.

## Duplicate-signal prevention & multi-timeframe independence

Each `BregSetup` gets a unique ID
(`Symbol_TF_DIR_BreakUnixTime`), and each timeframe trades under its own
magic number (`InpMagicNumber + timeframe_index`). Because state only
advances forward and a setup is reset the instant it is traded or
invalidated, the same engulfing candle can never fire two trades. Because
each timeframe owns an independent `BregSetup` and magic sub-number, an M1
BUY, an M5 BUY and an H1 BUY can all be genuinely independent trades (subject
to `One_Trade_Total` / `One_Trade_Per_Timeframe` and the other risk caps).

## Backtesting notes

Every input that shapes swing/retest/engulfing behaviour
(`Swing_Left_Bars`, `Swing_Right_Bars`, `Minimum_Swing_Distance`,
`Minimum_Break_Distance`, `Retest_*`, `Engulfing_*`) is exposed so each
timeframe can — and should — be optimized separately in the Strategy
Tester. A parameter set tuned for H1 structure will typically be far too
loose for M1 noise and vice versa; nothing in the EA assumes otherwise.
