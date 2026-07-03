//+------------------------------------------------------------------+
//|                                   BTCJPY_Hybrid_Pro_V5_1.mq5     |
//|      Market-Tuned: High Volatility Bear Market Settings          |
//|      Optimized for BTCJPY Jul 2026 conditions                    |
//+------------------------------------------------------------------+
//
// MARKET CONDITIONS (July 2026):
//   Price: ¥10,013,683 | 90d range: ¥9.4M-¥13.0M (38.1%)
//   Daily EMA200: ¥11,006,428 (-9% below = BEARISH long-term)
//   Hourly EMA50 > EMA200 (short-term BULLISH bounce)
//   14d ATR: ¥345,914 (3.45%) | 20d volatility: 14.7%
//   Support: ¥9,393,627 | Resistance: ¥10,774,523
//
// V5.1 CHANGES vs V5.0:
//   1. SL 5% → 7%     (ATR 3.45% × 2 = 7% needed to survive noise)
//   2. TP 10% → 8%    (Bear market: take profits faster)
//   3. Trail 3% → 4%  (Wider trail to avoid shakeouts)
//   4. RSI OB 58.5 → 65 (Short-term bounce allows higher RSI)
//   5. BE trigger 2% → 3% (Higher bar in volatile conditions)
//   6. Partial TP trigger 5% → 4% (Bank profits earlier)
//   7. Partial close 30% → 40% (Take more off in downtrend)
//   8. Daily loss 8% → 6% (Tighter risk in volatile market)
//   9. Zone expiry 48h → 36h (Faster in fast-moving market)
//  10. Max trades/day 3 → 2 (Conservative in high volatility)
//+------------------------------------------------------------------+
#property copyright "DEN Trading - BTCJPY Hybrid Edition V5.1"
#property version   "5.10"
#property strict

#include <Trade\Trade.mqh>

input group "=== Core Settings ==="
input long     MagicNumber = 987114;
input int      SlowMAPeriod = 579;
input bool     ShowDashboard = true;
input bool     ShowFullDashboard = true;
input bool     ShowMonthlySummaryOnly = false;

input group "=== RSI Filter (Market-Tuned) ==="
input bool     UseRSIFilter    = true;
input int      RSIPeriod       = 105;
input double   RSIOverbought   = 65.0;    // V5.1: Was 58.5 (too strict for current bounce)
input double   RSIOversold     = 25.0;

input group "=== Spread Filter ==="
input bool     UseSpreadFilter = false;
input int      MaxSpread       = 15000;

input group "=== Risk Management (High-Volatility Tuned) ==="
input double   FixedLotSize     = 0.01;
input double   StopLossPercent  = 7.0;    // V5.1: Was 5.0% (ATR=3.45% needs 2× buffer)
input double   TakeProfitPercent = 8.0;   // V5.1: Was 10% (bear market: take profit sooner)

input group "=== Trailing & Break-even (Volatility-Adjusted) ==="
input bool     UseTrailing           = true;
input bool     UseIntelligentTrail   = true;
input double   TrailingStopPct       = 4.0;    // V5.1: Was 3.0% (avoid shakeout)
input bool     UseBreakEven          = true;
input double   BE_TriggerPct         = 3.0;    // V5.1: Was 2.0% (higher bar for BE)
input double   BE_BufferPct          = 0.5;

input group "=== Partial Take Profit (BEAR MARKET MODE) ==="
input bool     UsePartialTP          = true;
input double   PartialTP_TriggerPct  = 4.0;    // V5.1: Was 5.0% (bank profits earlier)
input double   PartialClosePct       = 40.0;   // V5.1: Was 30% (take more off table)

input group "=== Daily Risk Limits (Tightened) ==="
input int      MaxTradesPerDay       = 2;      // V5.1: Was 3 (fewer trades in high volatility)
input double   MaxDailyLossPercent   = 6.0;    // V5.1: Was 8% (tighter in volatile market)
input bool     UseDailyLossLimit     = true;

input group "=== Equity Protection ==="
input double   MinimumEquityStop     = 0.0;
input double   ActivationEquityGain  = 30000.0;
input double   TrailingEquityPercent = 33.0;

input group "=== Structural Entry (Faster Cycle) ==="
input ENUM_TIMEFRAMES ZoneTF        = PERIOD_H4;
input int      BodyStrengthMin      = 50;
input int      ZoneExpiryHours      = 36;     // V5.1: Was 48h (faster market)
input double   ConfirmBodyMinPct    = 50.0;

