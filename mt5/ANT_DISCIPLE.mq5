//+------------------------------------------------------------------+
//|                                               ANT_DISCIPLE.mq5   |
//|                                                                  |
//|  ANT DISCIPLE - price-action trade engine for MetaTrader 5        |
//|                                                                  |
//|  No RSI. No MACD. No moving averages. No stochastic.              |
//|  Every decision comes from raw OHLC bars: range expansion,        |
//|  body-to-range dominance, wick rejection and liquidity sweeps.    |
//|  Volatility is true range measured in the EA, and is used for     |
//|  stop distance and lot size only, never as a buy/sell signal.     |
//|                                                                  |
//|  Trade management:                                               |
//|    - volatility-normalised stop (same risk unit every trade)      |
//|    - laddered partial take profits (TP1 / TP2 / runner)           |
//|    - break-even lock after TP1                                   |
//|    - tighten-only trailing stop                                  |
//|    - time stop on non-performing positions                       |
//|  Account protection:                                             |
//|    - spread filter, session filter, Friday cut-off               |
//|    - daily loss limit and daily profit target                    |
//|    - max trades per side / total, per-bar cooldown                |
//|    - no martingale, no grid, no averaging down. Ever.             |
//|                                                                  |
//|  Chart panel: BUY ON/OFF, CLOSE BUY, PAUSE, SELL ON/OFF,          |
//|               CLOSE SELL, PAUSE, NEW CYCLE                       |
//|                                                                  |
//|  Risk warning: an EA cannot guarantee profit. Test on DEMO first. |
//+------------------------------------------------------------------+
#property copyright "ANT DISCIPLE"
#property link      ""
#property version   "1.00"
#property description "ANT DISCIPLE - indicator-free price action engine for MT5."
#property description "Breakout continuation + liquidity-sweep rejection entries, ATR-normalised risk,"
#property description "laddered partial take profits, break-even lock, adaptive trailing stop."
#property description "No RSI / MACD / MA. Test on demo before any live account."

#include <Trade\Trade.mqh>

//====================================================================
//  ENUMERATIONS
//====================================================================
enum ENUM_ENTRY_MODE
{
   ENTRY_BREAKOUT = 0,   // Breakout continuation only
   ENTRY_SWEEP    = 1,   // Liquidity sweep rejection only
   ENTRY_BOTH     = 2    // Both engines (recommended)
};

enum ENUM_LOT_MODE
{
   LOT_FIXED        = 0,  // Fixed lot
   LOT_RISK_PERCENT = 1,  // Risk percent of balance
   LOT_BAL_STEP     = 2   // Fixed lot per balance block
};

//====================================================================
//  INPUTS
//====================================================================
//--- 1. Identity -----------------------------------------------------
input long   InpMagic            = 20261025;      // Magic number (unique per chart)
input int    InpSlippage         = 30;            // Max slippage (points)
input string InpComment          = "ANT DISCIPLE";// Order comment
input bool   InpShowPanel        = true;          // Show chart panel

//--- 2. Sides --------------------------------------------------------
input bool   InpAllowBuy         = true;          // Allow BUY engine
input bool   InpAllowSell        = true;          // Allow SELL engine

//--- 3. Entry engine -------------------------------------------------
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_BOTH;  // Entry mode
input int    InpATRPeriod        = 14;            // Volatility lookback (bars)
input int    InpBreakoutBars     = 12;            // Breakout: bars in the range
input double InpMinBodyATR       = 0.55;          // Breakout: min body (x ATR)
input double InpMaxExtensionATR  = 0.90;          // Breakout: max close beyond range (x ATR)
input int    InpSweepBars        = 10;            // Sweep: bars whose low/high is raided
input double InpWickRatio        = 1.20;          // Sweep: wick must be >= body x ratio
input double InpMaxBarATR        = 2.20;          // Reject bars bigger than this (x ATR)
input bool   InpUseTrendFilter   = false;         // Require higher-timeframe-ish trend
input int    InpTrendBars        = 20;            // Trend filter lookback (bars)
input int    InpCooldownBars     = 3;             // Bars to wait after an entry
input int    InpMaxTradesPerSide = 1;             // Max open trades per side
input int    InpMaxTradesTotal   = 2;             // Max open trades in total

//--- 4. Risk / lot size ----------------------------------------------
input ENUM_LOT_MODE InpLotMode   = LOT_RISK_PERCENT;// Lot sizing mode
input double InpRiskPercent      = 1.0;           // Risk per trade (% of balance)
input double InpFixedLot         = 0.01;          // Fixed lot (or step lot)
input double InpBalancePerStep   = 200.0;         // Balance per FixedLot block (mode 2)
input bool   InpAllowMinLotFallback = false;     // Trade min lot if risk calc is below it
input double InpMaxLot           = 0.50;          // Hard lot cap
input double InpSL_ATR           = 1.60;          // Stop loss (x ATR)
input int    InpMinSLPoints      = 200;           // Minimum SL distance (points)
input int    InpMaxSLPoints      = 1500;          // Maximum SL distance (points)

//--- 5. Targets / management -----------------------------------------
input double InpTP1_R            = 0.80;          // TP1 (x risk unit R)
input double InpTP1Pct           = 40.0;          // TP1 close percentage
input double InpTP2_R            = 1.50;          // TP2 (x risk unit R)
input double InpTP2Pct           = 30.0;          // TP2 close percentage (of remainder)
input double InpTP3_R            = 2.60;          // Runner target (x risk unit R)
input int    InpBE_OffsetPoints  = 30;            // Break-even offset (points)

//--- 6. Trailing -----------------------------------------------------
input bool   InpUseTrailing      = true;          // Enable trailing stop
input int    InpTrailAfterStage  = 1;             // Start trailing after N partials (0/1/2)
input double InpTrailStartR      = 0.80;          // Trail only after price is this many R in profit
input int    InpTrailPoints      = 350;           // Trail distance (points)
input int    InpTrailStepPoints  = 50;            // Min improvement before modifying SL

//--- 7. Time / market guards -----------------------------------------
input int    InpMaxSpreadPoints  = 45;            // Max spread to trade (points, 0 = off)
input bool   InpUseSession       = true;          // Use session filter
input int    InpSessionStart     = 7;             // Session start hour (server time)
input int    InpSessionEnd       = 21;            // Session end hour (server time)
input bool   InpAvoidFriday      = true;          // No new trades late Friday
input int    InpFridayStopHour   = 20;            // Friday stop hour (server time)
input int    InpMaxBarsInTrade   = 96;            // Time stop in bars (0 = off)

