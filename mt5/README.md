# ANT DISCIPLE — MT5 expert advisor

An indicator-free XAUUSD/XAGUSD price-action EA for MetaTrader 5, built in the same shape as the
"Black Dragon" chart you sent: a per-side control panel on the chart, blue entry arrows, orange dots
where partial profits are banked, break-even lock and a trailing stop.

**No RSI, no MACD, no moving averages, no stochastic, no Bollinger, no "signal" dashboard.**
Every decision comes from raw OHLC bars.

> File: [`ANT_DISCIPLE.mq5`](ANT_DISCIPLE.mq5) — source code.
> Preset: [`ANT_DISCIPLE_XAUUSD_M5.set`](ANT_DISCIPLE_XAUUSD_M5.set).
> Logic self-check: [`tools/logic_selfcheck.py`](tools/logic_selfcheck.py).

### Read this before you put it on a $30 account

On a **standard** gold contract, 0.01 lots = 1 oz, so a $1 price move = $1 P/L. The minimum stop this
EA will use is 200 points = **$2.00**, which means the smallest possible risk per trade is about
**$2**. On a $30 balance that is **6.7% per trade** — you are out after four normal losses in a row.

At the default 1% risk ($0.30) the broker minimum lot is *too big* for the risk, so the EA **refuses
to open the trade** and prints exactly why:

```
entry skipped: broker minimum lot 0.01 with this stop (2.00) risks 2.00 = 6.67% of balance.
Raise InpRiskPercent, use a cent account, or set InpAllowMinLotFallback=true.
```

Your three honest options:

1. **Cent / micro account** (`XAUUSD.c`, `XAUUSDm`, …) — 0.01 lots there is ~100× smaller. This is
   the right way to test $30 without pretending $30 is a real risk budget.
2. **`InpAllowMinLotFallback = true`** — the EA trades 0.01 anyway and logs the real risk. Fine on
   demo, brutal on a live $30 account.
3. **More balance** — at $2,000 the default settings size normally, and partials actually work
   (you need ≥0.03 lots for that, see §4).

---

## 1. Install (5 minutes)

1. On Windows (or macOS with the MT5 app), open MetaTrader 5 → **File → Open Data Folder**.
2. Copy `ANT_DISCIPLE.mq5` into `MQL5/Experts/` (you can make a subfolder, e.g. `MQL5/Experts/ANT/`).
3. In MT5 press **F4** (MetaEditor), find the file in the Navigator, press **F7** to compile.
   You should get `0 errors, 0 warnings` and a fresh `ANT_DISCIPLE.ex5` next to the source.
4. Back in MT5, right-click **Expert Advisors → Refresh**. Drag **ANT DISCIPLE** onto a
   **XAUUSD M5** chart.
5. In the dialog tick **Allow Algo Trading**, then make sure the **Algo Trading** toolbar button is green.
6. Optional: **load the preset** — in the EA dialog press *Load* and pick
   `ANT_DISCIPLE_XAUUSD_M5.set` (or use **Strategy Tester** → *Inputs* → *Load*).

There is no `.ex5` in this repo on purpose: an expert advisor only runs after *your* MetaEditor
compiles it, and a compiled file built against another terminal build can refuse to load. Source is
the portable artifact — one F7 press gives you a working bot.

---

## 2. The panel

```
ANT DISCIPLE   price action engine - no RSI / MACD / MA
[ BUY ON ] [ CLOSE BUY ] [ PAUSE OFF ]   [ SELL ON ] [ CLOSE SELL ] [ PAUSE OFF ]   [ NEW CYCLE ]
Buy profit: 0.00      Sell profit: 0.00      Daily profit: 0.00
XAUUSD M5 | ATR 0.84 | spread 22 pts | open L0 / S0 | day 0.00% | TP 0.80R / 1.50R / 2.60R | status
```

| Button | What it does |
|---|---|
| **BUY ON / BUY OFF** | Master switch for **new long entries**. Open longs keep being managed. |
| **CLOSE BUY** | Market-closes every long this EA owns on this symbol. |
| **PAUSE OFF / PAUSED** | Freezes the long side completely — no new longs **and** no management (SL/TP stay where the broker has them). Use it when you want to babysit a trade by hand. |
| **SELL ON / SELL OFF** | Same as BUY ON/OFF for shorts. |
| **CLOSE SELL** | Market-closes every short. |
| **PAUSE OFF / PAUSED** | Freezes the short side. |
| **NEW CYCLE** | Closes everything, wipes the EA's per-ticket state and daily counters, re-arms both sides. |

Only positions carrying the EA's **magic number** on **this symbol** are ever touched, so manual
trades and other EAs on the same account are safe.

---

## 3. How it decides to trade (the whole engine)

Everything is evaluated **once per closed bar**, never intrabar, so a forming candle can't fake a
signal.

