//+------------------------------------------------------------------+
//|                                     BTCJPY_Hybrid_Pro_V5_0.mq5   |
//|      Structural Supply/Demand + MyEA Full Suite (V5.0 Optimized) |
//|      FIXED: Volatility-adjusted SL, realistic RSI, true trailing |
//+------------------------------------------------------------------+
// CRITICAL FIXES OVER V4.3:
// 1. SL widened 3.48% → 5.0% (BTCJPY wicks regularly hit 3-5%)
// 2. RSI oversold 7.5 → 25 (7.5 was unrealistic for BTCJPY)
// 3. Trail start 1.5% → 3.0% (1.5% triggered too early in volatile BTC)
// 4. Equity gain activation ¥2M → ¥50K (2M was unreachable for 0.01 lot)
// 5. Zone expiry 24h → 48h (4H zones need longer lifespan)
// 6. Body strength 60 → 50 (captures more valid zones)
// 7. Partial TP + Break-Even ENABLED by default
// 8. NEW: MaxDailyLoss protection
// 9. NEW: Max trades per day limit
// 10. Better Dynamic trailing logic
//+------------------------------------------------------------------+
#property copyright "DEN Trading - BTCJPY Hybrid Edition V5.0"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters

input group "=== Core Settings ==="
input long     MagicNumber = 987113;
input int      SlowMAPeriod = 579;
input bool     ShowDashboard = true;
input bool     ShowFullDashboard = true;
input bool     ShowMonthlySummaryOnly = false;

input group "=== RSI Filter (FIXED: More realistic levels) ==="
input bool     UseRSIFilter    = true;
input int      RSIPeriod       = 105;
input double   RSIOverbought   = 58.5;
input double   RSIOversold     = 25.0;        // FIXED: Was 7.5 (NEVER triggered)

input group "=== Spread Filter ==="
input bool     UseSpreadFilter = false;
input int      MaxSpread       = 15000;

input group "=== Risk Management (FIXED: Volatility-adjusted) ==="
input double   FixedLotSize     = 0.01;
input double   StopLossPercent  = 5.0;         // FIXED: Was 3.48% (too tight for BTCJPY)
input double   TakeProfitPercent = 10.0;        // Increased to match wider SL

input group "=== Trailing & Break-even (IMPROVED) ==="
input bool     UseTrailing           = true;
input bool     UseIntelligentTrail   = true;
input double   TrailingStopPct       = 3.0;     // FIXED: Was 1.5% (triggered on noise)
input bool     UseBreakEven          = true;    // FIXED: Was false
input double   BE_TriggerPct         = 2.0;
input double   BE_BufferPct          = 0.5;     // FIXED: Was 0.2% (too tight)

input group "=== Partial Take Profit (IMPROVED - NOW ENABLED) ==="
input bool     UsePartialTP          = true;    // FIXED: Was false
input double   PartialTP_TriggerPct  = 5.0;
input double   PartialClosePct       = 30.0;    // Close 30% at 5% profit

input group "=== Daily Risk Limits (NEW) ==="
input int      MaxTradesPerDay       = 3;       // NEW: Max 3 trades per day
input double   MaxDailyLossPercent   = 8.0;     // NEW: Stop trading after 8% daily loss
input bool     UseDailyLossLimit     = true;    // NEW: Enable daily loss protection

input group "=== Equity Protection ==="
input double   MinimumEquityStop     = 0.0;
input double   ActivationEquityGain  = 50000.0; // FIXED: Was ¥2,000,000 (unreachable)
input double   TrailingEquityPercent = 33.0;

input group "=== Structural Entry ==="
input ENUM_TIMEFRAMES ZoneTF        = PERIOD_H4;
input int      BodyStrengthMin      = 50;        // FIXED: Was 60 (missed valid zones)
input int      ZoneExpiryHours      = 48;        // FIXED: Was 24h (too short for 4H)
input double   ConfirmBodyMinPct    = 50.0;

//--- Global Variables
CTrade      trade;
string      prefix = "DEN_V5_";
int         slowMA_handle, rsi_handle;
double      startingEquity = 0, peakEquity = 0;
bool        equityTrailingActive = false, protectionHalt = false;
datetime    g_lastCloseTime = 0;
double      g_monthlyProfits[12];
int         g_lastLossDirection = 0;

