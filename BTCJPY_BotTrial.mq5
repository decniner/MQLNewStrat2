//+------------------------------------------------------------------+
//|                                      BTCJPY_SupplyDemand_EA.mq5 |
//|                                     Professional Trading Systems |
//+------------------------------------------------------------------+
#property copyright "Professional Trading Systems"
#property version   "2.00"
#property strict

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double   RiskPercent          = 1.0;         // Risk per trade (%)
input double   MaxDailyLossPercent  = 3.0;         // Max daily loss (%)
input int      MaxConsecutiveLosses = 3;           // Max consecutive losses

input group "=== Zone Detection ==="
input ENUM_TIMEFRAMES ZoneTF        = PERIOD_H1;   // Zone detection timeframe
input int      BodyStrengthMin      = 60;          // Min body strength (%)
input int      MaxZonesPerType      = 5;           // Max zones to track
input int      ZoneExpiryBars       = 100;         // Zone expiry (bars)

input group "=== Stop Loss & Take Profit ==="
input int      StopLossPoints       = 15000;       // Stop loss (points) ~15000 JPY
input int      TakeProfitPoints     = 30000;       // Take profit (points) ~30000 JPY
input bool     UseBreakeven         = true;        // Use breakeven
input int      BreakevenTrigger     = 15000;       // Breakeven trigger (points)
input int      BreakevenOffset      = 1000;        // Breakeven offset (points)

input group "=== Trend Filter ==="
input bool     UseEMAFilter         = true;        // Use EMA filter
input int      EMA_Fast             = 20;          // Fast EMA period
input int      EMA_Slow             = 50;          // Slow EMA period
input int      EMA_Trend            = 200;         // Trend EMA period

input group "=== Session Filter ==="
input bool     UseSessionFilter     = true;        // Use session filter
input int      TokyoStart           = 9;           // Tokyo start (JST)
input int      TokyoEnd             = 15;          // Tokyo end (JST)
input int      LondonStart          = 17;          // London start (JST)
input int      LondonEnd            = 1;           // London end (JST)
input int      NYStart              = 22;          // NY start (JST)
input int      NYEnd                = 6;           // NY end (JST)

input group "=== Advanced Settings ==="
input long     MagicNumber          = 240105;      // Magic number
input int      Slippage             = 100;         // Max slippage (points)
input string   TradeComment         = "BTCJPY_SD"; // Trade comment
input bool     ShowZonesOnChart     = true;        // Show zones on chart

//+------------------------------------------------------------------+
struct SZone {
   double   priceHigh, priceLow;
   datetime timeCreated;
   int      touches;
   double   strength;
   bool     isValid;
   string   objectID;
};

SZone g_demandZones[], g_supplyZones[];
int g_demandCount = 0, g_supplyCount = 0;
datetime g_lastZoneCheck = 0, g_lastDailyReset = 0;
double g_dailyProfit = 0.0, g_startingDailyBalance = 0.0;
int g_consecutiveLosses = 0;
int g_emaFastHandle = INVALID_HANDLE, g_emaSlowHandle = INVALID_HANDLE, g_emaTrendHandle = INVALID_HANDLE;
bool g_tradingAllowed = true;

//+------------------------------------------------------------------+
int OnInit() {
   if(RiskPercent <= 0 || RiskPercent > 10) {
      Print("ERROR: Risk percent must be 0-10"); return INIT_PARAMETERS_INCORRECT;
   }
   if(StopLossPoints <= 0 || TakeProfitPoints <= 0) {
      Print("ERROR: SL/TP must be positive"); return INIT_PARAMETERS_INCORRECT;
   }
   
   ArrayResize(g_demandZones, MaxZonesPerType);
   ArrayResize(g_supplyZones, MaxZonesPerType);
   for(int i = 0; i < MaxZonesPerType; i++) {
      g_demandZones[i].isValid = false;
      g_supplyZones[i].isValid = false;
   }
   
   if(UseEMAFilter) {
      g_emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_emaTrendHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
      
      if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE || g_emaTrendHandle == INVALID_HANDLE) {
         Print("ERROR: Failed to create EMAs"); return INIT_FAILED;
      }
   }
   
   g_startingDailyBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastDailyReset = TimeCurrent();
   Print("=== BTCJPY SD EA Initialized | Risk:", RiskPercent,"% | SL:",StopLossPoints," TP:",TakeProfitPoints," ===");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if(g_emaTrendHandle != INVALID_HANDLE) IndicatorRelease(g_emaTrendHandle);
   DeleteAllZoneObjects();
   Print("=== EA Deinitialized | Reason:",reason," ===");
}