**Volatility unit.** True range is measured directly from OHLC over `InpATRPeriod` bars. This is not
an indicator — it's the average of `max(high-low, |high-prevClose|, |low-prevClose|)` computed in the
EA. It is used for stop distance and lot size only, never as a buy/sell signal.

**Engine A — range break continuation.**
The last closed bar closes **outside** the high/low of the previous `InpBreakoutBars` bars, its body
is at least `InpMinBodyATR × TR`, and it is not already stretched more than `InpMaxExtensionATR × TR`
past the range. Big body, close at the extreme = continuation.

**Engine B — liquidity sweep rejection.**
The last closed bar **raids** the low of the previous `InpSweepBars` bars (stop hunt / wick below the
range) but then closes bullish, back above the midpoint of its own range, with a lower wick at least
`InpWickRatio × body`. That is a failed breakdown, so the EA buys the failure. Mirror image for shorts.

**Hard rejects** (no trade regardless of signal): bar range > `InpMaxBarATR × TR` (news spike),
spread > `InpMaxSpreadPoints`, outside session hours, weekend / late Friday, daily limit already hit,
cooldown bars since the last entry on that side, max trades per side/total.

**Optional trend filter** (`InpUseTrendFilter`, off by default): longs only if the last close is above
the close `InpTrendBars` bars ago.

---

## 4. How it manages a trade (the part that matters)

Risk is defined **once**, at entry: `SL = TR × InpSL_ATR` (clamped by `InpMinSLPoints` /
`InpMaxSLPoints`). That distance is the **R** unit and it is stored per ticket, so it survives a
terminal restart, timeframe switch or recompile.

| Stage | Trigger | Action |
|---|---|---|
| TP1 | price reaches `InpTP1_R × R` (0.80R) | close `InpTP1Pct`% (40%), move SL to entry ± `InpBE_OffsetPoints` (**break-even lock**), orange dot on the chart |
| TP2 | price reaches `InpTP2_R × R` (1.50R) | close `InpTP2Pct`% of the remainder (30%), SL tightened to TP1, orange dot |
| TP3 | price reaches `InpTP3_R × R` (2.60R) | broker-side take profit closes the runner |
| Trailing | from stage `InpTrailAfterStage`, once price is `InpTrailStartR × R` in profit | SL follows price at `InpTrailPoints`, only ever tightening by at least `InpTrailStepPoints`; never worse than break-even after TP1 |
| Time stop | position older than `InpMaxBarsInTrade` bars **and** not in profit | closed |

The broker's stop-level and freeze-level are respected before every modify (`SafeModify`), so you
won't get "invalid stops" rejections on symbols with a wide minimum distance.

**What it deliberately does NOT do:** no martingale, no lot doubling, no grid, no averaging down, no
hedging-recovery. Those are the mechanisms that turn a 90% win rate into a blown account — one
recovery sequence eats the previous twenty wins. Every loss here is a fixed, pre-known R.

**Quantity note.** Partial closes need at least `3 × SYMBOL_VOLUME_MIN` to be meaningful, i.e.
**0.03 lots** for a standard gold account. At the 0.01 minimum lot the EA simply skips the partials and
gives you break-even + trailing instead — same protection logic, one smaller unit.

---

## 5. Key inputs

| Input | Default | Notes |
|---|---|---|
| `InpMagic` | 20261025 | Unique per chart. Two EAs with the same magic on the same symbol will fight. |
| `InpEntryMode` | Both | 0 = breakout only, 1 = sweep only, 2 = both. |
| `InpATRPeriod` | 14 | Volatility lookback, closed bars. |
| `InpBreakoutBars` | 12 | Size of the range being broken (M5: 1 hour). |
| `InpMinBodyATR` | 0.55 | Conviction filter on the signal candle. |
| `InpSweepBars` | 10 | Range whose extreme must be raided for a sweep entry. |
| `InpWickRatio` | 1.20 | Wick-to-body requirement for rejection. |
| `InpLotMode` | Risk % | 0 = fixed lot, 1 = risk %, 2 = lot per balance block. |
| `InpRiskPercent` | 1.0 | Of **balance**, per trade. |
| `InpAllowMinLotFallback` | false | Trade the minimum lot when the risk calculation is smaller than it. Refuse is the safe default. |
| `InpSL_ATR` / `InpMinSLPoints` | 1.6 / 200 | Gold 2-digit: 200 points = $2.00. On a 3-digit gold symbol multiply point inputs by 10 (the EA warns at startup). |
| `InpTP1_R` / `InpTP2_R` / `InpTP3_R` | 0.80 / 1.50 / 2.60 | Must be strictly increasing (the EA auto-corrects and logs if not). |
| `InpTP1Pct` / `InpTP2Pct` | 40 / 30 | % of position, then % of remainder. |
| `InpTrailStartR` / `InpTrailPoints` | 0.80 / 350 | Trailing activation in R, distance in points. |
| `InpMaxSpreadPoints` | 45 | Gold brokers: 20–40 is normal, 150+ at rollover. |
| `InpUseSession` / start / end | true / 7 / 21 | **Server** time, not your local time. |
| `InpMaxDailyLossPct` | 4.0 | Blocks new trades and (optionally) closes all. |
| `InpDailyTargetPct` | 6.0 | Same, upward. |
| `InpMaxTradesPerSide` / `Total` | 1 / 2 | One long + one short at most by default. |