//--- 8. Daily protection ---------------------------------------------
input double InpMaxDailyLossPct  = 4.0;           // Daily loss limit (%, 0 = off)
input double InpDailyTargetPct   = 6.0;           // Daily profit target (%, 0 = off)
input bool   InpCloseOnDayLimit  = true;          // Close open trades when a limit hits
input bool   InpVerboseLog       = true;          // Print decisions to the Experts log

//====================================================================
//  GLOBAL STATE
//====================================================================
CTrade   trade;

bool     g_panelOn        = true;
bool     g_entryBuyOn     = true;
bool     g_entrySellOn    = true;
bool     g_pausedBuy      = false;
bool     g_pausedSell     = false;
double   g_atr            = 0.0;
datetime g_lastBar        = 0;
double   g_dayStartBal    = 0.0;
datetime g_dayStamp       = 0;
bool     g_dayBlocked     = false;
string   g_status         = "starting";
string   g_statusShown    = "";
datetime g_lastEntryBuy   = 0;
datetime g_lastEntrySell  = 0;
double   g_tp1R           = 0.80;
double   g_tp2R           = 1.50;
double   g_tp3R           = 2.60;
int      g_markerCount    = 0;
bool     g_minLotWarned   = false;
string   g_prefix         = "ANT_";

//====================================================================
//  LIFECYCLE
//====================================================================
int OnInit()
{
   g_tp1R = InpTP1_R;
   g_tp2R = InpTP2_R;
   g_tp3R = InpTP3_R;

   // Targets must be strictly increasing, otherwise stage detection breaks.
   if(g_tp1R < 0.10) g_tp1R = 0.10;
   if(g_tp2R <= g_tp1R) g_tp2R = g_tp1R * 1.75;
   if(g_tp3R <= g_tp2R) g_tp3R = g_tp2R * 1.60;
   if(MathAbs(g_tp1R - InpTP1_R) > 0.0001 ||
      MathAbs(g_tp2R - InpTP2_R) > 0.0001 ||
      MathAbs(g_tp3R - InpTP3_R) > 0.0001)
      Log("TP multipliers were not strictly increasing - using " +
          DoubleToString(g_tp1R, 2) + "R / " + DoubleToString(g_tp2R, 2) +
          "R / " + DoubleToString(g_tp3R, 2) + "R");

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints((ulong)MathMax(1, InpSlippage));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(!SymbolSelect(_Symbol, true))
      Log("could not select " + _Symbol + " in Market Watch");

   g_entryBuyOn  = InpAllowBuy;
   g_entrySellOn = InpAllowSell;
   g_pausedBuy   = false;
   g_pausedSell  = false;
   g_panelOn     = InpShowPanel;
   g_dayStamp    = DayStart();
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayBlocked  = false;
   g_lastBar     = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_atr         = ATRValue(InpATRPeriod);

   // Point-based inputs assume a 2-digit quote (classic XAUUSD). A 3-digit gold
   // symbol makes every point-based distance ten times tighter - warn loudly.
   if(_Digits > 2)
      Log(StringFormat("NOTE: %s has %d digits. InpMinSLPoints/InpMaxSLPoints/InpTrailPoints are in points - " +
                       "multiply them by 10 compared with a 2-digit symbol (min SL %.0f points = %s price).",
                       _Symbol, (int)_Digits, (double)InpMinSLPoints, DoubleToString(InpMinSLPoints * _Point, _Digits)));
   if(InpMaxSpreadPoints <= 0)
      Log("NOTE: InpMaxSpreadPoints is disabled - the EA will trade through rollover spreads.");

   if(g_panelOn) BuildPanel();
   EventSetTimer(1);

   Log("initialised on " + _Symbol + " " + EnumToString((ENUM_TIMEFRAMES)Period()) +
       " | magic " + IntegerToString(InpMagic));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix + "BTN_");
   ObjectsDeleteAll(0, g_prefix + "LBL_");
   ObjectsDeleteAll(0, g_prefix + "PNL");
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // The strategy tester and live terminal both land here.
   if(!HistoryReady())
   {
      UpdatePanel();
      return;
   }

   RollDay();               // cheap equity check, closes out on a breached limit

   if(NewBar())
   {
      g_atr = ATRValue(InpATRPeriod);
      EvaluateEntries();
   }

   ManagePositions();
   UpdatePanel();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!HistoryReady()) return;
   ManagePositions();
   UpdatePanel();
}