//+------------------------------------------------------------------+
void OnTick() {
   CheckDailyReset();
   if(!CheckDailyLossLimit() || !CheckConsecutiveLosses()) {
      if(g_tradingAllowed) { Print("Trading stopped - Risk limits"); g_tradingAllowed = false; }
      return;
   }
   
   ManagePositions();
   if(HasOpenPosition()) return;
   if(UseSessionFilter && !InTradingSession()) return;
   
   DetectZones();
   CleanExpiredZones();
   CheckTradeSignals();
}

//+------------------------------------------------------------------+
void DetectZones() {
   datetime currentBarTime = iTime(_Symbol, ZoneTF, 0);
   if(currentBarTime == g_lastZoneCheck) return;
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, ZoneTF, 1, 3, rates) < 3) return;
   
   double open = rates[0].open, close = rates[0].close;
   double high = rates[0].high, low = rates[0].low;
   datetime time = rates[0].time;
   double body = MathAbs(close - open), range = high - low;
   if(range <= 0) return;
   
   double strength = (body / range) * 100.0;
   
   if(close > open && strength >= BodyStrengthMin && ValidateImpulse(rates, true)) {
      AddDemandZone(low, low + (range * 0.3), time, strength);
   }
   if(open > close && strength >= BodyStrengthMin && ValidateImpulse(rates, false)) {
      AddSupplyZone(high - (range * 0.3), high, time, strength);
   }
   g_lastZoneCheck = currentBarTime;
}

//+------------------------------------------------------------------+
bool ValidateImpulse(const MqlRates &rates[], bool isBullish) {
   if(ArraySize(rates) < 3) return true;
   if(isBullish) return rates[1].close < rates[1].open || rates[2].close < rates[2].open;
   return rates[1].close > rates[1].open || rates[2].close > rates[2].open;
}

//+------------------------------------------------------------------+
void AddDemandZone(double low, double high, datetime time, double strength) {
   for(int i = 0; i < g_demandCount; i++)
      if(g_demandZones[i].isValid && MathAbs(g_demandZones[i].priceLow - low) < (high - low)) return;
   
   int slot = -1;
   for(int i = 0; i < MaxZonesPerType; i++) if(!g_demandZones[i].isValid) { slot = i; break; }
   if(slot == -1) {
      double minStr = 999; 
      for(int i = 0; i < MaxZonesPerType; i++) if(g_demandZones[i].strength < minStr) { minStr = g_demandZones[i].strength; slot = i; }
      if(ShowZonesOnChart) ObjectDelete(0, g_demandZones[slot].objectID);
   }
   
   g_demandZones[slot].priceLow = low; g_demandZones[slot].priceHigh = high;
   g_demandZones[slot].timeCreated = time; g_demandZones[slot].touches = 0;
   g_demandZones[slot].strength = strength; g_demandZones[slot].isValid = true;
   g_demandZones[slot].objectID = "Demand_" + IntegerToString(time);
   if(g_demandCount < MaxZonesPerType) g_demandCount++;
   if(ShowZonesOnChart) DrawZone(g_demandZones[slot].objectID, time, low, high, clrLimeGreen);
   Print("DEMAND ZONE: ",low,"-",high," | Str:",DoubleToString(strength,1),"%");
}

//+------------------------------------------------------------------+
void AddSupplyZone(double low, double high, datetime time, double strength) {
   for(int i = 0; i < g_supplyCount; i++)
      if(g_supplyZones[i].isValid && MathAbs(g_supplyZones[i].priceHigh - high) < (high - low)) return;
   
   int slot = -1;
   for(int i = 0; i < MaxZonesPerType; i++) if(!g_supplyZones[i].isValid) { slot = i; break; }
   if(slot == -1) {
      double minStr = 999;
      for(int i = 0; i < MaxZonesPerType; i++) if(g_supplyZones[i].strength < minStr) { minStr = g_supplyZones[i].strength; slot = i; }
      if(ShowZonesOnChart) ObjectDelete(0, g_supplyZones[slot].objectID);
   }
   
   g_supplyZones[slot].priceLow = low; g_supplyZones[slot].priceHigh = high;
   g_supplyZones[slot].timeCreated = time; g_supplyZones[slot].touches = 0;
   g_supplyZones[slot].strength = strength; g_supplyZones[slot].isValid = true;
   g_supplyZones[slot].objectID = "Supply_" + IntegerToString(time);
   if(g_supplyCount < MaxZonesPerType) g_supplyCount++;
   if(ShowZonesOnChart) DrawZone(g_supplyZones[slot].objectID, time, low, high, clrCoral);
   Print("SUPPLY ZONE: ",low,"-",high," | Str:",DoubleToString(strength,1),"%");
}

