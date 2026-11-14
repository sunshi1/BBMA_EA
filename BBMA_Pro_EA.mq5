//+------------------------------------------------------------------+
//|                                              BBMA_Pro_EA.mq5     |
//|         BBMA Pro Signals - Spread-Optimized Auto Trader          |
//|         For high-spread accounts (35-40+ points)                 |
//+------------------------------------------------------------------+
#property copyright "BBMA Pro EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  pos;
CSymbolInfo    sym;

//====================== INPUTS ======================
input group "=== 1. Bollinger Bands ==="
input int    InpBBLen      = 20;
input double InpBBMult     = 2.0;

input group "=== 2. Signal Setup ==="
input bool   InpShowMHV    = true;
input bool   InpShowRE     = true;
input int    InpMhvWindow  = 10;
input int    InpBiasBars   = 30;
input int    InpCooldown   = 5;

input group "=== 3. Trend Filter ==="
input bool           InpUseHTF = true;
input ENUM_TIMEFRAMES InpHTF   = PERIOD_H1;

input group "=== 4. SL / TP (SPREAD-AWARE) ==="
input int    InpAtrLen       = 14;
input int    InpSlBars       = 3;
input double InpSlMult       = 1.0;   // ATR buffer (កើនពី 0.5 → 1.0)
input double InpRR1          = 2.5;   // កើនពី 1.5 → 2.5
input double InpRR2          = 4.5;   // កើនពី 3.0 → 4.5
input double InpMinSLxSpread = 5.0;   // SL យ៉ាងតិច 5x spread
input double InpSLBufferPts  = 20;    // buffer បន្ថែម (points)

input group "=== 5. SPREAD FILTER ==="
input double InpMaxSpreadPts = 50;    // ហាម trade បើ spread > 50 pts
input double InpMinEffRR     = 1.0;   // Effective RR អប្បបរមា

input group "=== 6. RISK MANAGEMENT ==="
input double InpRiskPercent = 1.0;    // % ហានិភ័យ/ trade
input double InpFixedLot    = 0.0;    // ប្រើ fixed lot (0 = ប្រើ %risk)
input double InpMaxLot      = 10.0;

input group "=== 7. PARTIAL CLOSE (TP1) ==="
input bool   InpUsePartialClose = true;
input double InpPartialPercent  = 50.0;  // % បិទនៅ TP1
input bool   InpMoveToBE        = true;  // SL ដល់ BE ក្រោយ TP1

input group "=== 8. TRADE SETTINGS ==="
input long   InpMagic       = 20241114;
input string InpComment     = "BBMA Pro";
input bool   InpEnableLong  = true;
input bool   InpEnableShort = true;

input group "=== 9. NEWS PROTECTION ==="
input bool   InpPauseOnNews   = true;
input int    InpNewsMinBefore = 15;
input int    InpNewsMinAfter  = 15;

//====================== GLOBALS ======================
int    hBB, hMA5H, hMA5L, hMA10H, hMA10L, hEMA50, hATR, hHTF;
datetime gLastBarTime = 0;

// signal state (mimics Pine "var")
int    gSellArmBar  = -1;
int    gBuyArmBar   = -1;
int    gSellBiasBar = -1;
int    gBuyBiasBar  = -1;
int    gLastSigBar  = -1;

// active trade tracking
struct TradeState
{
   bool     active;
   int      dir;
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   bool     tp1Done;
   bool     beSet;
   ulong    ticket;
   double   originalLot;
};
TradeState gTrade;

//====================== INIT ======================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   hBB    = iBands(_Symbol, _Period, InpBBLen, 0, InpBBMult, PRICE_CLOSE);
   hMA5H  = iMA(_Symbol, _Period, 5,  0, MODE_LWMA, PRICE_HIGH);
   hMA5L  = iMA(_Symbol, _Period, 5,  0, MODE_LWMA, PRICE_LOW);
   hMA10H = iMA(_Symbol, _Period, 10, 0, MODE_LWMA, PRICE_HIGH);
   hMA10L = iMA(_Symbol, _Period, 10, 0, MODE_LWMA, PRICE_LOW);
   hEMA50 = iMA(_Symbol, _Period, 50, 0, MODE_EMA,  PRICE_CLOSE);
   hATR   = iATR(_Symbol, _Period, InpAtrLen);
   hHTF   = iMA(_Symbol, InpHTF, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(hBB==INVALID_HANDLE || hMA5H==INVALID_HANDLE || hMA5L==INVALID_HANDLE ||
      hMA10H==INVALID_HANDLE || hMA10L==INVALID_HANDLE || hEMA50==INVALID_HANDLE ||
      hATR==INVALID_HANDLE || hHTF==INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   ResetTradeState();
   Print("BBMA Pro EA initialized. Max spread: ", InpMaxSpreadPts, " pts");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // nothing
}

void ResetTradeState()
{
   gTrade.active   = false;
   gTrade.dir      = 0;
   gTrade.entry    = 0;
   gTrade.sl       = 0;
   gTrade.tp1      = 0;
   gTrade.tp2      = 0;
   gTrade.tp1Done  = false;
   gTrade.beSet    = false;
   gTrade.ticket   = 0;
   gTrade.originalLot = 0;
}

//====================== HELPERS ======================
double CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(_Point <= 0) return 0;
   return (ask - bid) / _Point;
}

