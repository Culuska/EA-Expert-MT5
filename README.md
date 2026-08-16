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

## Calibrated for XAUUSD (Gold)

All "points" inputs (`SL_Buffer_Points`, `Retest_Tolerance_Points`,
`Max_Spread_Points`, etc.) are calibrated for a typical **2-digit XAUUSD
quote** (point = $0.01, e.g. `2650.23`), which is what most MT5 brokers use.
A few brokers quote gold with 3 decimals instead — the same raw "points"
input then means a different dollar amount.

You don't have to guess which one your broker uses: with `Debug_Mode = true`,
`OnInit` prints every points-based input converted into real price terms
for whatever symbol is actually attached, e.g.:

```
[BREG] XAUUSD: Digits=2 Point=0.01
[BREG]   SL_Buffer_Points             = 100 pts (~1.00)
[BREG]   Max_Spread_Points            = 300 pts (~3.00)
[BREG]   Current live spread          = 180 pts (~1.80)
```

Check that log line on first attach and adjust any input that doesn't
match how you'd naturally describe that distance in dollars on your
broker's chart.

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

## Tuned to how you actually trade

The defaults below are calibrated to the trader's stated rules, not generic
placeholders — everything stays a configurable input if you want to
experiment, but this is the out-of-the-box behavior:

* **Break** = a candle *closing* beyond a prior swing high/low. No extra
  strength/momentum requirement beyond the close itself (`Minimum_Break_Distance`
  is a tiny noise filter, not a strictness knob).
* **Retest** = price simply returning into the tolerance zone around the
  broken level, within a few bars (`Retest_Max_Bars = 5`) — no rejection
  wick or extra confirmation required at the retest itself.
* **Engulfing** must (a) fully engulf the previous candle's body **and**
  (b) look like a genuinely strong, decisive candle relative to recent
  price action — not just technically bigger than a tiny previous candle.
  That second condition is `Engulfing_Min_Avg_Body_Ratio`, enforced whenever
  `Use_Strict_Engulfing = true` (the default). A candle that fails either
  check is not a "weak engulfing" that gets scored down — it simply isn't
  recognized as an engulf yet, so the EA keeps watching the next couple of
  bars (`Engulfing_Max_Bars_After_Retest`) before giving up on the setup.
* **Entry** fires the instant the engulfing candle closes (`Entry_Mode =
  CLOSED_CANDLE`, the default) — no waiting for a break of its high/low.
* **Stop Loss** defaults to `SL_Method = SL_ENGULFING_WICK`: beyond the
  engulfing candle's wick, plus `SL_Buffer_Points`.
* **Take Profit** defaults to `TP_Method = TP_NEXT_STRUCTURE`: the EA scans
  already-closed history for the nearest *unbroken* opposing swing high/low
  (same fractal validity rules as break detection) or the previous day's
  high/low, ahead of price in the trade direction, and aims there instead of
  a fixed multiple. If no such level clears `TP_Min_Structure_RR` (default
  1.0R) within `TP_Structure_Lookback_Bars`, it falls back to a fixed
  `RiskReward` multiple of the realized SL distance, so every trade still
  gets a valid TP.
* **Liquidity sweeps and higher-timeframe bias are not part of your rule
  set** — `Use_Liquidity_Filter` and `Use_HTF_Filter` stay off by default;
  the corresponding scoring bonuses simply contribute 0 rather than gating
  entries.
* **Every timeframe, every session** — `Enable_M1` through `Enable_H4` are
  all on and `Use_Session_Filter` is off by default. The same rule set
  (same inputs) is applied independently and identically on every enabled
  timeframe; nothing changes the logic between M1 and H4 except the bars
  it's reading.

Because the liquidity/HTF/displacement scoring bonuses are off in this
configuration, `Minimum_Setup_Score` defaults to `60` rather than `70` — the
realistic ceiling with only Break+Retest+Engulfing active is 80, so 60 stays
selective (requires at least a moderate retest and a genuinely decisive
engulf) without silently rejecting valid setups for bonus points you never
asked for.

## Architecture

The EA is organized into named modules mirroring the discretionary BREG
workflow, each implemented as its own function:

| Module | Responsibility |
|---|---|
| `InitializeEA` | Builds the active timeframe list, creates ATR/MA indicator handles, configures `CTrade`, parses the manual news list. |
| `DetectSwingStructure` / `FindSwingHigh` / `FindSwingLow` / `IsValidSwingHigh` / `IsValidSwingLow` | Fractal swing detection with `Swing_Left_Bars`/`Swing_Right_Bars` confirmation and a `Minimum_Swing_Distance` prominence filter so noise isn't mistaken for structure. Adapts per timeframe because the same left/right/distance inputs are applied independently to each timeframe's own bar data. The validity check is factored out so it can be reused by both break detection and TP structure-target scanning. |
| `DetectBreak` / `ValidateBreak` / `CreateSetupFromBreak` | Confirms a **closed-bar** break beyond the swing level by at least `Minimum_Break_Distance` points (wicks alone never qualify), optionally requires displacement, records the break level/time, and opens a new `BregSetup` record. |
| `DetectRetest` / `ValidateRetest` | Waits (up to `Retest_Max_Bars`) for price to return into a tolerance zone around the broken level (`Retest_Tolerance_Points`, bounded by `Retest_Min_Depth`/`Retest_Max_Depth`). A strong closed-bar push back through the level by more than the tolerance + `Retest_Invalidation_Buffer_Points` cancels the setup early. |
| `DetectEngulfing` / `EvaluateEngulfing` / `CheckIntrabarEngulfing` | Confirms a full-body engulfing candle within `Engulfing_Max_Bars_After_Retest` bars of the retest. `Use_Strict_Engulfing` gates both `Engulfing_Min_Body_Ratio` (vs. the previous candle) and `Engulfing_Min_Avg_Body_Ratio` (vs. recent average candle size, filtering out "weak" engulfs). The intrabar variant re-runs the same check against the still-forming bar for `Entry_Mode = INTRABAR_AGGRESSIVE`. |
| `CalculateSetupScore` | 0–110 point score: Break +30, Retest quality +5..+25, Engulfing quality +20..+25 (12 only reachable with `Use_Strict_Engulfing = false`), HTF alignment +10, Liquidity sweep +10, Displacement +10. Setups below `Minimum_Setup_Score` are invalidated instead of traded. |
| `CheckHTFContext` | Optional HTF EMA/price bias check (see above). |
| `CheckLiquidity` | Optional PDH/PDL, equal-highs/lows and wick-sweep detection feeding the scoring bonus only — never a hard filter. |
| `CalculateStopLoss` / `CalculateTakeProfit` / `FindNextTPTarget` | Four SL placement modes (`STRUCTURE`, `ENGULFING_WICK`, `RETEST_SWING`, `ATR`) plus buffer. TP defaults to the nearest qualifying opposing structure/liquidity level (`TP_NEXT_STRUCTURE`), falling back to `RiskReward` × realized SL distance when no level qualifies or `TP_Method = TP_FIXED_RR`. |
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

## Production hardening (technical, not trading decisions)

These are handled automatically and require no trading input from you:

* **Margin validation** (`ClampLotToFreeMargin`) — the risk-based lot size is
  checked against `OrderCalcMargin` before sending. If free margin can't
  support the full risk-sized lot, it's scaled down (with a small safety
  buffer) rather than blindly sent and rejected; if even the broker minimum
  lot isn't affordable, the setup is invalidated with a clear log line
  instead of silently failing.
* **Broker trade-mode awareness** (`CheckSymbolTradeMode`) — respects
  `SYMBOL_TRADE_MODE_DISABLED`/`CLOSEONLY`/`LONGONLY`/`SHORTONLY` (some
  brokers flip these around rollover, high-impact news, or low-liquidity
  hours). A SELL setup is simply skipped during a long-only window rather
  than erroring out.
* **Order-failure recovery** (`SendOrderWithRecovery`) — a requote or
  "price changed" re-prices against the current market and retries exactly
  once; "invalid stops" widens SL/TP by one extra stop-level increment and
  retries exactly once. Anything else (including a second failure) is left
  as `ENTRY_READY` and naturally retried on the next tick through the same
  spread/news/session gates — except `TRADE_RETCODE_NO_MONEY`, which
  invalidates the setup outright since retrying won't change the margin
  situation.
* **Dashboard refresh throttling** (`Dashboard_Refresh_Seconds`, default 1s)
  — chart-object updates and `ChartRedraw` calls are time-throttled instead
  of firing on every tick, which matters on M1 in live trading or during
  tick-heavy Strategy Tester runs.

## Backtesting notes

Every input that shapes swing/retest/engulfing behaviour
(`Swing_Left_Bars`, `Swing_Right_Bars`, `Minimum_Swing_Distance`,
`Minimum_Break_Distance`, `Retest_*`, `Engulfing_*`) is exposed so each
timeframe can — and should — be optimized separately in the Strategy
Tester. A parameter set tuned for H1 structure will typically be far too
loose for M1 noise and vice versa; nothing in the EA assumes otherwise.