//====================================================================
//  ENTRY LOGIC
//====================================================================
void EvaluateEntries()
{
   if(!TradingAllowed())
   {
      SetStatus("algo/broker trading blocked");
      return;
   }
   if(g_atr <= 0.0) return;
   if(!SpreadOk())    { SetStatus("spread too wide (" + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts)"); return; }
   if(!SessionOk())   { SetStatus("outside session"); return; }
   if(g_dayBlocked)   { SetStatus("daily limit reached - standing down"); return; }
   if(CountAllPositions() >= InpMaxTradesTotal) { SetStatus("max total trades open"); return; }

   const bool buyFree  = g_entryBuyOn && !g_pausedBuy && CountPositions(POSITION_TYPE_BUY)  < InpMaxTradesPerSide;
   const bool sellFree = g_entrySellOn && !g_pausedSell && CountPositions(POSITION_TYPE_SELL) < InpMaxTradesPerSide;

   if(buyFree && CooldownOk(g_lastEntryBuy) && SignalBuy())
   {
      if(TryOpen(POSITION_TYPE_BUY)) return;
   }
   if(sellFree && CooldownOk(g_lastEntrySell) && SignalSell())
   {
      TryOpen(POSITION_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Long signal: range break with dominant body, or a swept low          |
//| that closes back inside the range with a long lower wick.            |
//+------------------------------------------------------------------+
bool SignalBuy()
{
   if(!HistoryReady() || g_atr <= 0.0) return false;

   const double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   const double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   const double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   const double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   const double range = h1 - l1;
   const double body = c1 - o1;           // signed: > 0 means bullish bar

   if(range <= 0.0) return false;
   if(range > InpMaxBarATR * g_atr) return false;   // news-spike guard

   bool breakout = false;
   bool sweep    = false;

   if(InpEntryMode == ENTRY_BREAKOUT || InpEntryMode == ENTRY_BOTH)
   {
      const double priorHigh = HighestHigh(InpBreakoutBars, 2);
      const double extension = c1 - priorHigh;
      if(body > 0.0 &&
         MathAbs(body) >= InpMinBodyATR * g_atr &&
         extension > 0.0 &&
         extension <= InpMaxExtensionATR * g_atr)
         breakout = true;
   }

   if(InpEntryMode == ENTRY_SWEEP || InpEntryMode == ENTRY_BOTH)
   {
      const double priorLow   = LowestLow(InpSweepBars, 2);
      const double lowerWick  = MathMin(o1, c1) - l1;
      double       bodyFloor  = MathAbs(body);
      if(bodyFloor < 0.05 * g_atr) bodyFloor = 0.05 * g_atr;
      const bool swept     = (l1 < priorLow);
      const bool rejected  = (body > 0.0) && (lowerWick >= InpWickRatio * bodyFloor);
      const bool closedMid = (c1 >= (h1 + l1) * 0.5);
      if(swept && rejected && closedMid) sweep = true;
   }

   if(!breakout && !sweep) return false;

   if(InpUseTrendFilter)
   {
      const int tb = MathMax(2, InpTrendBars);
      if(c1 <= iClose(_Symbol, PERIOD_CURRENT, 1 + tb)) return false;
   }

   if(InpVerboseLog)
      Log("BUY signal: " + (breakout ? "breakout" : "") + (breakout && sweep ? "+" : "") +
          (sweep ? "sweep-reject" : "") + " close=" + DoubleToString(c1, _Digits) +
          " ATR=" + DoubleToString(g_atr, _Digits));
   return true;
}

//+------------------------------------------------------------------+
bool SignalSell()
{
   if(!HistoryReady() || g_atr <= 0.0) return false;

   const double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   const double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   const double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   const double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   const double range = h1 - l1;
   const double body = c1 - o1;

   if(range <= 0.0) return false;
   if(range > InpMaxBarATR * g_atr) return false;

   bool breakout = false;
   bool sweep    = false;

   if(InpEntryMode == ENTRY_BREAKOUT || InpEntryMode == ENTRY_BOTH)
   {
      const double priorLow  = LowestLow(InpBreakoutBars, 2);
      const double extension = priorLow - c1;
      if(body < 0.0 &&
         MathAbs(body) >= InpMinBodyATR * g_atr &&
         extension > 0.0 &&
         extension <= InpMaxExtensionATR * g_atr)
         breakout = true;
   }

   if(InpEntryMode == ENTRY_SWEEP || InpEntryMode == ENTRY_BOTH)
   {
      const double priorHigh  = HighestHigh(InpSweepBars, 2);
      const double upperWick  = h1 - MathMax(o1, c1);
      double       bodyFloor  = MathAbs(body);
      if(bodyFloor < 0.05 * g_atr) bodyFloor = 0.05 * g_atr;
      const bool swept     = (h1 > priorHigh);
      const bool rejected  = (body < 0.0) && (upperWick >= InpWickRatio * bodyFloor);
      const bool closedMid = (c1 <= (h1 + l1) * 0.5);
      if(swept && rejected && closedMid) sweep = true;
   }

   if(!breakout && !sweep) return false;

   if(InpUseTrendFilter)
   {
      const int tb = MathMax(2, InpTrendBars);
      if(c1 >= iClose(_Symbol, PERIOD_CURRENT, 1 + tb)) return false;
   }

   if(InpVerboseLog)
      Log("SELL signal: " + (breakout ? "breakout" : "") + (breakout && sweep ? "+" : "") +
          (sweep ? "sweep-reject" : "") + " close=" + DoubleToString(c1, _Digits) +
          " ATR=" + DoubleToString(g_atr, _Digits));
   return true;
}

//====================================================================
//  ORDER EXECUTION
//====================================================================
bool TryOpen(const ENUM_POSITION_TYPE ptype)
{
   if(!TradingAllowed()) return false;
   if(!SpreadOk() || !SessionOk() || g_dayBlocked) return false;
   if(g_atr <= 0.0) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;

   double price = (ptype == POSITION_TYPE_BUY) ? ask : bid;

   // --- stop distance: volatility sized, then clamped to the broker limits
   double slDist = g_atr * InpSL_ATR;
   if(InpMinSLPoints > 0 && slDist < InpMinSLPoints * _Point) slDist = InpMinSLPoints * _Point;
   if(InpMaxSLPoints > 0 && slDist > InpMaxSLPoints * _Point) slDist = InpMaxSLPoints * _Point;

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop    = (double)stopsLevel * _Point;
   if(minStop > 0 && slDist < minStop * 1.2) slDist = minStop * 1.2;
   if(slDist <= 0) return false;

   double tpDist = slDist * g_tp3R;

   double sl = (ptype == POSITION_TYPE_BUY) ? price - slDist : price + slDist;
   double tp = (ptype == POSITION_TYPE_BUY) ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   double lots = CalcLots(slDist);
   if(lots <= 0.0)
   {
      const double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      const double minRisk   = RiskForLots(minLot, slDist);
      const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      const double needPct   = (balance > 0.0) ? minRisk / balance * 100.0 : 0.0;
      SetStatus(StringFormat("risk %.2f%% too small for broker min lot (%.2f lots = %.2f risk, needs ~%.2f%%)",
                InpRiskPercent, minLot, minRisk, needPct));
      if(InpVerboseLog)
         Log(StringFormat("entry skipped: broker minimum lot %s with this stop (%s) risks %.2f = %.2f%% of balance. " +
                          "Raise InpRiskPercent, use a cent account, or set InpAllowMinLotFallback=true.",
                          DoubleToString(minLot, 2), DoubleToString(slDist, _Digits),
                          minRisk, needPct));
      return false;
   }

   double marginNeeded = 0.0;
   ENUM_ORDER_TYPE otype = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(otype, _Symbol, lots, price, marginNeeded))
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginNeeded > freeMargin * 0.90)
      {
         SetStatus("not enough free margin for " + DoubleToString(lots, 2) + " lots");
         return false;
      }
   }

   bool ok = false;
   if(ptype == POSITION_TYPE_BUY) ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment);
   else                           ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);

   const uint rc = trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
   {
      SetStatus("order failed rc=" + IntegerToString((int)rc) + " " + trade.ResultRetcodeDescription());
      Log("order failed rc=" + IntegerToString((int)rc) + " " + trade.ResultRetcodeDescription());
      return false;
   }

   // --- remember the risk unit for this ticket so management survives restarts
   ulong posTicket = 0;
   const ulong deal = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      posTicket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(posTicket > 0)
   {
      GlobalVariableSet(StateName("R", posTicket), slDist);
      GlobalVariableSet(StateName("S", posTicket), 0.0);
   }
   else
   {
      // netting / unusual fills: attach to the newest position of this side
      posTicket = NewestPositionTicket(ptype);
      if(posTicket > 0)
      {
         GlobalVariableSet(StateName("R", posTicket), slDist);
         GlobalVariableSet(StateName("S", posTicket), 0.0);
      }
   }

   const double fill = (trade.ResultPrice() > 0.0) ? trade.ResultPrice() : price;
   DrawEntry(ptype, fill);

   if(ptype == POSITION_TYPE_BUY) g_lastEntryBuy  = iTime(_Symbol, PERIOD_CURRENT, 1);
   else                           g_lastEntrySell = iTime(_Symbol, PERIOD_CURRENT, 1);

   const double riskMoney = RiskForLots(lots, slDist);
   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskPct   = (balance > 0.0) ? riskMoney / balance * 100.0 : 0.0;

   SetStatus(StringFormat("%s %.2f lots  SL %.0f pts  risk %.2f (%.2f%%)",
             (ptype == POSITION_TYPE_BUY ? "BUY" : "SELL"), lots,
             slDist / _Point, riskMoney, riskPct));
   Log(StringFormat("%s opened %.2f lots at %s SL %s TP %s | riskDist %s | risk %.2f (%.2f%% of balance)",
       (ptype == POSITION_TYPE_BUY ? "BUY" : "SELL"), lots,
       DoubleToString(fill, _Digits), DoubleToString(sl, _Digits),
       DoubleToString(tp, _Digits), DoubleToString(slDist, _Digits),
       riskMoney, riskPct));
   return true;
}