//+------------------------------------------------------------------+
void CleanExpiredZones() {
   datetime now = TimeCurrent();
   for(int i = 0; i < MaxZonesPerType; i++) {
      if(g_demandZones[i].isValid && Bars(_Symbol, ZoneTF, g_demandZones[i].timeCreated, now) > ZoneExpiryBars) {
         if(ShowZonesOnChart) ObjectDelete(0, g_demandZones[i].objectID);
         g_demandZones[i].isValid = false; g_demandCount--;
      }
      if(g_supplyZones[i].isValid && Bars(_Symbol, ZoneTF, g_supplyZones[i].timeCreated, now) > ZoneExpiryBars) {
         if(ShowZonesOnChart) ObjectDelete(0, g_supplyZones[i].objectID);
         g_supplyZones[i].isValid = false; g_supplyCount--;
      }
   }
}

//+------------------------------------------------------------------+
void CheckTradeSignals() {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   for(int i = 0; i < MaxZonesPerType; i++) {
      if(g_demandZones[i].isValid && bid >= g_demandZones[i].priceLow && bid <= g_demandZones[i].priceHigh) {
         if(TrendOK(true) && HasRejectionConfirmation(true)) {
            if(OpenTrade(ORDER_TYPE_BUY, g_demandZones[i].priceLow)) {
               if(ShowZonesOnChart) ObjectDelete(0, g_demandZones[i].objectID);
               g_demandZones[i].isValid = false; g_demandCount--;
            }
            return;
         }
      }
      if(g_supplyZones[i].isValid && ask >= g_supplyZones[i].priceLow && ask <= g_supplyZones[i].priceHigh) {
         if(TrendOK(false) && HasRejectionConfirmation(false)) {
            if(OpenTrade(ORDER_TYPE_SELL, g_supplyZones[i].priceHigh)) {
               if(ShowZonesOnChart) ObjectDelete(0, g_supplyZones[i].objectID);
               g_supplyZones[i].isValid = false; g_supplyCount--;
            }
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
bool HasRejectionConfirmation(bool isBuy) {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 2, rates) < 2) return true;
   
   double body = MathAbs(rates[1].close - rates[1].open);
   double range = rates[1].high - rates[1].low;
   if(range <= 0) return true;
   
   return isBuy ? (rates[1].close > rates[1].open && (body/range) > 0.5) : (rates[1].close < rates[1].open && (body/range) > 0.5);
}

//+------------------------------------------------------------------+
bool TrendOK(bool isBuy) {
   if(!UseEMAFilter) return true;
   
   double emaF[], emaS[], emaT[];
   ArraySetAsSeries(emaF, true); ArraySetAsSeries(emaS, true); ArraySetAsSeries(emaT, true);
   if(CopyBuffer(g_emaFastHandle, 0, 0, 2, emaF) < 2 || CopyBuffer(g_emaSlowHandle, 0, 0, 2, emaS) < 2 || CopyBuffer(g_emaTrendHandle, 0, 0, 2, emaT) < 2) return true;
   
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return isBuy ? (emaF[0] > emaS[0] && emaS[0] > emaT[0] && price > emaT[0]) : (emaF[0] < emaS[0] && emaS[0] < emaT[0] && price < emaT[0]);
}

//+------------------------------------------------------------------+
bool InTradingSession() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(h >= TokyoStart && h < TokyoEnd) return true;
   if((LondonEnd > LondonStart && h >= LondonStart && h < LondonEnd) || (LondonEnd < LondonStart && (h >= LondonStart || h < LondonEnd))) return true;
   if((NYEnd > NYStart && h >= NYStart && h < NYEnd) || (NYEnd < NYStart && (h >= NYStart || h < NYEnd))) return true;
   return false;
}

//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double zonePrice) {
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalculateLotSize();
   if(lot <= 0) { Print("ERROR: Invalid lot"); return false; }
   
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl = (type == ORDER_TYPE_BUY) ? price - StopLossPoints * pt : price + StopLossPoints * pt;
   double tp = (type == ORDER_TYPE_BUY) ? price + TakeProfitPoints * pt : price - TakeProfitPoints * pt;
   
   int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, dig); sl = NormalizeDouble(sl, dig); tp = NormalizeDouble(tp, dig);
   
   req.action = TRADE_ACTION_DEAL; req.symbol = _Symbol; req.volume = lot; req.type = type;
   req.price = price; req.sl = sl; req.tp = tp; req.deviation = Slippage;
   req.magic = MagicNumber; req.comment = TradeComment; req.type_filling = GetFillingMode();
   
   for(int i = 0; i < 3; i++) {
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)) {
         Print("TRADE:",EnumToString(type)," Lot:",lot," Price:",price," SL:",sl," TP:",tp," Ticket:",res.order);
         return true;
      }
      Print("Order failed:",res.retcode,"-",res.comment); Sleep(500);
   }
   return false;
}