//--- Global Variables
CTrade      trade;
string      prefix = "DEN_V51_";
int         slowMA_handle, rsi_handle;
double      startingEquity = 0, peakEquity = 0;
bool        equityTrailingActive = false, protectionHalt = false;
datetime    g_lastCloseTime = 0;
double      g_monthlyProfits[12];
int         g_lastLossDirection = 0;

int tradesWon=0, tradesLost=0, tradesBreakEven=0, tradeCount=0;
double totalProfit=0, weekProfit=0, monthProfit=0, yearProfit=0;

datetime    g_currentDay = 0;
int         g_tradesToday = 0;
double      g_dailyPNL = 0;
double      g_dailyStartingEquity = 0;

struct SZone { double priceHigh, priceLow; bool isValid; datetime createdTime; };
SZone g_demandZones[1], g_supplyZones[1];

string g_proxText = "Scanning...";
color  g_proxColor = clrWhite;

int OnInit() {
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   TesterHideIndicators(true);
   slowMA_handle = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsi_handle    = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   if(slowMA_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(MagicNumber);
   startingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   peakEquity = startingEquity;
   g_dailyStartingEquity = startingEquity;
   EventSetTimer(1);
   RefreshStats();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, prefix);
   IndicatorRelease(slowMA_handle);
   IndicatorRelease(rsi_handle);
   ChartRedraw(0);
   Print("V5.1: Cleanup complete.");
}

void OnTick() {
   if(protectionHalt) return;
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

void ResetDailyCounters() {
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay != g_currentDay) {
      g_currentDay = currentDay;
      g_tradesToday = 0;
      g_dailyPNL = 0;
      g_dailyStartingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyPNL = currentEquity - g_dailyStartingEquity;
   if(UseDailyLossLimit && g_dailyStartingEquity > 0) {
      double dailyLossPct = (g_dailyPNL / g_dailyStartingEquity) * 100.0;
      if(dailyLossPct <= -MaxDailyLossPercent && !protectionHalt) {
         Print(StringFormat("V5.1: Daily loss limit hit: %.1f%%", dailyLossPct));
         if(PositionsTotal() > 0) CloseAllPositions();
         protectionHalt = true;
         Alert(StringFormat("DAILY LOSS LIMIT: %.1f%%", dailyLossPct));
      }
   }
}

void OnTimer() { UpdateMyEADashboard(); }

void RefreshStats() {
   if(!HistorySelect(0, TimeCurrent())) return;
   tradesWon=0; tradesLost=0; tradesBreakEven=0; tradeCount=0;
   totalProfit=0; weekProfit=0; monthProfit=0; yearProfit=0;
   ArrayFill(g_monthlyProfits,0,12,0.0);
   g_lastCloseTime=0; g_lastLossDirection=0;
   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now,dt);
   int totalDeals=HistoryDealsTotal();
   for(int i=0;i<totalDeals;i++) {
      ulong ticket=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double profit=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_SWAP);
      datetime dealTime=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      MqlDateTime ddt; TimeToStruct(dealTime,ddt);
      if(dealTime>g_lastCloseTime) g_lastCloseTime=dealTime;
      tradeCount++; totalProfit+=profit;
      if(profit>1.0) tradesWon++;
      else if(profit<-1.0) { tradesLost++; if(dealTime==g_lastCloseTime) g_lastLossDirection=(HistoryDealGetInteger(ticket,DEAL_TYPE)==DEAL_TYPE_SELL)?1:-1; }
      else tradesBreakEven++;
      if(ddt.year==dt.year) { yearProfit+=profit; if(ddt.mon>=1&&ddt.mon<=12) g_monthlyProfits[ddt.mon-1]+=profit; if(ddt.mon==dt.mon) monthProfit+=profit; if(now-dealTime<604800) weekProfit+=profit; }
   }
   g_tradesToday=0;
   for(int i=0;i<totalDeals;i++) {
      ulong ticket=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      datetime dealTime=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      MqlDateTime ddt; TimeToStruct(dealTime,ddt);
      MqlDateTime today; TimeToStruct(TimeCurrent(),today);
      if(ddt.day_of_year==today.day_of_year&&ddt.year==today.year) g_tradesToday++;
   }
}