//+------------------------------------------------------------------+
//| Lot sizing                                                           |
//+------------------------------------------------------------------+
double CalcLots(const double slDist)
{
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot = InpFixedLot;

   if(InpLotMode == LOT_RISK_PERCENT)
   {
      const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      const double riskMoney = balance * InpRiskPercent / 100.0;
      const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
      if(tickSize <= 0.0 || tickValue <= 0.0 || slDist <= 0.0)
      {
         Log("tick data unavailable - falling back to minimum lot");
         lot = minLot;
      }
      else
      {
         const double lossPerLot = (slDist / tickSize) * tickValue;
         lot = (lossPerLot > 0.0) ? (riskMoney / lossPerLot) : minLot;
      }
   }
   else if(InpLotMode == LOT_BAL_STEP)
   {
      const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      const double blocks  = MathFloor(balance / MathMax(1.0, InpBalancePerStep));
      lot = MathMax(minLot, InpFixedLot * MathMax(1.0, blocks));
   }

   lot = RoundVolumeToStep(lot);

   const double maxLotBroker = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(InpMaxLot > 0.0 && lot > InpMaxLot) lot = RoundVolumeToStep(InpMaxLot);
   if(maxLotBroker > 0.0 && lot > maxLotBroker) lot = RoundVolumeToStep(maxLotBroker);

   if(lot < minLot)
   {
      if(!InpAllowMinLotFallback) return 0.0;   // refuse: the risk would exceed InpRiskPercent

      if(!g_minLotWarned)
      {
         g_minLotWarned = true;
         Log(StringFormat("risk %.2f%% of %.2f balance is smaller than the broker minimum lot (%s). " +
                          "Trading %s anyway because InpAllowMinLotFallback=true - real risk per trade is higher " +
                          "than the configured risk.", InpRiskPercent,
                          AccountInfoDouble(ACCOUNT_BALANCE), DoubleToString(minLot, 2),
                          DoubleToString(minLot, 2)));
      }
      return minLot;
   }
   return lot;
}

//+------------------------------------------------------------------+
//| Money at risk if the stop is hit, for a given lot and distance.      |
//+------------------------------------------------------------------+
double RiskForLots(const double lots, const double slDist)
{
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   if(tickSize <= 0.0 || tickValue <= 0.0 || lots <= 0.0 || slDist <= 0.0) return 0.0;
   return (slDist / tickSize) * tickValue * lots;
}

//+------------------------------------------------------------------+
double RoundVolumeToStep(const double volume)
{
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return NormalizeDouble(volume, 2);

   const double steps = MathFloor(volume / step + 0.0000001);
   double lot = steps * step;

   int digits = 2;
   if(step < 1.0)
   {
      digits = 0;
      double s = step;
      while(s < 1.0 && digits < 8)
      {
         s *= 10.0;
         digits++;
      }
   }
   return NormalizeDouble(lot, digits);
}

//====================================================================
//  POSITION MANAGEMENT (the part that does the work)
//====================================================================
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ManagePosition(ticket);
   }
}

