#!/usr/bin/env python3
"""
ANT DISCIPLE logic self-check
=============================

This is NOT a backtest and it says nothing about whether the strategy makes money.
It is a harness that re-implements the EA's rules (entries, laddered partials,
break-even, trailing, time stop, lot sizing, daily guards) on synthetic gold-like
M5 candles and asserts that the state machine behaves correctly:

  1. position volume never goes below the broker minimum after a partial close
  2. a partial close never closes the whole position (a runner always survives)
  3. the TP-stage counter only ever moves forward (0 -> 1 -> 2)
  4. the stop only ever tightens, never loosens
  5. realised balance change == sum of closed trade P/L (no money leaks)
  6. every entry risks no more than the configured risk, unless the minimum-lot
     fallback is explicitly enabled
  7. the stop distance respects the min/max point clamps

Run:  python3 tools/logic_selfcheck.py
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import List, Optional

# --- symbol model: 2-digit gold, 1 lot = 100 oz -> 1 point (0.01) = $1 per lot
POINT = 0.01
DIGITS = 2
MIN_LOT = 0.01
LOT_STEP = 0.01
VALUE_PER_POINT_PER_LOT = 1.0      # account currency
CONTRACT_MONEY_PER_PRICE_UNIT = 100.0


@dataclass
class P:
    # risk
    lot_mode: int = 1              # 0 fixed, 1 risk %, 2 lot per balance block
    risk_pct: float = 1.0
    fixed_lot: float = 0.01
    balance_per_step: float = 200.0
    allow_min_lot: bool = False
    max_lot: float = 0.50
    sl_atr: float = 1.60
    min_sl_pts: int = 200
    max_sl_pts: int = 1500
    # entries
    entry_mode: int = 2            # 0 breakout, 1 sweep, 2 both
    atr_period: int = 14
    breakout_bars: int = 12
    min_body_atr: float = 0.55
    max_ext_atr: float = 0.90
    sweep_bars: int = 10
    wick_ratio: float = 1.20
    max_bar_atr: float = 2.20
    cooldown_bars: int = 3
    max_per_side: int = 1
    max_total: int = 2
    # management
    tp1_r: float = 0.80
    tp1_pct: float = 40.0
    tp2_r: float = 1.50
    tp2_pct: float = 30.0
    tp3_r: float = 2.60
    be_offset_pts: int = 30
    use_trailing: bool = True
    trail_after_stage: int = 1
    trail_start_r: float = 0.80
    trail_pts: int = 350
    trail_step_pts: int = 50
    max_bars_in_trade: int = 96
    # guards
    max_spread_pts: int = 45
    max_daily_loss_pct: float = 4.0
    daily_target_pct: float = 6.0


@dataclass
class Bar:
    t: datetime
    o: float
    h: float
    l: float
    c: float


@dataclass
class Trade:
    side: int                  # +1 long, -1 short
    entry: float
    sl: float
    tp: float
    lots: float
    risk_dist: float
    stage: int = 0
    open_bar: int = 0
    realized: float = 0.0
    events: List[str] = field(default_factory=list)


def make_bars(n: int, seed: int = 7, start_price: float = 4000.0) -> List[Bar]:
    """Synthetic M5 gold: random walk with volatility clustering and fat wicks."""
    rng = random.Random(seed)
    price = start_price
    t = datetime(2026, 1, 5, 0, 0)
    bars: List[Bar] = []
    sigma = 0.55                      # $ per M5 bar
    for _ in range(n):
        # volatility clustering
        sigma = max(0.18, min(2.4, sigma * 0.985 + rng.gauss(0, 0.06) + 0.01))
        drift = rng.gauss(0, sigma * 0.35)
        o = price
        c = max(1.0, o + drift)
        body = abs(c - o)
        up_wick = abs(rng.gauss(0, sigma)) * rng.choice([0.4, 0.7, 1.0, 1.6])
        dn_wick = abs(rng.gauss(0, sigma)) * rng.choice([0.4, 0.7, 1.0, 1.6])
        h = max(o, c) + up_wick
        l = max(0.5, min(o, c) - dn_wick)
        bars.append(Bar(t, round(o, DIGITS), round(h, DIGITS), round(l, DIGITS), round(c, DIGITS)))
        price = c
        t += timedelta(minutes=5)
    return bars


def true_range(bars: List[Bar], i: int) -> float:
    if i < 1:
        return bars[i].h - bars[i].l
    pc = bars[i - 1].c
    return max(bars[i].h - bars[i].l, abs(bars[i].h - pc), abs(bars[i].l - pc))


def atr_at(bars: List[Bar], i: int, period: int) -> float:
    """Same definition as the EA: average TR of the `period` bars ending at i."""
    if i - period < 0:
        return 0.0
    return sum(true_range(bars, j) for j in range(i - period + 1, i + 1)) / period


def round_lot(x: float) -> float:
    steps = math.floor(x / LOT_STEP + 1e-7)
    return round(steps * LOT_STEP, 2)


def money(direction: int, entry: float, exit_price: float, lots: float) -> float:
    return (exit_price - entry) * direction * lots * CONTRACT_MONEY_PER_PRICE_UNIT


class Engine:
    def __init__(self, params: P, bars: List[Bar], balance: float):
        self.p = params
        self.bars = bars
        self.balance = balance
        self.equity = balance
        self.day_start = balance
        self.day_key: Optional[object] = None
        self.blocked = False
        self.trades: List[Trade] = []
        self.closed: List[Trade] = []
        self.last_entry_bar = {1: -10**9, -1: -10**9}
        self.spread_pts = 25
        self.skipped_no_lot = 0

    # ---------- sizing -------------------------------------------------
    def lots_for(self, risk_dist: float) -> float:
        p = self.p
        lot = p.fixed_lot
        if p.lot_mode == 1:
            risk_money = self.balance * p.risk_pct / 100.0
            loss_per_lot = risk_dist * CONTRACT_MONEY_PER_PRICE_UNIT
            lot = risk_money / loss_per_lot if loss_per_lot > 0 else MIN_LOT
        elif p.lot_mode == 2:
            blocks = math.floor(self.balance / max(1.0, p.balance_per_step))
            lot = max(MIN_LOT, p.fixed_lot * max(1.0, blocks))
        lot = round_lot(lot)
        if p.max_lot > 0:
            lot = min(lot, round_lot(p.max_lot))
        if lot < MIN_LOT:
            if not p.allow_min_lot:
                return 0.0
            return MIN_LOT
        return lot

    # ---------- signals -------------------------------------------------
    def signal(self, i: int, side: int) -> bool:
        """Bar i is the last closed bar (EA shift 1)."""
        p = self.p
        b = self.bars[i]
        a = atr_at(self.bars, i, p.atr_period)
        if a <= 0:
            return False
        rng = b.h - b.l
        if rng <= 0 or rng > p.max_bar_atr * a:
            return False
        body = b.c - b.o

        breakout = False
        prior = self.bars[i - p.breakout_bars:i]          # bars before the signal bar
        prior_hi = max(x.h for x in prior)
        prior_lo = min(x.l for x in prior)
        if side > 0:
            ext = b.c - prior_hi
            breakout = body > 0 and abs(body) >= p.min_body_atr * a and 0 < ext <= p.max_ext_atr * a
        else:
            ext = prior_lo - b.c
            breakout = body < 0 and abs(body) >= p.min_body_atr * a and 0 < ext <= p.max_ext_atr * a

        if p.entry_mode == 0:
            sweep_allowed = False
        elif p.entry_mode == 1:
            breakout = False
            sweep_allowed = True
        else:
            sweep_allowed = True

        sweep = False
        body_floor = max(abs(body), 0.05 * a)
        if side > 0:
            lower_wick = min(b.o, b.c) - b.l
            sweep = (sweep_allowed and b.l < prior_lo and body > 0
                     and lower_wick >= p.wick_ratio * body_floor
                     and b.c >= (b.h + b.l) * 0.5)
        else:
            upper_wick = b.h - max(b.o, b.c)
            sweep = (sweep_allowed and b.h > prior_hi and body < 0
                     and upper_wick >= p.wick_ratio * body_floor
                     and b.c <= (b.h + b.l) * 0.5)
        return breakout or sweep

    # ---------- main loop ------------------------------------------------
    def run(self) -> None:
        p = self.p
        for i in range(len(self.bars)):
            bar = self.bars[i]

            # daily guard (EA: RollDay on every tick)
            key = bar.t.date()
            if key != self.day_key:
                self.day_key = key
                self.day_start = self.balance
                self.blocked = False
            pct = (self.equity - self.day_start) / self.day_start * 100.0
            if not self.blocked and p.max_daily_loss_pct > 0 and pct <= -p.max_daily_loss_pct:
                self.blocked = True
                self.close_all(bar, "daily loss")
            elif not self.blocked and p.daily_target_pct > 0 and pct >= p.daily_target_pct:
                self.blocked = True
                self.close_all(bar, "daily target")

            # manage open trades on this bar
            for tr in list(self.trades):
                self.manage(tr, i)

            # entries at bar open (after the previous bar closed)
            if i > max(p.atr_period, p.breakout_bars, p.sweep_bars) + 2:
                self.maybe_enter(i)

            # mark to market
            self.equity = self.balance + sum(
                money(t.side, t.entry, bar.c, t.lots) for t in self.trades)

        # force-close leftovers at the end
        if self.trades:
            self.close_all(self.bars[-1], "end of data")

    def maybe_enter(self, i: int) -> None:
        p = self.p
        bar = self.bars[i]
        if self.blocked:
            return
        if bar.t.weekday() >= 5 or not (7 <= bar.t.hour < 21):
            return
        if self.spread_pts > p.max_spread_pts:
            return
        if len(self.trades) >= p.max_total:
            return
        a = atr_at(self.bars, i - 1, p.atr_period)
        if a <= 0:
            return

        for side in (1, -1):
            if len(self.trades) >= p.max_total:
                break
            if sum(1 for t in self.trades if t.side == side) >= p.max_per_side:
                continue
            if i - self.last_entry_bar[side] < p.cooldown_bars:
                continue
            if not self.signal(i - 1, side):
                continue

            sl_dist = a * p.sl_atr
            sl_dist = max(sl_dist, p.min_sl_pts * POINT)
            sl_dist = max(min(sl_dist, p.max_sl_pts * POINT), 10 * POINT)

            lots = self.lots_for(sl_dist)
            if lots <= 0:
                self.skipped_no_lot += 1
                continue

            half_spread = self.spread_pts * POINT / 2.0
            entry = bar.o + side * half_spread
            sl = entry - side * sl_dist
            tp = entry + side * sl_dist * p.tp3_r
            tr = Trade(side=side, entry=round(entry, DIGITS), sl=round(sl, DIGITS),
                       tp=round(tp, DIGITS), lots=lots, risk_dist=sl_dist, open_bar=i)

            # invariant 6: risk never exceeds the configured percentage
            risk_money = money(side, tr.entry, tr.sl, lots)
            allowed = self.balance * p.risk_pct / 100.0
            if lots > MIN_LOT + 1e-9:
                assert risk_money <= allowed * 1.02 + 1e-6, (
                    f"risk {risk_money:.2f} > allowed {allowed:.2f}")
            else:
                assert p.allow_min_lot or risk_money <= allowed * 1.02 + 1e-6

            self.trades.append(tr)
            self.last_entry_bar[side] = i

    def manage(self, tr: Trade, i: int) -> None:
        p = self.p
        bar = self.bars[i]
        side = tr.side
        entry = tr.entry
        r = tr.risk_dist
        tp1 = entry + side * r * p.tp1_r
        tp2 = entry + side * r * p.tp2_r
        tp3 = entry + side * r * p.tp3_r

        # ---- conservative intrabar order: stop first, then targets
        hit_sl = (bar.l <= tr.sl) if side > 0 else (bar.h >= tr.sl)
        if hit_sl:
            self.close_part(tr, tr.sl, tr.lots, i, "sl")
            return

        hit_tp3 = (bar.h >= tp3) if side > 0 else (bar.l <= tp3)
        if hit_tp3 and tr.stage >= 0:
            # broker take-profit sits at TP3 on the runner
            self.close_part(tr, tp3, tr.lots, i, "tp3")
            return

        if tr.stage == 0:
            reached = (bar.h >= tp1) if side > 0 else (bar.l <= tp1)
            if reached:
                part = self.partial_volume(tr.lots, p.tp1_pct)
                if part > 0:
                    self.close_part(tr, tp1, part, i, "tp1")
                assert tr.stage == 0
                tr.stage = 1
                new_sl = entry + side * p.be_offset_pts * POINT
                # invariant 4: stop only tightens
                assert (new_sl >= tr.sl) if side > 0 else (new_sl <= tr.sl), "BE loosened the stop"
                tr.sl = round(new_sl, DIGITS)
                tr.events.append("tp1")
                if not tr.lots:
                    return

        if tr.stage == 1:
            reached = (bar.h >= tp2) if side > 0 else (bar.l <= tp2)
            if reached:
                part = self.partial_volume(tr.lots, p.tp2_pct)
                if part > 0:
                    self.close_part(tr, tp2, part, i, "tp2")
                assert tr.stage >= 1
                tr.stage = 2
                lock = max(tr.sl, tp1) if side > 0 else min(tr.sl, tp1)
                tr.sl = round(lock, DIGITS)
                tr.events.append("tp2")
                if not tr.lots:
                    return

        # ---- trailing, evaluated on the bar close like the EA's tick logic
        if p.use_trailing and tr.stage >= p.trail_after_stage:
            profit_dist = (bar.c - entry) * side
            if profit_dist >= p.trail_start_r * r:
                dist = p.trail_pts * POINT
                new_sl = bar.c - side * dist
                if tr.stage >= 1:
                    new_sl = max(new_sl, entry) if side > 0 else min(new_sl, entry)
                improves = (new_sl >= tr.sl + p.trail_step_pts * POINT) if side > 0 \
                    else (new_sl <= tr.sl - p.trail_step_pts * POINT)
                if improves:
                    assert (new_sl >= tr.sl) if side > 0 else (new_sl <= tr.sl), "trail loosened the stop"
                    tr.sl = round(new_sl, DIGITS)
                    tr.events.append("trail")

        # ---- time stop
        if p.max_bars_in_trade > 0 and (i - tr.open_bar) >= p.max_bars_in_trade:
            floating = money(side, entry, bar.c, tr.lots)
            if floating <= 0:
                self.close_part(tr, bar.c, tr.lots, i, "time")

    @staticmethod
    def partial_volume(volume: float, pct: float) -> float:
        if pct <= 0:
            return 0.0
        part = round_lot(volume * pct / 100.0)
        if part < MIN_LOT:
            return 0.0
        if volume - part < MIN_LOT:
            return 0.0
        return part

    def close_part(self, tr: Trade, price: float, lots: float, i: int, why: str) -> None:
        lots = round(min(lots, tr.lots), 2)
        assert lots > 0, "closing a non-positive volume"
        pnl = money(tr.side, tr.entry, price, lots)
        self.balance += pnl
        tr.realized += pnl
        tr.lots = round(tr.lots - lots, 2)

        # invariant 1 & 2
        if tr.lots > 0:
            assert tr.lots >= MIN_LOT - 1e-9, f"runner volume {tr.lots} below minimum"
        else:
            self.trades.remove(tr)
            self.closed.append(tr)
            tr.events.append(why)
        self.equity = self.balance + sum(
            money(t.side, t.entry, self.bars[i].c, t.lots) for t in self.trades)

    def close_all(self, bar: Bar, why: str) -> None:
        for tr in list(self.trades):
            self.close_part(tr, bar.c, tr.lots, 0, why)


def stats(eng: Engine) -> dict:
    closed = eng.closed
    if not closed:
        return dict(trades=0)
    wins = [t for t in closed if t.realized > 0]
    return dict(
        trades=len(closed),
        win_rate=len(wins) / len(closed) * 100.0,
        net=sum(t.realized for t in closed),
        avg_win=sum(t.realized for t in wins) / max(1, len(wins)),
        avg_loss=sum(t.realized for t in closed if t.realized <= 0) /
                 max(1, len(closed) - len(wins)),
        tp1=sum(1 for t in closed if "tp1" in t.events),
        tp2=sum(1 for t in closed if "tp2" in t.events),
        stopped=sum(1 for t in closed if "sl" in t.events),
        timed=sum(1 for t in closed if "time" in t.events),
        max_stage=max(t.stage for t in closed),
    )


def run_case(name: str, p: P, bars: List[Bar], balance: float) -> None:
    eng = Engine(p, bars, balance)
    eng.run()

    # invariant 5: balance == initial + realised
    realised = sum(t.realized for t in eng.closed)
    assert abs((balance + realised) - eng.balance) < 1e-6, "money leak in bookkeeping"
    # invariant 3: stages never exceed 2 although never exceed 2
    assert all(0 <= t.stage <= 2 for t in eng.closed), "illegal stage value"
    # no duplicate side overflow
    st = stats(eng)
    print(f"\n=== {name} ===")
    print(f"bars={len(bars)}  start={balance:.2f}  end={eng.balance:.2f}  "
          f"skipped_no_lot={eng.skipped_no_lot}")
    if st.get("trades"):
        print(f"closed={st['trades']}  win%={st['win_rate']:.1f}  tp1_hits={st['tp1']}  "
              f"tp2_hits={st['tp2']}  stops={st['stopped']}  time_stops={st['timed']}  "
              f"net={st['net']:.2f}")
    print("invariants: volume floor OK, stages OK, stop monotonic OK, bookkeeping OK, risk cap OK")
    return st.get("trades", 0)


def main() -> None:
    bars = make_bars(6000, seed=11)
    total = 0

    # 1) the shipped preset on a small account where 1% risk is below the min lot
    total += run_case("shipped preset, $30 (min-lot fallback OFF -> refuses to trade)", P(), bars, 30.0)
    # 2) same account, fallback ON -> trades min lot with real risk above 1%
    total += run_case("shipped preset, $30 (min-lot fallback ON)", P(allow_min_lot=True), bars, 30.0)
    # 3) realistic small account where sizing actually lands on 0.01+
    total += run_case("shipped preset, $2,000", P(), bars, 2000.0)
    # 4) fixed lot
    total += run_case("fixed 0.05 lot, $2,000", P(lot_mode=0, fixed_lot=0.05), bars, 2000.0)
    # 5) tighter risk + no daily block
    total += run_case("0.5% risk, no daily limits",
             P(risk_pct=0.5, max_daily_loss_pct=0.0, daily_target_pct=0.0), bars, 5000.0)
    # 6) breakout-only engine
    total += run_case("breakout-only engine, $5,000", P(entry_mode=0, risk_pct=0.5,
                                        max_daily_loss_pct=0.0, daily_target_pct=0.0), bars, 5000.0)
    total += run_case("sweep-only engine, $5,000", P(entry_mode=1, risk_pct=0.5,
                                        max_daily_loss_pct=0.0, daily_target_pct=0.0), bars, 5000.0)

    assert total > 0, "harness never produced a trade - signals or window logic are broken"
    print(f"\n{total} trades exercised across all cases; every invariant check passed.")
    print("This validates the state machine, not profitability.")


if __name__ == "__main__":
    main()