void CalculateProximity() {
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double ema[],rsi[];
   if(CopyBuffer(slowMA_handle,0,0,1,ema)<=0||CopyBuffer(rsi_handle,0,0,1,rsi)<=0) return;
   g_proxText="Scanning..."; g_proxColor=clrGray;
   if(g_demandZones[0].isValid) {
      double dist=bid-g_demandZones[0].priceHigh;
      double score=100-MathMin(100,MathMax(0,(dist/(bid*0.005))*100));
      g_proxText=DoubleToString(score,1)+"% (Long Prox)"; g_proxColor=clrLime;
   }
   if(g_supplyZones[0].isValid) {
      double dist=g_supplyZones[0].priceLow-ask;
      double score=100-MathMin(100,MathMax(0,(dist/(ask*0.005))*100));
      g_proxText=DoubleToString(score,1)+"% (Short Prox)"; g_proxColor=clrRed;
   }
}

void UpdateMyEADashboard() {
   static datetime lastTime=0;
   static int lastHistoryCount=-1;
   if(!ShowFullDashboard&&ShowMonthlySummaryOnly) {
      if(!HistorySelect(0,TimeCurrent())) return;
      int currentHistoryCount=HistoryDealsTotal();
      if(currentHistoryCount==lastHistoryCount) return;
      lastHistoryCount=currentHistoryCount;
   } else { if(TimeCurrent()==lastTime) return; lastTime=TimeCurrent(); }
   if(!ShowDashboard) {
      for(int i=ObjectsTotal(0,0,OBJ_LABEL)-1;i>=0;i--) { string name=ObjectName(0,i,0,OBJ_LABEL); if(StringFind(name,prefix)>=0) ObjectDelete(0,name); }
      return;
   }
   double currentEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   double floatingPL=currentEquity-AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int xOffset=20, yStart=30, spacing=16;
   CreateLabel("HDR","DEN BTCJPY V5.1 Market-Tuned",xOffset,yStart,11,clrGold);
   CreateLabel("L1",StringFormat("Equity: %.0f | FL: %.0f",currentEquity,floatingPL),xOffset,yStart+spacing,9,(floatingPL>=0?clrLime:clrRed));
   CreateLabel("L2",StringFormat("SL:%.1f%% TP:%.1f%% Trail:%.1f%%",StopLossPercent,TakeProfitPercent,TrailingStopPct),xOffset,yStart+spacing*2,9,clrDeepSkyBlue);
   int yStats=yStart+spacing*4;
   CreateLabel("S1",StringFormat("Trades:%d Today:%d/%d",tradeCount,g_tradesToday,MaxTradesPerDay),xOffset,yStats,9,clrWhite);
   double winRate=(tradeCount>0)?(tradesWon*100.0/tradeCount):0;
   CreateLabel("S2",StringFormat("W:%d L:%d WR:%.1f%%",tradesWon,tradesLost,winRate),xOffset,yStats+spacing,9,clrLime);
   CreateLabel("S3",StringFormat("Tot:%.0f Wk:%.0f",totalProfit,weekProfit),xOffset,yStats+spacing*2,9,(totalProfit>=0?clrLime:clrRed));
   CreateLabel("ST1","Status: "+g_proxText,xOffset,yStats+spacing*4,9,g_proxColor);
   CreateLabel("ST2","Trading: "+(protectionHalt?"HALTED":"Active"),xOffset,yStats+spacing*5,9,(protectionHalt?clrRed:clrLime));
}