double GetBuffer(int handle, int bufIdx, int shift, int count, double &out[])
{
   if(CopyBuffer(handle, bufIdx, shift, count, out) != count) return 0;
   return 1;
}

bool IsNewsTime()
{
   if(!InpPauseOnNews) return false;

   MqlCalendarValue values[];
   datetime from = TimeCurrent() - InpNewsMinAfter * 60;
   datetime to   = TimeCurrent() + InpNewsMinBefore * 60;

   if(CalendarValueHistory(values, from, to, NULL, NULL))
   {
      for(int i = 0; i < ArraySize(values); i++)
      {
         MqlCalendarEvent ev;
         if(CalendarEventById(values[i].event_id, ev))
         {
            if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
               return true;
         }
      }
   }
   return false;
}

double CalcLotSize(double slPoints)
{
   if(InpFixedLot > 0) return MathMin(InpFixedLot, InpMaxLot);

   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || slPoints <= 0) return 0.01;

   double valuePerPointPerLot = tickValue * (_Point / tickSize);
   double lot = riskAmount / (slPoints * valuePerPointPerLot);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLot);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   return NormalizeDouble(lot, 2);
}

//====================== ONTICK ======================
void OnTick()
{
   // ==== manage open trade on every tick (SL/TP/BE/Partial) ====
   ManageOpenTrade();

   // ==== only evaluate signals on new bar ====
   datetime curBar = iTime(_Symbol, _Period, 0);
   if(curBar == gLastBarTime) return;
   gLastBarTime = curBar;

   // ==== spread filter ====
   double sp = CurrentSpreadPoints();
   if(sp > InpMaxSpreadPts)
   {
      Print("Spread too high: ", sp, " pts — skip signal check");
      return;
   }

   // ==== news filter ====
   if(IsNewsTime())
   {
      Print("High-impact news window — skip");
      return;
   }

   // ==== only 1 position at a time ====
   if(gTrade.active && pos.SelectByTicket(gTrade.ticket))
      return;

   // ==== detect signal ====
   int sig = DetectSignal();
   if(sig == 0) return;

   // ==== already in trade? skip ====
   if(gTrade.active) return;

   // ==== open trade ====
   ExecuteSignal(sig);
}

