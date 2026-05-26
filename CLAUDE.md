# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository contents

Two standalone MetaTrader 5 Expert Advisors (`.mq5`) at the repo root. There is no build system, package manager, test suite, or CI — each file is a self-contained EA compiled and run inside MT5.

- `TrendFollower_EMA_EA.mq5` — EURUSD M5, EMA crossover + RSI filter + ATR-based dynamic TP + ATR trailing stop + time-based close. Gated to London/NY sessions (GMT).
- `TrendFollower_BTC_EA.mq5` — BTCUSD M15 variant of the above, runs 24/7, with wider pip/spread tolerances and 2-digit-broker awareness (`pointMultiplier = 100`).

## Build, deploy, and test

There are no shell-side build commands. Workflow is MetaEditor-driven:

- **Compile**: open the `.mq5` in MetaEditor (F4 from MT5) and press F7, or run from a shell:
  `"C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"<absolute-path>.mq5" /log`
  The compiler emits a `.ex5` next to the source. Compile-log path is printed at the end.
- **Deploy**: copy/symlink the `.mq5` (or just the `.ex5`) into the MT5 terminal's `MQL5/Experts/` directory. The Golden Strategist EA also requires `ATRStopLoss_Ind.ex5` in `MQL5/Indicators/`.
- **Test a single EA**: in MT5, open Strategy Tester (Ctrl+R), pick the EA, set Symbol/Timeframe to match the EA's intended instrument (the TrendFollower EAs hardcode their timeframe via `PERIOD_M5` / `PERIOD_M15` in `iMA`/`iRSI`/`iATR` calls — changing the chart timeframe alone won't change indicator timeframes), set the date range, and run. There is no per-test isolation; iterate by editing inputs in the Tester inputs tab rather than the source.
- **Live/demo run**: drag the EA from the Navigator onto a chart of the correct symbol; the chart timeframe is independent of the indicator timeframes baked into the source.

There is no linter or formatter. The MQL5 compiler is the only static checker.

## Shared architecture (TrendFollower family)

The two TrendFollower EAs are near-siblings and share a layout worth knowing before editing either one:

- **Input groups** declared with `input group "=== ... ==="` and an `Inp`-prefixed naming convention for every parameter. Keep new params in an appropriate group; the groups are how users navigate the Tester inputs panel.
- **Indicator handles** (`handleEmaFast`, `handleEmaSlow`, `handleRsi`, `handleAtrTp`, `handleAtrTrail`) are created once in `OnInit` against an explicit timeframe constant and released in `OnDeinit`. The timeframe lives in the `iMA`/`iRSI`/`iATR` calls, **not** as an input — changing the strategy's timeframe means editing those calls in three places.
- **Pip math is digits-aware.** `pointMultiplier` is set from `SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)`: 3/5-digit FX → 10, 2-digit BTC → 100, else 1. `pipValue = _Point * pointMultiplier`. All input distances are in pips; convert to price with `* pipValue` (never use `_Point` directly for pip distances).
- **Tick loop split.** `OnTick` runs position management (time-close, trailing) **every tick**, then guards entry logic behind a closed-bar check using `lastBarTime = iTime(_Symbol, <TF>, 0)`. New entry signals only fire on the open of a new bar; never move trailing or time-close logic behind that guard.
- **Magic number isolation.** Every position-iteration loop filters on both `PositionInfo.Symbol() == _Symbol` **and** `PositionInfo.Magic() == InpMagicNumber`. Each EA has its own magic (`20240101` for EURUSD, `20240202` for BTC) so multiple EAs can coexist on one account. New EAs must pick a unique magic.
- **Signal pipeline.** `GetEntrySignal` (EMA crossover + close-vs-slow-EMA filter) returns `ORDER_TYPE_BUY`/`SELL` or `(ENUM_ORDER_TYPE)-1` for "no signal". `ApplyRsiFilter` can downgrade a signal to `-1`. Use the `-1` sentinel rather than introducing a separate "no signal" enum.
- **TP is dynamic, SL is fixed.** `CalculateDynamicTP` reads ATR from the closed bar (`CopyBuffer(handleAtrTp, 0, 1, 1, …)`), multiplies by `InpAtrTpMultiplier`, and clamps between `InpMinTpPips` and `InpMaxTpPips`. SL is always `InpStopLossPips * pipValue`. R/R is logged at entry.
- **Trailing only after `InpMinProfitPips`,** and only advances if the new SL improves the previous one by at least `InpTrailingStep * pipValue` — prevents per-tick SL churn.
- **Time-close has a profit override.** A position older than `InpMaxMinutes` is closed *unless* current pips ≥ `InpMinProfitToKeep`, in which case it's left to the trailing stop. Both branches log with the `[TIEMPO]` tag.
- **Log tag prefixes** (Spanish, single-bracket): `[INFO]`, `[ERROR]`, `[WARN]`, `[TRADE]`, `[ATR-TP]`, `[RSI]`, `[TRAIL]`, `[TIEMPO]`. Match these when adding new log lines so journal filtering keeps working.

## Notes when modifying

- The Spanish-language comments and log strings are intentional; preserve language when editing existing strings, but new code can match the surrounding file.
- When adding indicators, create the handle in `OnInit`, check for `INVALID_HANDLE`, release in `OnDeinit`, and read with `ArraySetAsSeries(buf, true); CopyBuffer(h, 0, 1, n, buf)` to read closed-bar values (offset `1`, not `0`).
