//+------------------------------------------------------------------+
//|                                   BTCJPY_Hybrid_Pro_V5_2.mq5     |
//|      V5.1 + Break of Structure (BoS) confirmation from LowDD     |
//|      V5.2a: Data-driven params from full-year BTCJPY analysis    |
//|      Year range: 102.1% | Avg monthly range: 20.4% | DD: 49.3%  |
//|      SL=6.5% (30% mo range) | TP=10% (50% mo range) | Trail=3.5% |
//+------------------------------------------------------------------+
#property copyright "DEN Trading - BTCJPY Hybrid Edition V5.2a"
#property version   "5.21"
#property strict

#include <Trade\Trade.mqh>

input group "=== Core Settings ==="
input long     MagicNumber = 987115;
input int      SlowMAPeriod = 579;
input bool     ShowDashboard = true;
input bool     ShowFullDashboard = true;
input bool     ShowMonthlySummaryOnly = false;

input group "=== RSI Filter ==="
input bool     UseRSIFilter    = true;
input int      RSIPeriod       = 105;
input double   RSIOverbought   = 65.0;
input double   RSIOversold     = 25.0;

input group "=== Break of Structure (BoS) Confirmation - NEW ==="
input bool     UseLTFConfirmation = true;     // Enable 15M BoS confirmation
input ENUM_TIMEFRAMES  LTF          = PERIOD_M15; // Lower timeframe for structure break
input int              BoSLookback  = 5;         // Candles to check for structure break

input group "=== Spread Filter ==="
input bool     UseSpreadFilter = false;
input int      MaxSpread       = 15000;

input group "=== Risk Management ==="
input double   FixedLotSize     = 0.01;
input double   StopLossPercent  = 6.5;    // 30% of avg monthly range (20.4%)
input double   TakeProfitPercent = 10.0;   // 50% of avg monthly range (20.4%)

input group "=== Trailing & Break-even ==="
input bool     UseTrailing           = true;
input bool     UseIntelligentTrail   = true;
input double   TrailingStopPct       = 3.5;    // 15% of avg monthly range
input bool     UseBreakEven          = true;
input double   BE_TriggerPct         = 3.0;
input double   BE_BufferPct          = 0.5;

input group "=== Partial Take Profit ==="
input bool     UsePartialTP          = true;
input double   PartialTP_TriggerPct  = 4.0;
input double   PartialClosePct       = 40.0;

input group "=== Daily Risk Limits ==="
input int      MaxTradesPerDay       = 2;
input double   MaxDailyLossPercent   = 5.0;    // Tighter: 49% max DD market
input bool     UseDailyLossLimit     = true;

input group "=== Equity Protection ==="
input double   MinimumEquityStop     = 0.0;
input double   ActivationEquityGain  = 30000.0;
input double   TrailingEquityPercent = 33.0;

input group "=== Structural Entry ==="
input ENUM_TIMEFRAMES ZoneTF        = PERIOD_H4;
input int      BodyStrengthMin      = 50;
input int      ZoneExpiryHours      = 36;
input double   ConfirmBodyMinPct    = 50.0;

//--- Global Variables
CTrade      trade;
string      prefix = "DEN_V52_";
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

//--- V5.2: BoS tracking
bool g_htfZoneTouched = false;

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
   IndicatorRelease(slowMA_handle); IndicatorRelease(rsi_handle);
   ChartRedraw(0);
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

//──────────────────────────────────────────────────────────
// V5.2: Break of Structure Confirmation (from LowDDWithBoS)
//──────────────────────────────────────────────────────────
bool CheckLTFBreakOfStructure(int direction) {
   // direction: 1 for Long (Break of Resistance), -1 for Short (Break of Support)
   if(direction == 1) {
      int highBar = iHighest(_Symbol, LTF, MODE_HIGH, BoSLookback, 1);
      double resistance = iHigh(_Symbol, LTF, highBar);
      if(SymbolInfoDouble(_Symbol, SYMBOL_BID) > resistance) return true;
   } else if(direction == -1) {
      int lowBar = iLowest(_Symbol, LTF, MODE_LOW, BoSLookback, 1);
      double support = iLow(_Symbol, LTF, lowBar);
      if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) < support) return true;
   }
   return false;
}