//====================== SIGNAL LOGIC ======================
int DetectSignal()
{
   int bars = 100;
   double upper[], mid[], lower[];
   double m5h[], m5l[], ema[], atr[];
   double htfEma[];

   if(CopyBuffer(hBB, 1, 0, bars, upper)  != bars) return 0;
   if(CopyBuffer(hBB, 0, 0, bars, mid)    != bars) return 0;
   if(CopyBuffer(hBB, 2, 0, bars, lower)  != bars) return 0;
   if(CopyBuffer(hMA5H, 0, 0, bars, m5h)  != bars) return 0;
   if(CopyBuffer(hMA5L, 0, 0, bars, m5l)  != bars) return 0;
   if(CopyBuffer(hEMA50, 0, 0, bars, ema) != bars) return 0;
   if(CopyBuffer(hATR,   0, 0, bars, atr) != bars) return 0;

   // current completed bar index = 1 (bar 0 is forming)
   int i = 1;
   int iShift = bars - 1 - i;  // array index (chronological)

   // use raw price arrays
   double close[], high[], low[];
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   if(CopyClose(_Symbol, _Period, 0, bars, close) != bars) return 0;
   if(CopyHigh(_Symbol, _Period, 0, bars, high)  != bars) return 0;
   if(CopyLow(_Symbol, _Period, 0, bars, low)    != bars) return 0;

   int idx = bars - 1 - i;
   int pIdx = idx - 1;

   double cUp = upper[idx], cMid = mid[idx], cLow = lower[idx];
   double cm5h = m5h[idx], cm5l = m5l[idx];

   bool extremeSell = (cm5h > cUp);
   bool extremeBuy  = (cm5l < cLow);

   // armed windows
   bool armedSell = (gSellArmBar >= 0) && (i > gSellArmBar) && (i - gSellArmBar <= InpMhvWindow);
   bool armedBuy  = (gBuyArmBar  >= 0) && (i > gBuyArmBar)  && (i - gBuyArmBar  <= InpMhvWindow);

   bool mhvSell = armedSell && (high[idx] >= cUp) && (close[idx] < cUp) && (cm5h <= cUp);
   bool mhvBuy  = armedBuy  && (low[idx]  <= cLow) && (close[idx] > cLow) && (cm5l >= cLow);

   bool biasSell = (gSellBiasBar >= 0) && (i > gSellBiasBar) && (i - gSellBiasBar <= InpBiasBars);
   bool biasBuy  = (gBuyBiasBar  >= 0) && (i > gBuyBiasBar)  && (i - gBuyBiasBar  <= InpBiasBars);

   bool reSell = biasSell && (high[idx] >= cMid) && (high[pIdx] < mid[pIdx]) && (close[idx] < cMid);
   bool reBuy  = biasBuy  && (low[idx]  <= cMid) && (low[pIdx]  > mid[pIdx]) && (close[idx] > cMid);

   bool rawBuy  = (InpShowMHV && mhvBuy)  || (InpShowRE && reBuy);
   bool rawSell = (InpShowMHV && mhvSell) || (InpShowRE && reSell);

   bool canSig = (gLastSigBar < 0) || (i - gLastSigBar >= InpCooldown);

   // HTF filter
   bool htfUp = true;
   if(InpUseHTF)
   {
      double hc[];
      double he[];
      if(CopyClose(_Symbol, InpHTF, 0, 2, hc) == 2 &&
         CopyBuffer(hHTF, 0, 0, 2, he) == 2)
      {
         // series order: [0] = current HTF bar (forming), [1] = last closed
         htfUp = (hc[1] > he[1]);
      }
   }

   bool buySig  = rawBuy  && canSig && (!InpUseHTF || htfUp)  && InpEnableLong;
   bool sellSig = rawSell && canSig && (!InpUseHTF || !htfUp) && InpEnableShort;

   // update state
   if(extremeSell) gSellArmBar = i;
   else if(extremeBuy || mhvSell) gSellArmBar = -1;

   if(extremeSell || mhvSell) gSellBiasBar = i;
   else if(extremeBuy) gSellBiasBar = -1;

   if(extremeBuy) gBuyArmBar = i;
   else if(extremeSell || mhvBuy) gBuyArmBar = -1;

   if(extremeBuy || mhvBuy) gBuyBiasBar = i;
   else if(extremeSell) gBuyBiasBar = -1;

   if(buySig || sellSig) gLastSigBar = i;

   if(buySig)  return 1;
   if(sellSig) return -1;
   return 0;
}