## Testing & validation procedure

**Step 1 — Compile.** Open the file in MetaEditor and press F7. Fix any
compile errors shown (there shouldn't be any — this was written and
statically reviewed carefully, but MetaEditor's compiler is the real,
final check; I don't have one available in this environment).

**Step 2 — Visual single-timeframe pass.** In Strategy Tester, pick one
symbol, set `Enable_M1..Enable_H4` so only one timeframe is on, model
"Every tick based on real ticks" (most accurate), a date range with a few
weeks of data, and tick "Visual mode." Watch the chart objects appear in
the right order — BOS line, then RETEST text, then ENGULFING text, then
the BUY/SELL arrow with dotted SL/TP lines — and read the `Debug_Mode`
journal log alongside it. Confirm the sequence never jumps ahead of the
candle currently closing (that would indicate a repaint bug — it shouldn't
happen here, since every decision reads `shift >= 1`, but this is the way
to catch it if something regresses).

**Step 3 — Repeat per timeframe.** Do step 2 once per timeframe you intend
to trade (M1, M5, M15, M30, H1, H4 — independently, not all at once yet).
Expect very different trade *frequency* and win/loss character between
them; that's normal and expected, not a bug — an M1 parameter set is
inherently noisier than an H1 one even with the exact same rules, per the
project's own assumption that no single tuning generalizes across
timeframes.

**Step 4 — Multi-timeframe pass.** Re-enable all the timeframes you plan
to run live simultaneously and re-run the same range. Watch the dashboard
panel to confirm each timeframe really is progressing through its own
state independently (e.g. M1 sitting in `WAITING_FOR_ENGULFING` while H1
is still `IDLE`). Check `One_Trade_Total` vs `One_Trade_Per_Timeframe`
behaves as expected for your account size.

**Step 5 — Sanity-check trade mechanics.** For a handful of individual
trades, right-click → "trade properties" (or check the journal line) and
manually verify: SL sits beyond the engulfing candle's wick by
`SL_Buffer_Points`; TP sits at the nearest structure/liquidity level (or a
sensible fixed-R:R fallback when the journal says so); lot size scales
with `Risk_Per_Trade` and your test balance, not a fixed number.

**Step 6 — Broker realism.** Set a realistic spread/commission model for
your broker (Tester → symbol settings). `Max_Spread_Points = 300` (~$3.00)
is a reasonable starting ceiling for XAUUSD on a 2-digit quote, but gold
spreads vary a lot by broker/account type (raw ECN vs. standard) and blow
out around rollover and high-impact news — watch the `Current live spread`
line `LogPointConversions()` prints on attach against what you actually see
on your broker's XAUUSD chart, and tighten or loosen accordingly.

**Step 7 — Forward test on a demo account** for at least a few weeks
before considering live capital, with `Debug_Mode = true` so you have a
full journal trail to review setups against your own chart reading.

## Production-readiness checklist

| Item | Status |
|---|---|
| Compiles without errors | Statically reviewed line-by-line (brace/paren balance, every function call resolved, every signature checked against MQL5 documentation); **please confirm with an actual F7 compile** — no MQL5 compiler is available in this environment. |
| Function signatures | Verified against MQL5/CTrade documentation. |
| Symbol properties | Lot sizing, SL/TP, and margin checks all read live `SymbolInfoDouble`/`SymbolInfoInteger` — nothing hard-coded per-symbol. |
| Volume normalization | `NormalizeVolume()` respects `SYMBOL_VOLUME_MIN/MAX/STEP`. |
| Stop-level requirements | Enforced in `ExecuteTrade` via `SYMBOL_TRADE_STOPS_LEVEL` before sending. |
| Trading permissions | `MQL_TRADE_ALLOWED` / `TERMINAL_TRADE_ALLOWED` / `ACCOUNT_TRADE_ALLOWED` / `SYMBOL_TRADE_MODE` all checked. |
| Duplicate entries | Each setup carries a unique ID and is reset the instant it trades or invalidates; forward-only state machine. |
| Multi-timeframe logic | Independent `BregSetup` + magic sub-number per timeframe. |
| Strategy Tester compatibility | Non-repainting design (closed-bar only) is what makes tester results meaningful; see steps above. |
| Margin / free-margin validation | `ClampLotToFreeMargin` + `OrderCalcMargin`. |
| Order-failure handling | `SendOrderWithRecovery` (bounded retry on requote/invalid-stops), no-money hard-stops the setup. |