//──────────────────────────────────────────────────────────
void ResetDailyCounters() {
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay != g_currentDay) {
      g_currentDay = currentDay; g_tradesToday = 0; g_dailyPNL = 0;
      g_dailyStartingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyPNL = currentEquity - g_dailyStartingEquity;
   if(UseDailyLossLimit && g_dailyStartingEquity > 0) {
      double dailyLossPct = (g_dailyPNL / g_dailyStartingEquity) * 100.0;
      if(dailyLossPct <= -MaxDailyLossPercent && !protectionHalt) {
         Print(StringFormat("V5.2: Daily loss limit hit: %.1f%%", dailyLossPct));
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
   datetime now=TimeCurrent(); MqlDateTime dt; TimeToStruct(now,dt);
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
      MqlDateTime ddt; TimeToStruct(dealTime,ddt); MqlDateTime today; TimeToStruct(TimeCurrent(),today);
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
      g_proxText=DoubleToString(score,1)+"% (Long)"; g_proxColor=clrLime;
   }
   if(g_supplyZones[0].isValid) {
      double dist=g_supplyZones[0].priceLow-ask;
      double score=100-MathMin(100,MathMax(0,(dist/(ask*0.005))*100));
      g_proxText=DoubleToString(score,1)+"% (Short)"; g_proxColor=clrRed;
   }
}

void UpdateMyEADashboard() {
   static datetime lastTime=0; static int lastHistoryCount=-1;
   if(!ShowFullDashboard&&ShowMonthlySummaryOnly) {
      if(!HistorySelect(0,TimeCurrent())) return;
      int ch=HistoryDealsTotal(); if(ch==lastHistoryCount) return; lastHistoryCount=ch;
   } else { if(TimeCurrent()==lastTime) return; lastTime=TimeCurrent(); }
   if(!ShowDashboard) {
      for(int i=ObjectsTotal(0,0,OBJ_LABEL)-1;i>=0;i--) { string n=ObjectName(0,i,0,OBJ_LABEL); if(StringFind(n,prefix)>=0) ObjectDelete(0,n); }
      return;
   }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY); double fl=eq-AccountInfoDouble(ACCOUNT_BALANCE);
   int x=20,y=30,s=16;
   CreateLabel("H","DEN V5.2 BoS Optimized",x,y,11,clrGold);
   CreateLabel("L1",StringFormat("Eq:%.0f FL:%.0f",eq,fl),x,y+s,9,(fl>=0?clrLime:clrRed));
   CreateLabel("L2",StringFormat("SL:%.1f TP:%.1f Tr:%.1f BoS:%s",StopLossPercent,TakeProfitPercent,TrailingStopPct,(UseLTFConfirmation?"ON":"OFF")),x,y+s*2,9,clrDeepSkyBlue);
   int ys=y+s*4;
   CreateLabel("S1",StringFormat("T:%d D:%d/%d",tradeCount,g_tradesToday,MaxTradesPerDay),x,ys,9,clrWhite);
   double wr=(tradeCount>0)?(tradesWon*100.0/tradeCount):0;
   CreateLabel("S2",StringFormat("W:%d L:%d WR:%.0f%%",tradesWon,tradesLost,wr),x,ys+s,9,clrLime);
   CreateLabel("S3",StringFormat("PnL:%.0f Wk:%.0f",totalProfit,weekProfit),x,ys+s*2,9,(totalProfit>=0?clrLime:clrRed));
   CreateLabel("ST","St:"+g_proxText,x,ys+s*4,9,g_proxColor);
   string bs=g_htfZoneTouched?"ZoneTouched":"Waiting";
   CreateLabel("BS","BoS:"+bs,x,ys+s*5,9,(g_htfZoneTouched?clrLime:clrGray));
   CreateLabel("HA","Tr:"+(protectionHalt?"HALTED":"OK"),x,ys+s*6,9,(protectionHalt?clrRed:clrLime));
}