---

## 6. Test it like this

**Strategy Tester first** — View → Strategy Tester, then:

- Symbol `XAUUSD`, period `M5`, model **Every tick based on real ticks** (not "Open prices").
- Deposit: use the account size you'll actually trade, so lot sizing matches.
- Dates: at least 6 months, and separately test the 3 worst weeks you can find.
- Then **forward test on a demo account for 2–4 weeks** with the same settings.

Things to look at instead of the profit number: max drawdown, longest losing streak, average trade
duration, how many trades ended at break-even (that's the management working), and whether the
result survives a 20% higher spread (`InpMaxSpreadPoints` and the tester's spread setting).

### Logic self-check (what I verified before giving you the file)

`python3 tools/logic_selfcheck.py` re-implements the same rules in Python and runs them over synthetic
gold-like candles, asserting the state machine cannot misbehave:

```
364 trades exercised across all cases; every invariant check passed.
```

It checks: partial volume never drops below the broker minimum, a partial never closes the whole
position (a runner survives), the TP stage only moves forward, the stop only ever tightens, realised
balance change equals the sum of closed P/L, and no entry risks more than the configured percentage.

**What that run also showed, honestly:** on *pure random-walk* candles the strategy loses roughly its
spread. That is the correct result for data with no structure — it means the engine is not secretly
data-mining the sample, not that it wins on real gold. Only your own tick-data backtest and a demo
forward test tell you anything about the edge. I have not run this on real broker history, so I will
not quote you a win rate.

---

## 7. Straight talk about the screenshot

You said it took $30 → $60 and looked profitable with a high win rate while the market was closed.
Three things worth knowing, because they decide whether *this* bot helps you or hurts you:

1. **"Profit" on a closed market is not a result.** With the market shut, floating P/L freezes and
   every open trade shows its last value. Numbers that stop moving are not evidence of an edge —
   only *closed* trades plus the equity curve are.
2. **Doubling a $30 account is a red flag, not a feature.** To double $30 you need either enormous
   leverage or martingale/grid recovery. At 1% risk, doubling takes hundreds of trades. Any bot that
   doubles a micro account in days is running position sizes where a single normal losing streak
   removes the account. That's why this EA has a hard lot cap, a daily loss limit and no recovery
   multiplier.
3. **A high win rate is the easiest statistic in trading to fake.** Take profit at 0.5R with a stop at
   2R gives you ~80% winners and negative expectancy. Judge by **expectancy and drawdown**, not by
   how often the arrow is right. ANT DISCIPLE pays 40% at 0.8R, 30% at 1.5R and trails the rest, so it
   doesn't need a high win rate to be profitable — it needs the winners to be bigger than the losers.

**Nothing here is a promise of profit.** This is a real, risk-managed execution engine you can test,
read and modify — not a money printer. Trade demo until you have your own numbers, then risk money you
can lose entirely. Leverage on gold cuts both ways and you can lose more than your deposit on some
brokers.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Compile error mentioning `Trade.mqh` | Very old terminal build. Update MT5, or replace `trade.SetTypeFillingBySymbol(_Symbol);` with `trade.SetTypeFilling(ORDER_FILLING_IOC);` |
| "Algo Trading disabled" in log | Toolbar Algo Trading button is off, or *Allow Algo Trading* wasn't ticked in the EA dialog. |
| No trades for hours | Check the status line: it names the exact blocker (`outside session`, `spread too wide`, `daily limit reached`, `max total trades open`). Also `InpUseSession` is in **server** time. |
| Trades open then instantly show tiny profit | That's the spread. Gold spreads widen at rollover; keep `InpMaxSpreadPoints` tight. |
| Partial closes never happen | Position is 0.01 lots (below 3× minimum). Expected — see §4. |
| Two arrows at once | `InpMaxTradesPerSide` is 1 each, so one long + one short is normal. |
| Panel labels overlap on a small chart | The panel is anchored top-left, 668×128 px. Maximise the chart or set `InpShowPanel=false`. |

---

## 9. Ideas for the next iteration

- News guard using MT5's economic calendar (`CalendarValueHistory`) so it stands down around CPI/NFP.
- Optional "one trade per swing" mode using swing-point state instead of a fixed bar cooldown.
- Multi-symbol mode (one chart per symbol is the simplest correct design in MT5).
- A proper Monte Carlo / walk-forward harness on your own exported tick data.

Ask and I'll build any of these onto this base.