void CheckSignals() {
   if(PositionsTotal()>0||protectionHalt) return;
   if(g_tradesToday>=MaxTradesPerDay) { g_proxText=StringFormat("Daily limit %d/%d",g_tradesToday,MaxTradesPerDay); g_proxColor=clrOrange; return; }
   datetime currentBarTime=iTime(_Symbol,PERIOD_CURRENT,0);
   if(g_lastCloseTime>=currentBarTime) { g_proxText="Cooldown: New Bar"; g_proxColor=clrYellow; return; }
   bool allowLong=(g_lastLossDirection!=1), allowShort=(g_lastLossDirection!=-1);
   if(!allowLong) { g_proxText="Filter: SHORT only"; g_proxColor=clrOrange; }
   if(!allowShort) { g_proxText="Filter: LONG only"; g_proxColor=clrOrange; }
   if(UseSpreadFilter) { int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD); if(cs>MaxSpread) { g_proxText=StringFormat("Spread:%d",cs); g_proxColor=clrOrange; return; } }
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_CURRENT,0,2,r)<2) return;
   double b=MathAbs(r[1].close-r[1].open), rg=r[1].high-r[1].low, pct=(rg>0)?(b/rg)*100:0;
   double rsi[],ema[];
   if(CopyBuffer(rsi_handle,0,0,1,rsi)<=0||CopyBuffer(slowMA_handle,0,0,1,ema)<=0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   // Long: Demand Zone + Above EMA + RSI < OB + Bullish candle
   if(allowLong&&g_demandZones[0].isValid&&bid<=g_demandZones[0].priceHigh&&bid>=g_demandZones[0].priceLow) {
      if(bid>ema[0]&&rsi[0]<RSIOverbought&&r[1].close>r[1].open&&pct>=ConfirmBodyMinPct) {
         if(trade.Buy(FixedLotSize,_Symbol,ask,ask*(1-StopLossPercent/100),ask*(1+TakeProfitPercent/100))) {
            g_demandZones[0].isValid=false; g_lastLossDirection=0; g_tradesToday++; RefreshStats();
         }
      }
   }
   // Short: Supply Zone + Below EMA + RSI > OS + Bearish candle
   if(allowShort&&g_supplyZones[0].isValid&&ask>=g_supplyZones[0].priceLow&&ask<=g_supplyZones[0].priceHigh) {
      if(ask<ema[0]&&rsi[0]>RSIOversold&&r[1].close<r[1].open&&pct>=ConfirmBodyMinPct) {
         if(trade.Sell(FixedLotSize,_Symbol,bid,bid*(1+StopLossPercent/100),bid*(1-TakeProfitPercent/100))) {
            g_supplyZones[0].isValid=false; g_lastLossDirection=0; g_tradesToday++; RefreshStats();
         }
      }
   }
}

void ManageStructuralTrailing() {
   if(!UseTrailing||!UseIntelligentTrail) return;
   ENUM_TIMEFRAMES srTF=PERIOD_H4;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double ent=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL);
      long type=PositionGetInteger(POSITION_TYPE);
      double prc=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double pPct=MathAbs(prc-ent)/ent*100.0;
      int lookback=20;
      if(pPct>5.0) lookback=10;  // V5.1: Tighten at 5% (was 4%)
      if(pPct>9.0) lookback=5;   // V5.1: Aggressive at 9% (was 8%)
      if(type==POSITION_TYPE_BUY) {
         int lb=iLowest(_Symbol,srTF,MODE_LOW,lookback,1);
         double sl2=NormalizeDouble(iLow(_Symbol,srTF,lb)-(300*_Point),_Digits);
         if(sl2>sl||sl==0) trade.PositionModify(ticket,sl2,PositionGetDouble(POSITION_TP));
      } else {
         int hb=iHighest(_Symbol,srTF,MODE_HIGH,lookback,1);
         double sl2=NormalizeDouble(iHigh(_Symbol,srTF,hb)+(300*_Point),_Digits);
         if(sl2<sl||sl==0) trade.PositionModify(ticket,sl2,PositionGetDouble(POSITION_TP));
      }
   }
}

void ManagePartialTakeProfit() {
   if(!UsePartialTP) return;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) {
         double il=PositionGetDouble(POSITION_VOLUME), ent=PositionGetDouble(POSITION_PRICE_OPEN);
         long tp=PositionGetInteger(POSITION_TYPE);
         double prc=(tp==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double pPct=MathAbs(prc-ent)/ent*100.0;
         if(pPct>=PartialTP_TriggerPct&&il>=FixedLotSize) {
            double cl=NormalizeDouble(il*(PartialClosePct/100.0),2);
            if(cl>0&&trade.PositionClosePartial(t,cl)) Print(StringFormat("V5.1: Partial TP at %.2f%%",pPct));
         }
      }
   }
}

void DetectZones() {
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,ZoneTF,0,2,r)<2) return;
   double b=MathAbs(r[1].close-r[1].open),rg=r[1].high-r[1].low;
   if(rg>0&&(b/rg)*100>=BodyStrengthMin) {
      if(r[1].close>r[1].open) {
         g_demandZones[0].priceLow=r[1].low; g_demandZones[0].priceHigh=r[1].low+(rg*0.25);
         g_demandZones[0].isValid=true; g_demandZones[0].createdTime=TimeCurrent();
      } else {
         g_supplyZones[0].priceLow=r[1].high-(rg*0.25); g_supplyZones[0].priceHigh=r[1].high;
         g_supplyZones[0].isValid=true; g_supplyZones[0].createdTime=TimeCurrent();
      }
   }
}