//+------------------------------------------------------------------+
void ManagePosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   const double curSL  = PositionGetDouble(POSITION_SL);
   const double curTP  = PositionGetDouble(POSITION_TP);
   const double volume = PositionGetDouble(POSITION_VOLUME);
   const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

   const bool isBuy = (ptype == POSITION_TYPE_BUY);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double price = isBuy ? bid : ask;
   if(price <= 0.0 || volume <= 0.0) return;

   // Frozen side: management is suspended by the PAUSE button.
   if(isBuy && g_pausedBuy) return;
   if(!isBuy && g_pausedSell) return;

   const double r = RiskDistance(ticket, ptype, entry, curSL);
   if(r <= 0.0) return;

   const double tp1 = TargetLevel(ptype, entry, r, g_tp1R);
   const double tp2 = TargetLevel(ptype, entry, r, g_tp2R);

   int stage = GetStage(ticket, ptype, entry, curSL, curTP);

   // ---------------- TP1: take partial, lock break-even -------------
   if(stage == 0 && Reached(price, tp1, ptype))
   {
      const double part = PartialVolume(volume, InpTP1Pct);
      if(part > 0.0)
      {
         if(!trade.PositionClosePartial(ticket, part))
            Log("TP1 partial failed on #" + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
      }
      SetStage(ticket, 1);
      DrawMarker(tp1, clrOrange, 159);
      const double newSL = isBuy ? entry + InpBE_OffsetPoints * _Point
                                 : entry - InpBE_OffsetPoints * _Point;
      SafeModify(ticket, ptype, newSL, curTP);
      stage = 1;
      if(InpVerboseLog)
         Log("TP1 hit #" + IntegerToString((long)ticket) + " - partial " +
             DoubleToString(part, 2) + " lots, stop to break-even");
      if(!PositionSelectByTicket(ticket)) return;
   }

   // ---------------- TP2: take partial, let the runner run ----------
   if(stage == 1 && Reached(price, tp2, ptype))
   {
      const double volNow = PositionGetDouble(POSITION_VOLUME);
      const double part = PartialVolume(volNow, InpTP2Pct);
      if(part > 0.0)
      {
         if(!trade.PositionClosePartial(ticket, part))
            Log("TP2 partial failed on #" + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
      }
      SetStage(ticket, 2);
      if(PositionSelectByTicket(ticket))
      {
         const double lockSL = isBuy ? MathMax(PositionGetDouble(POSITION_SL), tp1)
                                     : MathMin(PositionGetDouble(POSITION_SL), tp1);
         SafeModify(ticket, ptype, lockSL, 0.0);
      }
      DrawMarker(tp2, clrOrange, 159);
      stage = 2;
      if(InpVerboseLog)
         Log("TP2 hit #" + IntegerToString((long)ticket) + " - partial " +
             DoubleToString(part, 2) + " lots, runner protected");
      if(!PositionSelectByTicket(ticket)) return;
   }

   // ---------------- Trailing stop ----------------------------------
   if(InpUseTrailing && stage >= InpTrailAfterStage)
      TrailPosition(ticket, ptype, entry, price, r, stage);

   // ---------------- Time stop --------------------------------------
   if(InpMaxBarsInTrade > 0)
   {
      const int barsHeld = (int)((TimeCurrent() - opened) / MathMax(1, PeriodSeconds()));
      if(barsHeld >= InpMaxBarsInTrade)
      {
         if(PositionSelectByTicket(ticket) &&
            PositionGetDouble(POSITION_PROFIT) <= 0.0)
         {
            if(trade.PositionClose(ticket))
               Log("time stop closed #" + IntegerToString((long)ticket) +
                   " after " + IntegerToString(barsHeld) + " bars");
         }
      }
   }
}

//+------------------------------------------------------------------+
void TrailPosition(const ulong ticket, const ENUM_POSITION_TYPE ptype,
                   const double entry, const double price,
                   const double r, const int stage)
{
   if(!PositionSelectByTicket(ticket)) return;

   const bool isBuy = (ptype == POSITION_TYPE_BUY);
   const double curSL = PositionGetDouble(POSITION_SL);
   const double curTP = PositionGetDouble(POSITION_TP);

   // Activation: price must be a set number of risk units in profit.
   const double profitDist = isBuy ? (price - entry) : (entry - price);
   if(r > 0.0 && profitDist < InpTrailStartR * r) return;

   double dist = InpTrailPoints * _Point;
   if(dist <= 0.0) dist = MathMax(g_atr * 1.2, 200 * _Point);

   const double stepNeeded = MathMax(1.0, (double)InpTrailStepPoints) * _Point;
   double newSL = isBuy ? price - dist : price + dist;

   // Once a partial has been banked the stop must never be worse than break-even.
   if(stage >= 1)
   {
      if(isBuy && newSL < entry) newSL = entry;
      if(!isBuy && newSL > entry) newSL = entry;
   }

   if(isBuy)
   {
      if(curSL > 0.0 && newSL < curSL + stepNeeded) return;
      SafeModify(ticket, ptype, newSL, curTP);
   }
   else
   {
      if(curSL > 0.0 && newSL > curSL - stepNeeded) return;
      SafeModify(ticket, ptype, newSL, curTP);
   }
}

//+------------------------------------------------------------------+
//| Modify SL/TP while respecting the broker's stop level.               |
//+------------------------------------------------------------------+
bool SafeModify(const ulong ticket, const ENUM_POSITION_TYPE ptype,
                double sl, double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;

   const bool isBuy = (ptype == POSITION_TYPE_BUY);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stopsLevel * _Point;
   if(minDist < 10 * _Point) minDist = 10 * _Point;

   if(sl > 0.0)
   {
      if(isBuy)
      {
         if(bid - sl < minDist) sl = bid - minDist;
      }
      else
      {
         if(sl - ask < minDist) sl = ask + minDist;
      }
      sl = NormalizeDouble(sl, _Digits);
   }

   if(tp > 0.0)
   {
      if(isBuy)
      {
         if(tp - bid < minDist) tp = 0.0;   // target already inside stop level
      }
      else
      {
         if(ask - tp < minDist) tp = 0.0;
      }
      if(tp > 0.0) tp = NormalizeDouble(tp, _Digits);
   }

   if(!trade.PositionModify(ticket, sl, tp))
   {
      if(InpVerboseLog)
         Log("modify failed #" + IntegerToString((long)ticket) + " SL " +
             DoubleToString(sl, _Digits) + " TP " + DoubleToString(tp, _Digits) +
             " : " + trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//====================================================================
//  STATE HELPERS (per-ticket risk unit and stage)
//====================================================================
string StateName(const string kind, const ulong ticket)
{
   return g_prefix + kind + "_" + IntegerToString((long)ticket);
}

double RiskDistance(const ulong ticket, const ENUM_POSITION_TYPE ptype,
                    const double entry, const double curSL)
{
   const string nm = StateName("R", ticket);
   if(GlobalVariableCheck(nm))
   {
      const double v = GlobalVariableGet(nm);
      if(v > 0.0) return v;
   }

   // Fallback 1: distance from entry to the live stop
   if(curSL > 0.0)
   {
      const double d = MathAbs(entry - curSL);
      if(d > 0.0 && (ptype == POSITION_TYPE_BUY ? curSL < entry : curSL > entry))
      {
         GlobalVariableSet(nm, d);
         return d;
      }
   }

   // Fallback 2: current volatility
   double d = g_atr * InpSL_ATR;
   if(InpMinSLPoints > 0 && d < InpMinSLPoints * _Point) d = InpMinSLPoints * _Point;
   if(d > 0.0) GlobalVariableSet(nm, d);
   return d;
}

//+------------------------------------------------------------------+
double TargetLevel(const ENUM_POSITION_TYPE ptype, const double entry,
                   const double r, const double mult)
{
   return (ptype == POSITION_TYPE_BUY) ? entry + r * mult : entry - r * mult;
}

//+------------------------------------------------------------------+
bool Reached(const double price, const double level, const ENUM_POSITION_TYPE ptype)
{
   return (ptype == POSITION_TYPE_BUY) ? (price >= level) : (price <= level);
}

//+------------------------------------------------------------------+
int GetStage(const ulong ticket, const ENUM_POSITION_TYPE ptype,
             const double entry, const double curSL, const double curTP)
{
   // Stage = number of partial take-profits already banked.
   const string nm = StateName("S", ticket);
   if(GlobalVariableCheck(nm))
   {
      const int s = (int)GlobalVariableGet(nm);
      if(s >= 0 && s <= 2) return s;
   }

   // Infer after a terminal restart.
   if(curTP == 0.0) return 2;
   if(curSL > 0.0)
   {
      if(ptype == POSITION_TYPE_BUY  && curSL >= entry - 2 * _Point) return 1;
      if(ptype == POSITION_TYPE_SELL && curSL <= entry + 2 * _Point) return 1;
   }
   return 0;
}

//+------------------------------------------------------------------+
void SetStage(const ulong ticket, const int stage)
{
   GlobalVariableSet(StateName("S", ticket), (double)stage);
}

//+------------------------------------------------------------------+
double PartialVolume(const double volume, const double pct)
{
   if(pct <= 0.0) return 0.0;
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double part = RoundVolumeToStep(volume * pct / 100.0);
   if(part < minLot) return 0.0;
   if(volume - part < minLot) return 0.0;   // never fully close with a partial
   return part;
}

//====================================================================
//  MARKET / ACCOUNT GUARDS
//====================================================================
bool TradingAllowed()
{
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))        return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))  return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))   return false;
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}