//+------------------------------------------------------------------+
double CalculateLotSize() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = balance * (RiskPercent / 100.0);
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tickSize == 0 || tickValue == 0 || pt == 0) return 0;
   
   double lot = (risk * tickSize) / (StopLossPoints * pt * tickValue);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / step) * step;
   return MathMax(minLot, MathMin(maxLot, lot));
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode() {
   int fill = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
void ManagePositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(UseBreakeven) MoveToBreakeven(ticket);
   }
}

//+------------------------------------------------------------------+
void MoveToBreakeven(ulong ticket) {
   if(!PositionSelectByTicket(ticket)) return;
   
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL = PositionGetDouble(POSITION_SL);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if((type == POSITION_TYPE_BUY && curSL >= openPrice) || (type == POSITION_TYPE_SELL && curSL <= openPrice && curSL > 0)) return;
   
   double curPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trigger = openPrice + BreakevenTrigger * pt * (type == POSITION_TYPE_BUY ? 1 : -1);
   
   if((type == POSITION_TYPE_BUY && curPrice >= trigger) || (type == POSITION_TYPE_SELL && curPrice <= trigger)) {
      double newSL = openPrice + BreakevenOffset * pt * (type == POSITION_TYPE_BUY ? 1 : -1);
      newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_SLTP; req.symbol = _Symbol; req.sl = newSL;
      req.tp = PositionGetDouble(POSITION_TP); req.position = ticket;
      
      if(OrderSend(req, res)) Print("Moved to breakeven: Ticket:",ticket," NewSL:",newSL);
   }
}

//+------------------------------------------------------------------+
bool HasOpenPosition() {
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CheckDailyReset() {
   MqlDateTime dtNow, dtLast;
   TimeToStruct(TimeCurrent(), dtNow);
   TimeToStruct(g_lastDailyReset, dtLast);
   
   if(dtNow.day != dtLast.day) {
      g_startingDailyBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyProfit = 0; g_consecutiveLosses = 0; g_tradingAllowed = true;
      g_lastDailyReset = TimeCurrent();
      Print("=== Daily Reset | Balance:",g_startingDailyBalance," ===");
   }
}

//+------------------------------------------------------------------+
bool CheckDailyLossLimit() {
   double curBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss = g_startingDailyBalance - curBalance;
   double lossPercent = (loss / g_startingDailyBalance) * 100.0;
   return lossPercent < MaxDailyLossPercent;
}

//+------------------------------------------------------------------+
bool CheckConsecutiveLosses() {
   int losses = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && losses < MaxConsecutiveLosses; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit < 0) losses++; else break;
   }
   return losses < MaxConsecutiveLosses;
}

//+------------------------------------------------------------------+
void DrawZone(string id, datetime t, double low, double high, color clr) {
   if(ObjectFind(0, id) >= 0) ObjectDelete(0, id);
   ObjectCreate(0, id, OBJ_RECTANGLE, 0, t, high, TimeCurrent() + PeriodSeconds(ZoneTF) * 20, low);
   ObjectSetInteger(0, id, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, id, OBJPROP_BACK, true);
   ObjectSetInteger(0, id, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, id, OBJPROP_FILL, true);
}

//+------------------------------------------------------------------+
void DeleteAllZoneObjects() {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
      string name = ObjectName(0, i);
      if(StringFind(name, "Demand_") >= 0 || StringFind(name, "Supply_") >= 0) ObjectDelete(0, name);
   }
}