//====================== EXECUTE ======================
void ExecuteSignal(int dir)
{
   // ==== gather data ====
   int bars = 100;
   double close[], high[], low[], atr[];
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(atr, false);

   if(CopyClose(_Symbol, _Period, 0, bars, close) != bars) return;
   if(CopyHigh(_Symbol, _Period, 0, bars, high)  != bars) return;
   if(CopyLow(_Symbol, _Period, 0, bars, low)    != bars) return;
   if(CopyBuffer(hATR, 0, 0, bars, atr) != bars) return;

   int idx = bars - 2;   // last closed bar
   double c = close[idx];
   double atrVal = atr[idx];

   // ==== SL from N bars ====
   double lowN = low[idx], highN = high[idx];
   for(int k = 1; k <= InpSlBars && (idx - k) >= 0; k++)
   {
      lowN  = MathMin(lowN, low[idx - k]);
      highN = MathMax(highN, high[idx - k]);
   }

   double newSL = (dir == 1) ? lowN - atrVal * InpSlMult
                : highN + atrVal * InpSlMult;

   // ==== SPREAD-AWARE MIN SL ====
   double spreadPts = CurrentSpreadPoints();
   double minSLPts  = spreadPts * InpMinSLxSpread;
   double slDistPts = MathAbs(c - newSL) / _Point;

   if(slDistPts < minSLPts)
   {
      double newDist = (minSLPts + InpSLBufferPts) * _Point;
      newSL = (dir == 1) ? c - newDist : c + newDist;
      slDistPts = minSLPts + InpSLBufferPts;
   }
   else
   {
      slDistPts += InpSLBufferPts;
      newSL = (dir == 1) ? c - slDistPts * _Point : c + slDistPts * _Point;
   }

   // ==== TP from RR ====
   double risk  = MathAbs(c - newSL);
   double newT1 = (dir == 1) ? c + risk * InpRR1 : c - risk * InpRR1;
   double newT2 = (dir == 1) ? c + risk * InpRR2 : c - risk * InpRR2;

   // ==== EFFECTIVE RR FILTER ====
   double spreadCost    = spreadPts * _Point;
   double effectiveRR1  = (MathAbs(newT1 - c) - spreadCost) /
                          (MathAbs(c - newSL) + spreadCost);
   if(effectiveRR1 < InpMinEffRR)
   {
      Print("Signal rejected: effective RR=", effectiveRR1, " < ", InpMinEffRR);
      return;
   }

   // ==== LOT SIZE ====
   double lot = CalcLotSize(slDistPts);
   if(lot <= 0) { Print("Invalid lot"); return; }

   // ==== ENTRY PRICE ====
   double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // round SL/TP to digits
   newSL = NormalizeDouble(newSL, _Digits);
   newT1 = NormalizeDouble(newT1, _Digits);
   newT2 = NormalizeDouble(newT2, _Digits);

   // ==== place order (use TP2 as broker TP, we manage TP1 ourselves) ====
   bool ok = false;
   if(dir == 1)
      ok = trade.Buy(lot, _Symbol, price, newSL, newT2, InpComment);
   else
      ok = trade.Sell(lot, _Symbol, price, newSL, newT2, InpComment);

   if(!ok)
   {
      Print("Order failed: ", trade.ResultRetcodeDescription());
      return;
   }

   // ==== store trade state ====
   gTrade.active      = true;
   gTrade.dir         = dir;
   gTrade.entry       = price;
   gTrade.sl          = newSL;
   gTrade.tp1         = newT1;
   gTrade.tp2         = newT2;
   gTrade.tp1Done     = false;
   gTrade.beSet       = false;
   gTrade.ticket      = trade.ResultOrder();
   gTrade.originalLot = lot;

   Print("Trade opened: dir=", dir, " lot=", lot, " entry=", price,
         " SL=", newSL, " TP1=", newT1, " TP2=", newT2,
         " spread=", spreadPts, " effRR=", DoubleToString(effectiveRR1,2));
}

//====================== MANAGE OPEN TRADE ======================
void ManageOpenTrade()
{
   if(!gTrade.active) return;

   if(!pos.SelectByTicket(gTrade.ticket))
   {
      // position closed (SL or TP2 hit)
      ResetTradeState();
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // ==== check TP1 ====
   if(!gTrade.tp1Done)
   {
      bool t1Hit = (gTrade.dir == 1) ? (bid >= gTrade.tp1)
                                     : (ask <= gTrade.tp1);
      if(t1Hit)
      {
         if(InpUsePartialClose)
         {
            double closeVol = NormalizeDouble(pos.Volume() * InpPartialPercent / 100.0, 2);
            double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double stepLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            closeVol = MathMax(closeVol, minLot);
            closeVol = MathFloor(closeVol / stepLot) * stepLot;

            if(closeVol < pos.Volume())
            {
               if(trade.PositionClosePartial(gTrade.ticket, closeVol))
                  Print("Partial close at TP1: ", closeVol, " lots");
               else
                  Print("Partial close failed: ", trade.ResultRetcodeDescription());
            }
         }

         // ==== move SL to BE + spread buffer ====
         if(InpMoveToBE)
         {
            double spreadPts = CurrentSpreadPoints();
            double beBuffer  = (spreadPts + 20) * _Point;
            double bePrice   = (gTrade.dir == 1) ? gTrade.entry + beBuffer
                                                 : gTrade.entry - beBuffer;
            bePrice = NormalizeDouble(bePrice, _Digits);

            if(pos.SelectByTicket(gTrade.ticket))
            {
               if(trade.PositionModify(gTrade.ticket, bePrice, gTrade.tp2))
               {
                  Print("SL moved to BE: ", bePrice);
                  gTrade.beSet = true;
               }
            }
         }

         gTrade.tp1Done = true;
      }
   }
}

//====================== END ======================