//+------------------------------------------------------------------+
bool SpreadOk()
{
   if(InpMaxSpreadPoints <= 0) return true;
   const long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= (long)InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
bool SessionOk()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   if(InpAvoidFriday && t.day_of_week == 5 && t.hour >= InpFridayStopHour) return false;
   if(t.day_of_week == 0 || t.day_of_week == 6) return false;   // weekend

   if(!InpUseSession) return true;

   const int h = t.hour;
   if(InpSessionStart <= InpSessionEnd) return (h >= InpSessionStart && h < InpSessionEnd);
   return (h >= InpSessionStart || h < InpSessionEnd);           // overnight session
}

//+------------------------------------------------------------------+
bool CooldownOk(const datetime lastEntryBarTime)
{
   if(InpCooldownBars <= 0 || lastEntryBarTime <= 0) return true;
   const datetime nowBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(nowBar <= lastEntryBarTime) return false;
   const int barsSince = (int)((nowBar - lastEntryBarTime) / MathMax(1, PeriodSeconds()));
   return (barsSince >= InpCooldownBars);
}

//+------------------------------------------------------------------+
bool HistoryReady()
{
   int need = (int)MathMax(InpATRPeriod + 2, MathMax(InpBreakoutBars + 3, InpSweepBars + 3)) + 5;
   if(InpUseTrendFilter) need = (int)MathMax((double)need, (double)InpTrendBars + 5.0);
   return (Bars(_Symbol, PERIOD_CURRENT) > need);
}

//+------------------------------------------------------------------+
bool NewBar()
{
   const datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == 0) return false;
   if(t != g_lastBar)
   {
      g_lastBar = t;
      return true;
   }
   return false;
}

//====================================================================
//  DAILY PROTECTION
//====================================================================
datetime DayStart()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0;
   t.min  = 0;
   t.sec  = 0;
   return StructToTime(t);
}

//+------------------------------------------------------------------+
void RollDay()
{
   const datetime today = DayStart();
   if(today != g_dayStamp)
   {
      g_dayStamp    = today;
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayBlocked  = false;
      PurgeStateGlobals();
      Log("new trading day - daily counters reset, start balance " +
          DoubleToString(g_dayStartBal, 2));
   }

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartBal <= 0.0) return;
   const double pct = (equity - g_dayStartBal) / g_dayStartBal * 100.0;

   if(!g_dayBlocked && InpMaxDailyLossPct > 0.0 && pct <= -InpMaxDailyLossPct)
   {
      g_dayBlocked = true;
      Log("DAILY LOSS LIMIT hit (" + DoubleToString(pct, 2) + "%) - no new trades today");
      if(InpCloseOnDayLimit) CloseAll("daily loss limit");
   }
   else if(!g_dayBlocked && InpDailyTargetPct > 0.0 && pct >= InpDailyTargetPct)
   {
      g_dayBlocked = true;
      Log("DAILY TARGET reached (" + DoubleToString(pct, 2) + "%) - no new trades today");
      if(InpCloseOnDayLimit) CloseAll("daily target");
   }
}

//+------------------------------------------------------------------+
//| Delete per-ticket state for positions that no longer exist, so the   |
//| terminal's global-variable pool never fills up.                      |
//+------------------------------------------------------------------+
void PurgeStateGlobals()
{
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      const string nm = GlobalVariableName(i);
      if(StringFind(nm, g_prefix) != 0) continue;

      int cut = StringFind(nm, "_R_");
      if(cut >= 0) cut += 3;
      else
      {
         cut = StringFind(nm, "_S_");
         if(cut < 0) continue;
         cut += 3;
      }

      const long ticket = StringToInteger(StringSubstr(nm, cut));
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket((ulong)ticket))
         GlobalVariableDel(nm);
   }
}

//====================================================================
//  POSITION QUERIES / BULK ACTIONS
//====================================================================
int CountPositions(const ENUM_POSITION_TYPE ptype)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != (long)ptype) continue;
      n++;
   }
   return n;
}

//+------------------------------------------------------------------+
int CountAllPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      n++;
   }
   return n;
}

