# Stage 10 — Live Deployment Checklist

This is the last gate, and it's deliberately the strictest one. Nothing
here is optional because "it worked in demo" — live introduces real
slippage, real emotions, and real consequences that demo can't fully
simulate.

## Go/no-go criteria (all of these, not some)

- [ ] Stage 9's demo bar has actually been met — a real closed-trade
      sample, not just open positions, with no unexplained journal
      errors.
- [ ] You have personally reviewed a sample of the demo trades against
      the chart and agree each one was a real BREG setup by your own
      eye, not just "the EA said so."
- [ ] `Risk_Per_Trade` reflects money you can genuinely afford to lose —
      re-confirm this number specifically for live capital; it's common
      to run a larger risk % on demo "because it's not real" and forget
      to dial it back down.
- [ ] `Max_Consecutive_Losses` and `Max_Trades_Per_Day` are set to values
      you'd actually be comfortable hitting in a single bad week.

## Infrastructure

- [ ] The EA runs on something that stays online 24/5 without your
      laptop's sleep/network interruptions — a VPS near your broker's
      server, or a dedicated always-on machine. A live EA that drops
      offline mid-trade (no trailing, no manual intervention possible)
      is a real risk, not a hypothetical one.
- [ ] Broker's live XAUUSD contract specs (digits, spread, stop level,
      minimum lot, margin requirements) have been confirmed to match
      what `LogPointConversions()` reports on the live chart — live and
      demo servers occasionally differ.
- [ ] `InpMagicNumber` doesn't collide with any other EA/system running
      on the same live account.

## Start small, scale deliberately

- [ ] First live week(s) at the smallest sensible lot/risk size, purely
      to confirm order execution, fills, and journal behavior match
      demo — not to prove profitability again.
- [ ] Only scale `Risk_Per_Trade` upward after a further live track
      record you're personally comfortable with, on your own timeline —
      there's no fixed number of trades that makes this automatic.

## Ongoing monitoring (this doesn't stop at "go live")

- [ ] `Debug_Mode` stays on, or at minimum the journal is reviewed
      regularly — an EA left completely unattended is how a broker-side
      change (spread widening, a swap/rollover quirk, a symbol
      specification change) goes unnoticed until it's expensive.
- [ ] Revisit Stage 8's optimization periodically (e.g. quarterly) —
      markets drift, and a parameter set that fit past XAUUSD volatility
      isn't guaranteed to stay fit indefinitely. This is exactly why
      Stage 1's written definition matters: re-optimizing later means
      re-tuning numbers against a fixed rule set, not re-litigating what
      "a valid engulfing" means every time.
- [ ] Any change to Stage 1's actual rules (not just parameter values)
      should be written back into `docs/01_STRATEGY_DEFINITION.md` first,
      dated, with the code change following it — not the other way
      around.