//--- Stats tracking
int tradesWon=0, tradesLost=0, tradesBreakEven=0, tradeCount=0;
double totalProfit=0, weekProfit=0, monthProfit=0, yearProfit=0;

//--- NEW: Daily tracking
datetime    g_currentDay = 0;
int         g_tradesToday = 0;
double      g_dailyPNL = 0;
double      g_dailyStartingEquity = 0;

struct SZone {
   double priceHigh, priceLow;
   bool isValid;
   datetime createdTime;
};
SZone g_demandZones[1], g_supplyZones[1];

string g_proxText = "Scanning...";
color  g_proxColor = clrWhite;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   TesterHideIndicators(true);
   
   slowMA_handle = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsi_handle    = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   
   if(slowMA_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE) return INIT_FAILED;
   
   trade.SetExpertMagicNumber(MagicNumber);
   startingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   peakEquity     = startingEquity;
   g_dailyStartingEquity = startingEquity;
   
   EventSetTimer(1);
   RefreshStats();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, prefix);
   IndicatorRelease(slowMA_handle);
   IndicatorRelease(rsi_handle);
   ChartRedraw(0);
   Print("V5.0: Cleanup complete.");
}

//+------------------------------------------------------------------+
//| Main Logic Flow                                                  |
//+------------------------------------------------------------------+
void OnTick() {
   if(protectionHalt) return;
   
   // NEW: Daily reset logic
   ResetDailyCounters();
   
   if(PositionsTotal() > 0) {
      if(UseIntelligentTrail) ManageStructuralTrailing();
      ManagePartialTakeProfit();
      ManageActiveTrades();
   }
   
   UpdateEquityProtection();
   DetectZones();
   CheckZoneExpiry();
   CalculateProximity();
   CheckSignals();
   DrawZones();
}

//+------------------------------------------------------------------+
//| NEW: Daily Reset - Track trades per day and daily loss           |
//+------------------------------------------------------------------+
void ResetDailyCounters() {
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay != g_currentDay) {
      // New day - reset counters
      g_currentDay = currentDay;
      g_tradesToday = 0;
      g_dailyPNL = 0;
      g_dailyStartingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   
   // Update daily P&L based on floating equity
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyPNL = currentEquity - g_dailyStartingEquity;
   
   // Check daily loss limit
   if(UseDailyLossLimit && g_dailyStartingEquity > 0) {
      double dailyLossPct = (g_dailyPNL / g_dailyStartingEquity) * 100.0;
      if(dailyLossPct <= -MaxDailyLossPercent && !protectionHalt) {
         Print(StringFormat("!!! DAILY LOSS LIMIT HIT: %.1f%% (Limit: %.1f%%)", dailyLossPct, MaxDailyLossPercent));
         if(PositionsTotal() > 0) CloseAllPositions();
         protectionHalt = true;
         Alert(StringFormat("DAILY LOSS LIMIT REACHED: %.1f%%", dailyLossPct));
      }
   }
}

//+------------------------------------------------------------------+
//| Timer Function                                                   |
//+------------------------------------------------------------------+
void OnTimer() { 
   UpdateMyEADashboard(); 
}

//+------------------------------------------------------------------+
//| Refresh Stats                                                    |
//+------------------------------------------------------------------+
void RefreshStats() {
   if(!HistorySelect(0, TimeCurrent())) return;
   
   tradesWon = 0; tradesLost = 0; tradesBreakEven = 0; tradeCount = 0;
   totalProfit = 0; weekProfit = 0; monthProfit = 0; yearProfit = 0;
   ArrayFill(g_monthlyProfits, 0, 12, 0.0);
   g_lastCloseTime = 0; g_lastLossDirection = 0;
   
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + 
                     HistoryDealGetDouble(ticket, DEAL_COMMISSION) + 
                     HistoryDealGetDouble(ticket, DEAL_SWAP);
      datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      MqlDateTime ddt; TimeToStruct(dealTime, ddt);
      
      if(dealTime > g_lastCloseTime) g_lastCloseTime = dealTime;
      
      tradeCount++;
      totalProfit += profit;
      
      if(profit > 1.0) tradesWon++;
      else if(profit < -1.0) {
         tradesLost++;
         if(dealTime == g_lastCloseTime) {
            g_lastLossDirection = (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL) ? 1 : -1;
         }
      }
      else tradesBreakEven++;
      
      if(ddt.year == dt.year) {
         yearProfit += profit;
         if(ddt.mon >= 1 && ddt.mon <= 12) g_monthlyProfits[ddt.mon - 1] += profit;
         if(ddt.mon == dt.mon) monthProfit += profit;
         if(now - dealTime < 604800) weekProfit += profit;
      }
   }
   
   // NEW: Recount today's trades from history
   g_tradesToday = 0;
   for(int i = 0; i < totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      
      datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      MqlDateTime ddt; TimeToStruct(dealTime, ddt);
      MqlDateTime today; TimeToStruct(TimeCurrent(), today);
      
      if(ddt.day_of_year == today.day_of_year && ddt.year == today.year) {
         g_tradesToday++;
      }
   }
}