//+------------------------------------------------------------------+
ulong NewestPositionTicket(const ENUM_POSITION_TYPE ptype)
{
   ulong best = 0;
   datetime bestTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != (long)ptype) continue;
      const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= bestTime) { bestTime = t; best = ticket; }
   }
   return best;
}

//+------------------------------------------------------------------+
void FloatingProfits(double &buyPL, double &sellPL)
{
   buyPL = 0.0;
   sellPL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      const double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyPL += pl;
      else                                                      sellPL += pl;
   }
}

//+------------------------------------------------------------------+
void CloseSide(const ENUM_POSITION_TYPE ptype)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != (long)ptype) continue;
      if(trade.PositionClose(ticket)) closed++;
   }
   if(closed > 0)
      SetStatus(StringFormat("closed %d %s position(s)", closed,
                (ptype == POSITION_TYPE_BUY ? "BUY" : "SELL")));
}

//+------------------------------------------------------------------+
void CloseAll(const string reason)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(trade.PositionClose(ticket)) closed++;
   }
   if(closed > 0) Log("closed " + IntegerToString(closed) + " position(s): " + reason);
}

//====================================================================
//  VOLATILITY / STRUCTURE (raw OHLC, no indicators)
//====================================================================
double TrueRangeAt(const int shift)
{
   const double h  = iHigh(_Symbol, PERIOD_CURRENT, shift);
   const double l  = iLow(_Symbol, PERIOD_CURRENT, shift);
   const double pc = iClose(_Symbol, PERIOD_CURRENT, shift + 1);
   const double a = h - l;
   const double b = MathAbs(h - pc);
   const double c = MathAbs(l - pc);
   return MathMax(a, MathMax(b, c));
}

//+------------------------------------------------------------------+
double ATRValue(const int period)
{
   if(period <= 0) return 0.0;
   if(Bars(_Symbol, PERIOD_CURRENT) < period + 3) return 0.0;
   double sum = 0.0;
   for(int i = 1; i <= period; i++) sum += TrueRangeAt(i);
   return sum / (double)period;
}

//+------------------------------------------------------------------+
double HighestHigh(const int bars, const int startShift)
{
   double hh = -DBL_MAX;
   for(int i = startShift; i < startShift + bars; i++)
   {
      const double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(h > hh) hh = h;
   }
   return hh;
}

//+------------------------------------------------------------------+
double LowestLow(const int bars, const int startShift)
{
   double ll = DBL_MAX;
   for(int i = startShift; i < startShift + bars; i++)
   {
      const double l = iLow(_Symbol, PERIOD_CURRENT, i);
      if(l < ll) ll = l;
   }
   return ll;
}

//====================================================================
//  CHART MARKERS
//====================================================================
void DrawEntry(const ENUM_POSITION_TYPE ptype, const double price)
{
   TrimMarkers();
   const string nm = g_prefix + "ENT_" + IntegerToString((long)TimeCurrent()) + "_" +
                     IntegerToString(g_markerCount++);
   const datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(!ObjectCreate(0, nm, OBJ_ARROW, 0, t, price)) return;
   ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, (ptype == POSITION_TYPE_BUY) ? 233 : 234);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, (ptype == POSITION_TYPE_BUY) ? clrDodgerBlue : clrOrange);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, (ptype == POSITION_TYPE_BUY) ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, nm, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
void DrawMarker(const double price, const color clr, const int code)
{
   TrimMarkers();
   const string nm = g_prefix + "TP_" + IntegerToString((long)TimeCurrent()) + "_" +
                     IntegerToString(g_markerCount++);
   const datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(!ObjectCreate(0, nm, OBJ_ARROW, 0, t, price)) return;
   ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, nm, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
void TrimMarkers()
{
   if(g_markerCount < 240) return;
   ObjectsDeleteAll(0, g_prefix + "ENT_");
   ObjectsDeleteAll(0, g_prefix + "TP_");
   g_markerCount = 0;
}

//====================================================================
//  PANEL
//====================================================================
void BuildPanel()
{
   // backdrop
   CreateRect(g_prefix + "PNL_BG", 8, 24, 668, 104, C'22,22,22', C'60,60,60');
   CreateLabel(g_prefix + "LBL_TITLE", "ANT DISCIPLE", 18, 32, C'255,196,0', 11, true);
   CreateLabel(g_prefix + "LBL_SUB", "price action engine - no RSI / MACD / MA", 152, 36, C'150,150,150', 8, false);

   const int y = 56, h = 22, w = 82, gap = 5;
   int x = 18;
   CreateButton(g_prefix + "BTN_BUYON",   "BUY OFF",  x, y, w, h, C'0,150,70');   x += w + gap;
   CreateButton(g_prefix + "BTN_CLOSEBUY","CLOSE BUY", x, y, w, h, C'0,150,70');   x += w + gap;
   CreateButton(g_prefix + "BTN_PAUSEBUY","PAUSE OFF", x, y, w, h, C'235,140,0');  x += w + gap + 18;
   CreateButton(g_prefix + "BTN_SELLON",  "SELL OFF", x, y, w, h, C'235,140,0');   x += w + gap;
   CreateButton(g_prefix + "BTN_CLOSESELL","CLOSE SELL", x, y, w, h, C'235,140,0');x += w + gap;
   CreateButton(g_prefix + "BTN_PAUSESELL","PAUSE OFF", x, y, w, h, C'235,140,0'); x += w + gap + 18;
   CreateButton(g_prefix + "BTN_NEWCYCLE","NEW CYCLE", x, y, w, h, C'180,40,180');

   CreateLabel(g_prefix + "LBL_BUYPL",  "Buy profit: 0.00",  18, 90, clrWhite, 9, true);
   CreateLabel(g_prefix + "LBL_SELLPL", "Sell profit: 0.00", 180, 90, clrWhite, 9, true);
   CreateLabel(g_prefix + "LBL_DAYPL",  "Daily profit: 0.00", 360, 90, clrWhite, 9, true);
   CreateLabel(g_prefix + "LBL_STATUS", "", 18, 112, C'165,165,165', 8, false);

   RefreshButtons();
   ChartRedraw();
}

//+------------------------------------------------------------------+
void CreateRect(const string name, const int x, const int y,
                const int w, const int h, const color bg, const color border)
{
   if(ObjectFind(0, name) < 0 && !ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0)) return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
void CreateLabel(const string name, const string text, const int x, const int y,
                 const color fg, const int fontSize, const bool bold)
{
   if(ObjectFind(0, name) < 0 && !ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0)) return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
void CreateButton(const string name, const string text, const int x, const int y,
                  const int w, const int h, const color bg)
{
   if(ObjectFind(0, name) < 0 && !ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0)) return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'40,40,40');
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
void RefreshButtons()
{
   if(!g_panelOn) return;

   SetButton(g_prefix + "BTN_BUYON",  g_entryBuyOn ? "BUY ON" : "BUY OFF",
             g_entryBuyOn ? C'0,150,70' : C'90,90,90');
   SetButton(g_prefix + "BTN_SELLON", g_entrySellOn ? "SELL ON" : "SELL OFF",
             g_entrySellOn ? C'235,140,0' : C'90,90,90');

   SetButton(g_prefix + "BTN_PAUSEBUY", g_pausedBuy ? "PAUSED" : "PAUSE OFF",
             g_pausedBuy ? C'180,30,30' : C'235,140,0');
   SetButton(g_prefix + "BTN_PAUSESELL", g_pausedSell ? "PAUSED" : "PAUSE OFF",
             g_pausedSell ? C'180,30,30' : C'235,140,0');
}