//──────────────────────────────────────────────────────────
// CheckSignals — V5.2 with BoS confirmation support
//──────────────────────────────────────────────────────────
void CheckSignals() {
   if(PositionsTotal()>0||protectionHalt) return;
   if(g_tradesToday>=MaxTradesPerDay) { g_proxText=StringFormat("Daily %d/%d",g_tradesToday,MaxTradesPerDay); g_proxColor=clrOrange; return; }
   datetime cbt=iTime(_Symbol,PERIOD_CURRENT,0);
   if(g_lastCloseTime>=cbt) { g_proxText="Cooldown"; g_proxColor=clrYellow; return; }
   bool allowLong=(g_lastLossDirection!=1),allowShort=(g_lastLossDirection!=-1);
   if(!allowLong) { g_proxText="Filter:SHORT"; g_proxColor=clrOrange; }
   if(!allowShort) { g_proxText="Filter:LONG"; g_proxColor=clrOrange; }
   if(UseSpreadFilter) { int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD); if(cs>MaxSpread) { g_proxText=StringFormat("Spr:%d",cs); g_proxColor=clrOrange; return; } }
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double rsi[],ema[];
   if(CopyBuffer(rsi_handle,0,0,1,rsi)<=0||CopyBuffer(slowMA_handle,0,0,1,ema)<=0) return;
   bool inDemand=(g_demandZones[0].isValid&&bid<=g_demandZones[0].priceHigh&&bid>=g_demandZones[0].priceLow);
   bool inSupply=(g_supplyZones[0].isValid&&ask>=g_supplyZones[0].priceLow&&ask<=g_supplyZones[0].priceHigh);
   if(inDemand||inSupply) g_htfZoneTouched=true;

   // ── OPTION A: BoS Confirmation (4H zone + 15M structure break)
   if(UseLTFConfirmation&&g_htfZoneTouched) {
      if(allowLong&&inDemand&&CheckLTFBreakOfStructure(1)) {
         if(trade.Buy(FixedLotSize,_Symbol,ask,ask*(1-StopLossPercent/100),ask*(1+TakeProfitPercent/100))) {
            g_htfZoneTouched=false; g_demandZones[0].isValid=false; g_lastLossDirection=0; g_tradesToday++; RefreshStats();
         }
      } else if(allowShort&&inSupply&&CheckLTFBreakOfStructure(-1)) {
         if(trade.Sell(FixedLotSize,_Symbol,bid,bid*(1+StopLossPercent/100),bid*(1-TakeProfitPercent/100))) {
            g_htfZoneTouched=false; g_supplyZones[0].isValid=false; g_lastLossDirection=0; g_tradesToday++; RefreshStats();
         }
      }
      return;
   }

   // ── OPTION B: Original candle confirmation (no BoS)
   if(!UseLTFConfirmation) {
      MqlRates r[]; ArraySetAsSeries(r,true);
      if(CopyRates(_Symbol,PERIOD_CURRENT,0,2,r)<2) return;
      double bd=MathAbs(r[1].close-r[1].open),rg=r[1].high-r[1].low,pct=(rg>0)?(bd/rg)*100:0;
      if(allowLong&&inDemand&&bid>ema[0]&&rsi[0]<RSIOverbought&&r[1].close>r[1].open&&pct>=ConfirmBodyMinPct) {
         if(trade.Buy(FixedLotSize,_Symbol,ask,ask*(1-StopLossPercent/100),ask*(1+TakeProfitPercent/100))) {
            g_demandZones[0].isValid=false; g_lastLossDirection=0; g_tradesToday++; RefreshStats();
         }
      }
      if(allowShort&&inSupply&&ask<ema[0]&&rsi[0]>RSIOversold&&r[1].close<r[1].open&&pct>=ConfirmBodyMinPct) {
         if(trade.Sell(FixedLotSize,_Symbol,bid,bid*(1+StopLossPercent/100),bid*(1-TakeProfitPercent/100))) {
            g_supplyZones[0].isValid=false; g_lastLossDirection=0; g_tradesToday++; RefreshStats();
         }
      }
   }
}

//──────────────────────────────────────────────────────────
// Trailing, TP, Risk, Draw — unchanged from V5.1
//──────────────────────────────────────────────────────────
void ManageStructuralTrailing() {
   if(!UseTrailing||!UseIntelligentTrail) return;
   ENUM_TIMEFRAMES srTF=PERIOD_H4;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double ent=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
      long tp=PositionGetInteger(POSITION_TYPE);
      double prc=(tp==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double pPct=MathAbs(prc-ent)/ent*100.0;
      int lb=20; if(pPct>5.0) lb=10; if(pPct>9.0) lb=5;
      if(tp==POSITION_TYPE_BUY) {
         int lbi=iLowest(_Symbol,srTF,MODE_LOW,lb,1);
         double sl2=NormalizeDouble(iLow(_Symbol,srTF,lbi)-(300*_Point),_Digits);
         if(sl2>sl||sl==0) trade.PositionModify(ticket,sl2,PositionGetDouble(POSITION_TP));
      } else {
         int hbi=iHighest(_Symbol,srTF,MODE_HIGH,lb,1);
         double sl2=NormalizeDouble(iHigh(_Symbol,srTF,hbi)+(300*_Point),_Digits);
         if(sl2<sl||sl==0) trade.PositionModify(ticket,sl2,PositionGetDouble(POSITION_TP));
      }
   }
}