//+------------------------------------------------------------------+
//| Proximity Logic                                                  |
//+------------------------------------------------------------------+
void CalculateProximity() {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double ema[], rsi[];
   if(CopyBuffer(slowMA_handle, 0, 0, 1, ema) <= 0 || CopyBuffer(rsi_handle, 0, 0, 1, rsi) <= 0) return;

   g_proxText = "Scanning..."; g_proxColor = clrGray;

   if(g_demandZones[0].isValid) {
      double dist = bid - g_demandZones[0].priceHigh;
      double score = 100 - MathMin(100, MathMax(0, (dist/(bid*0.005))*100));
      g_proxText = DoubleToString(score, 1) + "% (Long Prox)"; 
      g_proxColor = clrLime;
   }
   if(g_supplyZones[0].isValid) {
      double dist = g_supplyZones[0].priceLow - ask;
      double score = 100 - MathMin(100, MathMax(0, (dist/(ask*0.005))*100));
      g_proxText = DoubleToString(score, 1) + "% (Short Prox)"; 
      g_proxColor = clrRed;
   }
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void UpdateMyEADashboard() {
   static datetime lastTime = 0;
   static int lastHistoryCount = -1;
   
   if(!ShowFullDashboard && ShowMonthlySummaryOnly) {
      if(!HistorySelect(0, TimeCurrent())) return;
      int currentHistoryCount = HistoryDealsTotal();
      if(currentHistoryCount == lastHistoryCount) return;
      lastHistoryCount = currentHistoryCount;
   } else {
      if(TimeCurrent() == lastTime) return;
      lastTime = TimeCurrent();
   }

   if(!ShowDashboard) {
      for(int i=ObjectsTotal(0, 0, OBJ_LABEL)-1; i>=0; i--) {
         string name = ObjectName(0, i, 0, OBJ_LABEL);
         if(StringFind(name, prefix) >= 0) ObjectDelete(0, name);
      }
      return;
   }

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floatingPL = currentEquity - AccountInfoDouble(ACCOUNT_BALANCE);
   string monthNames[] = {"","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   
   int xOffset = 20; 
   int yStart = 30;
   int spacing = 16;

   // V5.0 Optimized Dashboard
   CreateLabel("HDR", "DEN BTCJPY V5.0 Optimized", xOffset, yStart, 11, clrGold);
   CreateLabel("L1", StringFormat("Equity: ¥%.0f | FL: ¥%.0f", currentEquity, floatingPL), xOffset, yStart+spacing, 9, (floatingPL>=0?clrLime:clrRed));
   CreateLabel("L2", StringFormat("SL: %.1f%% | TP: %.1f%% | Trail: %.1f%%", StopLossPercent, TakeProfitPercent, TrailingStopPct), xOffset, yStart+spacing*2, 9, clrDeepSkyBlue);
   
   int yStats = yStart + spacing*4;
   CreateLabel("S1", StringFormat("Trades: %d | Today: %d/%d", tradeCount, g_tradesToday, MaxTradesPerDay), xOffset, yStats, 9, clrWhite);
   double winRate = (tradeCount > 0) ? (tradesWon * 100.0 / tradeCount) : 0;
   CreateLabel("S2", StringFormat("W:%d L:%d Win:%.1f%%", tradesWon, tradesLost, winRate), xOffset, yStats+spacing, 9, clrLime);
   CreateLabel("S3", StringFormat("Total: ¥%.0f | Wk: ¥%.0f", totalProfit, weekProfit), xOffset, yStats+spacing*2, 9, (totalProfit>=0?clrLime:clrRed));
   CreateLabel("S4", StringFormat("Daily P&L: ¥%.0f | Daily Loss: %.1f%%", g_dailyPNL, (g_dailyStartingEquity>0?(g_dailyPNL/g_dailyStartingEquity*100):0)), xOffset, yStats+spacing*3, 9, (g_dailyPNL>=0?clrLime:clrRed));
   
   // Status line
   int ySafe = yStats + spacing*6;
   CreateLabel("ST1", "Status: " + g_proxText, xOffset, ySafe, 9, g_proxColor);
   string tradeStatus = protectionHalt ? "HALTED" : "Active";
   CreateLabel("ST2", "Trading: " + tradeStatus, xOffset, ySafe+spacing, 9, (protectionHalt?clrRed:clrLime));
   CreateLabel("ST3", "Zones: " + (g_demandZones[0].isValid?"Demand ":"") + (g_supplyZones[0].isValid?"Supply":""), xOffset, ySafe+spacing*2, 9, clrGray);
}

//+------------------------------------------------------------------+
//| Signal Logic (IMPROVED)                                          |
//+------------------------------------------------------------------+
void CheckSignals() {
   if(PositionsTotal() > 0 || protectionHalt) return;
   
   // NEW: Daily trade limit check
   if(g_tradesToday >= MaxTradesPerDay) {
      g_proxText = StringFormat("Daily limit: %d/%d trades", g_tradesToday, MaxTradesPerDay);
      g_proxColor = clrOrange;
      return;
   }

   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(g_lastCloseTime >= currentBarTime) {
      g_proxText = "Cooldown: New Bar";
      g_proxColor = clrYellow;
      return;
   }

   bool allowLong  = (g_lastLossDirection != 1);
   bool allowShort = (g_lastLossDirection != -1);

   if(!allowLong)  { g_proxText = "Filter: SHORT only"; g_proxColor = clrOrange; }
   if(!allowShort) { g_proxText = "Filter: LONG only";  g_proxColor = clrOrange; }

   if(UseSpreadFilter) {
      int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(currentSpread > MaxSpread) {
         g_proxText = StringFormat("Spread: %d", currentSpread);
         g_proxColor = clrOrange;
         return;
      }
   }

   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 2, r) < 2) return;
   
   double b = MathAbs(r[1].close - r[1].open);
   double rg = r[1].high - r[1].low;
   double pct = (rg > 0) ? (b / rg) * 100 : 0;
   
   double rsi[], ema[]; 
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi) <= 0 || CopyBuffer(slowMA_handle, 0, 0, 1, ema) <= 0) return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Demand Zone Entry (Long) - IMPROVED entry logic
   if(allowLong && g_demandZones[0].isValid && bid <= g_demandZones[0].priceHigh && bid >= g_demandZones[0].priceLow) {
      if(bid > ema[0] && rsi[0] < RSIOverbought && r[1].close > r[1].open && pct >= ConfirmBodyMinPct) {
         if(trade.Buy(FixedLotSize, _Symbol, ask, ask * (1 - StopLossPercent / 100), ask * (1 + TakeProfitPercent / 100))) { 
            g_demandZones[0].isValid = false; 
            g_lastLossDirection = 0;
            g_tradesToday++; // NEW: Track daily trade
            RefreshStats(); 
         }
      }
   }

   // Supply Zone Entry (Short)
   if(allowShort && g_supplyZones[0].isValid && ask >= g_supplyZones[0].priceLow && ask <= g_supplyZones[0].priceHigh) {
      if(ask < ema[0] && rsi[0] > RSIOversold && r[1].close < r[1].open && pct >= ConfirmBodyMinPct) {
         if(trade.Sell(FixedLotSize, _Symbol, bid, bid * (1 + StopLossPercent / 100), bid * (1 - TakeProfitPercent / 100))) { 
            g_supplyZones[0].isValid = false; 
            g_lastLossDirection = 0;
            g_tradesToday++; // NEW: Track daily trade
            RefreshStats(); 
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Structural Trailing (IMPROVED: Better dynamic levels)            |
//+------------------------------------------------------------------+
void ManageStructuralTrailing() {
   if(!UseTrailing || !UseIntelligentTrail) return;
   ENUM_TIMEFRAMES srTF = PERIOD_H4;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double ent = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      long type  = PositionGetInteger(POSITION_TYPE);
      double prc = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double pPct = MathAbs(prc - ent) / ent * 100.0;

      // IMPROVED: Better dynamic lookback based on market structure
      int lookback = 20;
      if(pPct > 4.0) lookback = 10;     // Tighten at 4% profit (was 3%)
      if(pPct > 8.0) lookback = 5;       // Aggressive at 8% (was 7%)

      if(type == POSITION_TYPE_BUY) {
         int lowestBar = iLowest(_Symbol, srTF, MODE_LOW, lookback, 1);
         double supportLevel = iLow(_Symbol, srTF, lowestBar);
         double finalSL = NormalizeDouble(supportLevel - (300 * _Point), _Digits); // Tighter: 300pts instead of 500
         if(finalSL > sl || sl == 0) trade.PositionModify(ticket, finalSL, PositionGetDouble(POSITION_TP));
      } else {
         int highestBar = iHighest(_Symbol, srTF, MODE_HIGH, lookback, 1);
         double resistanceLevel = iHigh(_Symbol, srTF, highestBar);
         double finalSL = NormalizeDouble(resistanceLevel + (300 * _Point), _Digits);
         if(finalSL < sl || sl == 0) trade.PositionModify(ticket, finalSL, PositionGetDouble(POSITION_TP));
      }
   }
}

//+------------------------------------------------------------------+
//| Partial TP                                                       |
//+------------------------------------------------------------------+
void ManagePartialTakeProfit() {
   if(!UsePartialTP) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double initialLot = PositionGetDouble(POSITION_VOLUME);
         double ent = PositionGetDouble(POSITION_PRICE_OPEN);
         long type  = PositionGetInteger(POSITION_TYPE);
         double prc = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double pPct = MathAbs(prc - ent) / ent * 100.0;

         if(pPct >= PartialTP_TriggerPct && initialLot >= FixedLotSize) {
            double closeLot = NormalizeDouble(initialLot * (PartialClosePct / 100.0), 2);
            if(closeLot > 0 && trade.PositionClosePartial(t, closeLot)) {
               Print(StringFormat("V5: Partial TP - Closed %.2f lots at %.2f%%", closeLot, pPct));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Zone Detection                                                   |
//+------------------------------------------------------------------+
void DetectZones() {
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, ZoneTF, 0, 2, r) < 2) return;
   double b = MathAbs(r[1].close - r[1].open), rg = r[1].high - r[1].low;
   if(rg > 0 && (b/rg)*100 >= BodyStrengthMin) {
      if(r[1].close > r[1].open) { 
         g_demandZones[0].priceLow = r[1].low; g_demandZones[0].priceHigh = r[1].low + (rg*0.25);
         g_demandZones[0].isValid = true; g_demandZones[0].createdTime = TimeCurrent(); 
      } else { 
         g_supplyZones[0].priceLow = r[1].high - (rg*0.25); g_supplyZones[0].priceHigh = r[1].high;
         g_supplyZones[0].isValid = true; g_supplyZones[0].createdTime = TimeCurrent(); 
      }
   }
}

//+------------------------------------------------------------------+
//| Zone Expiry                                                      |
//+------------------------------------------------------------------+
void CheckZoneExpiry() {
   if(g_demandZones[0].isValid && (TimeCurrent() - g_demandZones[0].createdTime > ZoneExpiryHours*3600)) g_demandZones[0].isValid = false;
   if(g_supplyZones[0].isValid && (TimeCurrent() - g_supplyZones[0].createdTime > ZoneExpiryHours*3600)) g_supplyZones[0].isValid = false;
}

//+------------------------------------------------------------------+
//| Equity Protection                                                |
//+------------------------------------------------------------------+
void UpdateEquityProtection() {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > peakEquity) peakEquity = eq;
   
   if(!equityTrailingActive && (eq - startingEquity >= ActivationEquityGain)) {
      equityTrailingActive = true;
      Print(">>> V5: Equity Trailing Activated.");
   }

   double trailingLimit = peakEquity * (1 - TrailingEquityPercent/100);
   bool hardFloorHit = (eq < MinimumEquityStop);
   bool trailingHit  = (equityTrailingActive && eq < trailingLimit);

   if((hardFloorHit || trailingHit) && !protectionHalt) { 
      string reason = hardFloorHit ? "HARD FLOOR" : "EQUITY TRAIL HIT";
      Print(StringFormat("!!! SAFETY HALT: %s at ¥%.0f", reason, eq));
      if(PositionsTotal() > 0) CloseAllPositions();
      protectionHalt = true;
   }
}

//+------------------------------------------------------------------+
//| Trade Management                                                 |
//+------------------------------------------------------------------+
void ManageActiveTrades() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double ent = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl  = PositionGetDouble(POSITION_SL);
         double tp  = PositionGetDouble(POSITION_TP);
         long type  = PositionGetInteger(POSITION_TYPE);
         double prc = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double pPct = MathAbs(prc - ent) / ent * 100.0;

         // Break-Even
         if(UseBreakEven && pPct >= BE_TriggerPct) {
            double be = (type == POSITION_TYPE_BUY) ? ent * (1 + BE_BufferPct/100) : ent * (1 - BE_BufferPct/100);
            if((type == POSITION_TYPE_BUY && sl < be) || (type == POSITION_TYPE_SELL && (sl > be || sl == 0))) {
               if(trade.PositionModify(t, NormalizeDouble(be, _Digits), tp))
                  Print(StringFormat("V5: Break-even set at +%.2f%%", BE_BufferPct));
            }
         }

         // Original Trail (only if IntelligentTrail is OFF)
         if(UseTrailing && !UseIntelligentTrail) {
            double distance = prc * (TrailingStopPct / 100.0);
            double newSL = (type == POSITION_TYPE_BUY) ? prc - distance : prc + distance;
            if((type == POSITION_TYPE_BUY && newSL > sl) || (type == POSITION_TYPE_SELL && (newSL < sl || sl == 0))) {
               trade.PositionModify(t, NormalizeDouble(newSL, _Digits), tp);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Visual Zones                                                     |
//+------------------------------------------------------------------+
void DrawZones() {
   string demName = prefix + "Demand";
   if(g_demandZones[0].isValid) {
      if(ObjectFind(0, demName) < 0) {
         ObjectCreate(0, demName, OBJ_RECTANGLE, 0, g_demandZones[0].createdTime, g_demandZones[0].priceHigh, TimeCurrent() + (ZoneExpiryHours * 3600 * 16), g_demandZones[0].priceLow);
         ObjectSetInteger(0, demName, OBJPROP_COLOR, C'35,70,35');
         ObjectSetInteger(0, demName, OBJPROP_FILL, true);
         ObjectSetInteger(0, demName, OBJPROP_BACK, true);
         ObjectSetInteger(0, demName, OBJPROP_SELECTABLE, false);
      }
   } else ObjectDelete(0, demName);

   string supName = prefix + "Supply";
   if(g_supplyZones[0].isValid) {
      if(ObjectFind(0, supName) < 0) {
         ObjectCreate(0, supName, OBJ_RECTANGLE, 0, g_supplyZones[0].createdTime, g_supplyZones[0].priceLow, TimeCurrent() + (ZoneExpiryHours * 3600 * 16), g_supplyZones[0].priceHigh);
         ObjectSetInteger(0, supName, OBJPROP_COLOR, C'70,35,35');
         ObjectSetInteger(0, supName, OBJPROP_FILL, true);
         ObjectSetInteger(0, supName, OBJPROP_BACK, true);
         ObjectSetInteger(0, supName, OBJPROP_SELECTABLE, false);
      }
   } else ObjectDelete(0, supName);
}

//+------------------------------------------------------------------+
//| UI Helper                                                        |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, int size, color clr) {
   string obj = prefix + name;
   if(ObjectFind(0, obj) < 0) { 
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0); 
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   }
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
   ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, obj, OBJPROP_FONT, "Lucida Console");
}

void CloseAllPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) trade.PositionClose(t);
   }
   RefreshStats();
}