//+------------------------------------------------------------------+
void SetButton(const string name, const string text, const color bg)
{
   if(ObjectFind(0, name) < 0) return;
   if(ObjectGetString(0, name, OBJPROP_TEXT) != text)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   if((color)ObjectGetInteger(0, name, OBJPROP_BGCOLOR) != bg)
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
}

//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!g_panelOn) return;

   double buyPL = 0.0, sellPL = 0.0;
   FloatingProfits(buyPL, sellPL);
   const double dayPL = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBal;

   SetLabel(g_prefix + "LBL_BUYPL",  StringFormat("Buy profit: %.2f", buyPL),  buyPL >= 0 ? clrWhite : clrTomato);
   SetLabel(g_prefix + "LBL_SELLPL", StringFormat("Sell profit: %.2f", sellPL), sellPL >= 0 ? clrWhite : clrTomato);
   SetLabel(g_prefix + "LBL_DAYPL",  StringFormat("Daily profit: %.2f", dayPL), dayPL >= 0 ? clrWhite : clrTomato);

   const double dayPct = (g_dayStartBal > 0.0)
                       ? (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBal) / g_dayStartBal * 100.0
                       : 0.0;
   const string info = StringFormat("%s %s | ATR %s | spread %d pts | open L%d / S%d | day %.2f%% | TP %sR / %sR / %sR | %s",
                                    _Symbol,
                                    EnumToString((ENUM_TIMEFRAMES)Period()),
                                    DoubleToString(g_atr, _Digits),
                                    (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
                                    CountPositions(POSITION_TYPE_BUY),
                                    CountPositions(POSITION_TYPE_SELL),
                                    dayPct,
                                    DoubleToString(g_tp1R, 2),
                                    DoubleToString(g_tp2R, 2),
                                    DoubleToString(g_tp3R, 2),
                                    g_status);
   SetLabel(g_prefix + "LBL_STATUS", info, g_dayBlocked ? clrOrange : C'165,165,165');
}

//+------------------------------------------------------------------+
void SetLabel(const string name, const string text, const color fg)
{
   if(ObjectFind(0, name) < 0) return;

   static datetime lastRedraw = 0;
   static bool     pending    = false;

   bool changed = false;
   if(ObjectGetString(0, name, OBJPROP_TEXT) != text)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      changed = true;
   }
   if((color)ObjectGetInteger(0, name, OBJPROP_COLOR) != fg)
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
      changed = true;
   }

   if(changed) pending = true;

   // Repaint at most once per second so a fast tick stream cannot stall the chart.
   if(pending && TimeCurrent() != lastRedraw)
   {
      lastRedraw = TimeCurrent();
      pending    = false;
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
void SetStatus(const string text)
{
   if(g_status != text) g_status = text;
   if(InpVerboseLog && text != g_statusShown)
   {
      g_statusShown = text;
      Print("ANT DISCIPLE: ", text);
   }
}

//+------------------------------------------------------------------+
void Log(const string text)
{
   Print("ANT DISCIPLE: ", text);
}

//====================================================================
//  PANEL EVENTS
//====================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam, g_prefix + "BTN_") != 0) return;

   // release the pressed state so the button can be clicked again
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   if(sparam == g_prefix + "BTN_BUYON")
   {
      g_entryBuyOn = !g_entryBuyOn;
      SetStatus(g_entryBuyOn ? "BUY engine enabled" : "BUY engine disabled");
   }
   else if(sparam == g_prefix + "BTN_SELLON")
   {
      g_entrySellOn = !g_entrySellOn;
      SetStatus(g_entrySellOn ? "SELL engine enabled" : "SELL engine disabled");
   }
   else if(sparam == g_prefix + "BTN_CLOSEBUY")
   {
      CloseSide(POSITION_TYPE_BUY);
   }
   else if(sparam == g_prefix + "BTN_CLOSESELL")
   {
      CloseSide(POSITION_TYPE_SELL);
   }
   else if(sparam == g_prefix + "BTN_PAUSEBUY")
   {
      g_pausedBuy = !g_pausedBuy;
      SetStatus(g_pausedBuy ? "BUY side paused (management frozen)" : "BUY side resumed");
   }
   else if(sparam == g_prefix + "BTN_PAUSESELL")
   {
      g_pausedSell = !g_pausedSell;
      SetStatus(g_pausedSell ? "SELL side paused (management frozen)" : "SELL side resumed");
   }
   else if(sparam == g_prefix + "BTN_NEWCYCLE")
   {
      CloseAll("new cycle");
      GlobalVariablesDeleteAll(g_prefix, (datetime)0);
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayStamp    = DayStart();
      g_dayBlocked  = false;
      g_pausedBuy   = false;
      g_pausedSell  = false;
      g_entryBuyOn  = InpAllowBuy;
      g_entrySellOn = InpAllowSell;
      ObjectsDeleteAll(0, g_prefix + "ENT_");
      ObjectsDeleteAll(0, g_prefix + "TP_");
      g_markerCount = 0;
      SetStatus("new cycle - counters reset");
   }

   RefreshButtons();
   UpdatePanel();
   ChartRedraw();
}
//+------------------------------------------------------------------+