void ManagePartialTakeProfit() {
   if(!UsePartialTP) return;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) {
         double il=PositionGetDouble(POSITION_VOLUME),ent=PositionGetDouble(POSITION_PRICE_OPEN);
         long tp=PositionGetInteger(POSITION_TYPE);
         double prc=(tp==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double pPct=MathAbs(prc-ent)/ent*100.0;
         if(pPct>=PartialTP_TriggerPct&&il>=FixedLotSize) {
            double cl=NormalizeDouble(il*(PartialClosePct/100.0),2);
            if(cl>0&&trade.PositionClosePartial(t,cl)) Print(StringFormat("V5.2: Partial TP %.2f%%",pPct));
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
   if(!equityTrailingActive&&(eq-startingEquity>=ActivationEquityGain)) { equityTrailingActive=true; }
   double tl=peakEquity*(1-TrailingEquityPercent/100);
   bool hf=(eq<MinimumEquityStop),tr=(equityTrailingActive&&eq<tl);
   if((hf||tr)&&!protectionHalt) {
      Print(StringFormat("V5.2 HALT at %.0f",eq)); 
      if(PositionsTotal()>0) CloseAllPositions(); protectionHalt=true;
   }
}

void ManageActiveTrades() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) {
         double ent=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
         long ty=PositionGetInteger(POSITION_TYPE);
         double prc=(ty==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double pPct=MathAbs(prc-ent)/ent*100.0;
         if(UseBreakEven&&pPct>=BE_TriggerPct) {
            double be=(ty==POSITION_TYPE_BUY)?ent*(1+BE_BufferPct/100):ent*(1-BE_BufferPct/100);
            if((ty==POSITION_TYPE_BUY&&sl<be)||(ty==POSITION_TYPE_SELL&&(sl>be||sl==0))) trade.PositionModify(t,NormalizeDouble(be,_Digits),tp);
         }
         if(UseTrailing&&!UseIntelligentTrail) {
            double dist=prc*(TrailingStopPct/100.0);
            double nsl=(ty==POSITION_TYPE_BUY)?prc-dist:prc+dist;
            if((ty==POSITION_TYPE_BUY&&nsl>sl)||(ty==POSITION_TYPE_SELL&&(nsl<sl||sl==0))) trade.PositionModify(t,NormalizeDouble(nsl,_Digits),tp);
         }
      }
   }
}

void DrawZones() {
   string dn=prefix+"D";
   if(g_demandZones[0].isValid) {
      if(ObjectFind(0,dn)<0) {
         ObjectCreate(0,dn,OBJ_RECTANGLE,0,g_demandZones[0].createdTime,g_demandZones[0].priceHigh,TimeCurrent()+(ZoneExpiryHours*3600*16),g_demandZones[0].priceLow);
         ObjectSetInteger(0,dn,OBJPROP_COLOR,C'35,70,35'); ObjectSetInteger(0,dn,OBJPROP_FILL,true); ObjectSetInteger(0,dn,OBJPROP_BACK,true); ObjectSetInteger(0,dn,OBJPROP_SELECTABLE,false);
      }
   } else ObjectDelete(0,dn);
   string sn=prefix+"S";
   if(g_supplyZones[0].isValid) {
      if(ObjectFind(0,sn)<0) {
         ObjectCreate(0,sn,OBJ_RECTANGLE,0,g_supplyZones[0].createdTime,g_supplyZones[0].priceLow,TimeCurrent()+(ZoneExpiryHours*3600*16),g_supplyZones[0].priceHigh);
         ObjectSetInteger(0,sn,OBJPROP_COLOR,C'70,35,35'); ObjectSetInteger(0,sn,OBJPROP_FILL,true); ObjectSetInteger(0,sn,OBJPROP_BACK,true); ObjectSetInteger(0,sn,OBJPROP_SELECTABLE,false);
      }
   } else ObjectDelete(0,sn);
}

void CreateLabel(string n,string t,int x,int y,int sz,color c) {
   string o=prefix+n;
   if(ObjectFind(0,o)<0) { ObjectCreate(0,o,OBJ_LABEL,0,0,0); ObjectSetInteger(0,o,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,o,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER); }
   ObjectSetString(0,o,OBJPROP_TEXT,t); ObjectSetInteger(0,o,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,o,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,o,OBJPROP_COLOR,c); ObjectSetInteger(0,o,OBJPROP_FONTSIZE,sz); ObjectSetString(0,o,OBJPROP_FONT,"Lucida Console");
}

void CloseAllPositions() {
   for(int i=PositionsTotal()-1;i>=0;i--) { ulong t=PositionGetTicket(i); if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber) trade.PositionClose(t); }
   RefreshStats();
}