void CheckZoneExpiry() {
   if(g_demandZones[0].isValid&&(TimeCurrent()-g_demandZones[0].createdTime>ZoneExpiryHours*3600)) g_demandZones[0].isValid=false;
   if(g_supplyZones[0].isValid&&(TimeCurrent()-g_supplyZones[0].createdTime>ZoneExpiryHours*3600)) g_supplyZones[0].isValid=false;
}

void UpdateEquityProtection() {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>peakEquity) peakEquity=eq;
   if(!equityTrailingActive&&(eq-startingEquity>=ActivationEquityGain)) { equityTrailingActive=true; Print(">>> V5.1: Equity Trailing Activated"); }
   double tl=peakEquity*(1-TrailingEquityPercent/100);
   bool hf=(eq<MinimumEquityStop), tr=(equityTrailingActive&&eq<tl);
   if((hf||tr)&&!protectionHalt) {
      Print(StringFormat("V5.1 SAFETY HALT at %.0f",eq));
      if(PositionsTotal()>0) CloseAllPositions();
      protectionHalt=true;
   }
}

void ManageActiveTrades() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) {
         double ent=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
         long type=PositionGetInteger(POSITION_TYPE);
         double prc=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double pPct=MathAbs(prc-ent)/ent*100.0;
         if(UseBreakEven&&pPct>=BE_TriggerPct) {
            double be=(type==POSITION_TYPE_BUY)?ent*(1+BE_BufferPct/100):ent*(1-BE_BufferPct/100);
            if((type==POSITION_TYPE_BUY&&sl<be)||(type==POSITION_TYPE_SELL&&(sl>be||sl==0)))
               trade.PositionModify(t,NormalizeDouble(be,_Digits),tp);
         }
         if(UseTrailing&&!UseIntelligentTrail) {
            double dist=prc*(TrailingStopPct/100.0);
            double nsl=(type==POSITION_TYPE_BUY)?prc-dist:prc+dist;
            if((type==POSITION_TYPE_BUY&&nsl>sl)||(type==POSITION_TYPE_SELL&&(nsl<sl||sl==0)))
               trade.PositionModify(t,NormalizeDouble(nsl,_Digits),tp);
         }
      }
   }
}

void DrawZones() {
   string dn=prefix+"Demand";
   if(g_demandZones[0].isValid) {
      if(ObjectFind(0,dn)<0) {
         ObjectCreate(0,dn,OBJ_RECTANGLE,0,g_demandZones[0].createdTime,g_demandZones[0].priceHigh,TimeCurrent()+(ZoneExpiryHours*3600*16),g_demandZones[0].priceLow);
         ObjectSetInteger(0,dn,OBJPROP_COLOR,C'35,70,35'); ObjectSetInteger(0,dn,OBJPROP_FILL,true);
         ObjectSetInteger(0,dn,OBJPROP_BACK,true); ObjectSetInteger(0,dn,OBJPROP_SELECTABLE,false);
      }
   } else ObjectDelete(0,dn);
   string sn=prefix+"Supply";
   if(g_supplyZones[0].isValid) {
      if(ObjectFind(0,sn)<0) {
         ObjectCreate(0,sn,OBJ_RECTANGLE,0,g_supplyZones[0].createdTime,g_supplyZones[0].priceLow,TimeCurrent()+(ZoneExpiryHours*3600*16),g_supplyZones[0].priceHigh);
         ObjectSetInteger(0,sn,OBJPROP_COLOR,C'70,35,35'); ObjectSetInteger(0,sn,OBJPROP_FILL,true);
         ObjectSetInteger(0,sn,OBJPROP_BACK,true); ObjectSetInteger(0,sn,OBJPROP_SELECTABLE,false);
      }
   } else ObjectDelete(0,sn);
}

void CreateLabel(string name,string text,int x,int y,int size,color clr) {
   string obj=prefix+name;
   if(ObjectFind(0,obj)<0) { ObjectCreate(0,obj,OBJ_LABEL,0,0,0); ObjectSetInteger(0,obj,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,obj,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER); }
   ObjectSetString(0,obj,OBJPROP_TEXT,text); ObjectSetInteger(0,obj,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,obj,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,obj,OBJPROP_COLOR,clr); ObjectSetInteger(0,obj,OBJPROP_FONTSIZE,size); ObjectSetString(0,obj,OBJPROP_FONT,"Lucida Console");
}

void CloseAllPositions() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) trade.PositionClose(t);
   }
   RefreshStats();
}
