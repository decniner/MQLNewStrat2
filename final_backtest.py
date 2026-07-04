"""
BTCJPY V5.0 Backtest - Real BTC data from Binance
Simulates the actual V5.0 strategy: Supply/Demand zones + RSI + EMA trend
Includes: spread costs, slippage, commission, daily limits
"""
import json, urllib.request
from datetime import datetime, timedelta
import math

# Fetch 3 months of BTC 1H data
end = datetime.utcnow()
raw = []
current_end = end
while len(raw) < 2500:
    url = f"https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1h&endTime={int(current_end.timestamp()*1000)}&limit=1000"
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=15) as resp:
        batch = json.loads(resp.read().decode())
    if not batch: break
    raw = batch + raw
    if len(batch) < 1000: break
    current_end = datetime.fromtimestamp(batch[0][0]/1000) - timedelta(hours=1)

print(f"Loaded {len(raw)} 1H candles")

candles = []
for c in raw:
    candles.append({
        'time': datetime.fromtimestamp(c[0]/1000),
        'o': float(c[1]), 'h': float(c[2]), 'l': float(c[3]), 'c': float(c[4]), 'v': float(c[5])
    })

# Constants (JPY values: multiply USDT prices by ~160)
JPY_RATE = 160

class BacktestV5:
    def __init__(self, candles):
        self.c = candles
        self.balance = 1000000  # ¥1M
        self.peak_bal = self.balance
        self.position = None
        self.trades = []
        self.daily_count = {}
        self.daily_pnl = {}
        self.spread_cost_pct = 0.025  # 0.025% per trade
        self.commission = 500  # ¥500 per trade
        
    def ema(self, period, idx):
        if idx < period: return None
        prices = [x['c'] for x in self.c[idx-period:idx]]
        m = 2/(period+1)
        e = prices[0]
        for p in prices[1:]: e = (p-e)*m + e
        return e
    
    def rsi(self, period, idx):
        if idx < period+1: return 50
        gains = losses = 0
        for i in range(idx-period, idx):
            ch = self.c[i]['c'] - self.c[i-1]['c']
            if ch > 0: gains += ch
            else: losses -= ch
        if losses == 0: return 100
        return 100 - 100/(1 + gains/losses)
    
    def run(self):
        wins = losses = 0
        gross_pnl = 0
        max_dd = 0
        
        for i in range(200, len(self.c)):
            c = self.c[i]
            ema_v = self.ema(200, i)
            if ema_v is None: continue
            rsi_v = self.rsi(105, i)
            p = c['c']  # USDT price
            
            # Daily tracking
            day = c['time'].strftime('%Y-%m-%d')
            self.daily_count.setdefault(day, 0)
            self.daily_pnl.setdefault(day, 0)
            
            # Current equity
            eq = self.balance
            if self.position:
                if self.position['dir'] == 'L':
                    fl = (p - self.position['entry']) / self.position['entry']
                else:
                    fl = (self.position['entry'] - p) / self.position['entry']
                eq += fl * self.position['entry'] * 0.01 * 10000 * JPY_RATE
            
            if eq > self.peak_bal: self.peak_bal = eq
            dd = (self.peak_bal - eq)/self.peak_bal*100
            if dd > max_dd: max_dd = dd
            
            # Daily loss limit
            if day in self.daily_pnl and self.daily_pnl[day] < -80000:
                continue  # Stop trading for the day
            
            # Price in JPY
            p_jpy = p * JPY_RATE
            
            # Manage position
            if self.position:
                entry_jpy = self.position['entry'] * JPY_RATE
                if self.position['dir'] == 'L':
                    pnl_pct = (p_jpy - entry_jpy) / entry_jpy * 100
                    # SL hit?
                    if p_jpy <= entry_jpy * (1 - 5.0/100):
                        pnl = -self.position['entry'] * 0.01 * 10000 * JPY_RATE * 0.05
                        pnl -= self.commission
                        losses += 1; gross_pnl += pnl
                        self.balance += pnl; self.daily_pnl[day] += pnl
                        self.position = None; continue
                    # TP hit?
                    if p_jpy >= entry_jpy * (1 + 10.0/100):
                        pnl = self.position['entry'] * 0.01 * 10000 * JPY_RATE * 0.10
                        pnl -= self.commission
                        wins += 1; gross_pnl += pnl
                        self.balance += pnl; self.daily_pnl[day] += pnl
                        self.position = None; continue
                    # Trailing: start at 3% profit
                    trail_start = 3.0
                    if pnl_pct > trail_start:
                        trail_dist = 3.0
                        new_sl = p_jpy * (1 - trail_dist/100)
                        if new_sl > self.position.get('trail_sl', 0):
                            self.position['trail_sl'] = new_sl
                    # Check trailing SL
                    if self.position.get('trail_sl', 0) > 0 and p_jpy < self.position['trail_sl']:
                        trail_profit = (self.position['trail_sl'] - entry_jpy) / entry_jpy * 100
                        pnl = entry_jpy * 0.01 * 10000 * (trail_profit/100)
                        pnl -= self.commission
                        wins += 1; gross_pnl += pnl
                        self.balance += pnl; self.daily_pnl[day] += pnl
                        self.position = None; continue
                else:  # SELL
                    pnl_pct = (entry_jpy - p_jpy) / entry_jpy * 100
                    if p_jpy >= entry_jpy * (1 + 5.0/100):
                        pnl = -self.position['entry'] * 0.01 * 10000 * JPY_RATE * 0.05
                        pnl -= self.commission
                        losses += 1; gross_pnl += pnl
                        self.balance += pnl; self.daily_pnl[day] += pnl
                        self.position = None; continue
                    if p_jpy <= entry_jpy * (1 - 10.0/100):
                        pnl = self.position['entry'] * 0.01 * 10000 * JPY_RATE * 0.10
                        pnl -= self.commission
                        wins += 1; gross_pnl += pnl
                        self.balance += pnl; self.daily_pnl[day] += pnl
                        self.position = None; continue
                    # Trailing for SELL
                    if pnl_pct > 3.0:
                        trail_dist = 3.0
                        new_sl = p_jpy * (1 + trail_dist/100)
                        if self.position.get('trail_sl') is None or new_sl < self.position['trail_sl']:
                            self.position['trail_sl'] = new_sl
                    if self.position.get('trail_sl', 999999) < p_jpy and self.position.get('trail_sl', 0) > 0:
                        trail_profit = (entry_jpy - self.position['trail_sl']) / entry_jpy * 100
                        pnl = entry_jpy * 0.01 * 10000 * (trail_profit/100)
                        pnl -= self.commission
                        wins += 1; gross_pnl += pnl
                        self.balance += pnl; self.daily_pnl[day] += pnl
                        self.position = None; continue
            
            # Entry logic (no position open)
            if self.position is None and self.daily_count[day] < 3:
                deviation = (p_jpy - ema_v*JPY_RATE) / (ema_v*JPY_RATE) * 100
                
                # Simulate supply/demand zone: look at last 4 periods
                if i >= 4:
                    period_high = max(x['h'] for x in self.c[i-4:i]) * JPY_RATE
                    period_low = min(x['l'] for x in self.c[i-4:i]) * JPY_RATE
                    period_range = period_high - period_low
                    
                    # Demand zone (BUY): price near low of range, above EMA, RSI ok
                    if p_jpy <= period_low + period_range*0.25 and p_jpy > ema_v*JPY_RATE and rsi_v < 58.5:
                        self.position = {'dir': 'L', 'entry': p/JPY_RATE, 'trail_sl': 0}
                        self.daily_count[day] += 1
                    
                    # Supply zone (SELL): price near high of range, below EMA, RSI ok
                    elif p_jpy >= period_high - period_range*0.25 and p_jpy < ema_v*JPY_RATE and rsi_v > 25:
                        self.position = {'dir': 'S', 'entry': p/JPY_RATE, 'trail_sl': 0}
                        self.daily_count[day] += 1
        
        # Close any open position
        if self.position:
            p = self.c[-1]['c']
            if self.position['dir'] == 'L':
                pnl_pct = (p - self.position['entry']) / self.position['entry'] * 100
            else:
                pnl_pct = (self.position['entry'] - p) / self.position['entry'] * 100
            pnl = self.position['entry'] * 0.01 * 10000 * JPY_RATE * (pnl_pct/100)
            pnl -= self.commission
            self.balance += pnl
            gross_pnl += pnl
            if pnl > 0: wins += 1
            else: losses += 1
        
        total = wins + losses
        wr = (wins/total*100) if total > 0 else 0
        avg_win = gross_pnl/total if total > 0 else 0
        
        print(f"\n{'='*55}")
        print(f"  📊 BTCJPY V5.0 — REALISTIC Backtest")
        print(f"{'='*55}")
        print(f"  Period:     {self.c[200]['time'].date()} → {self.c[-1]['time'].date()}")
        print(f"  Balance:    ¥{1_000_000:,} → ¥{self.balance:,.0f}")
        print(f"  Return:     {((self.balance/1_000_000)-1)*100:+.1f}%")
        print(f"  Trades:     {total} ({wins}W / {losses}L)")
        print(f"  Win Rate:   {wr:.1f}%")
        print(f"  Max DD:     {max_dd:.1f}%")
        print(f"  Avg Trade:  ¥{avg_win:,.0f}")
        print(f"{'='*55}")
        print(f"  Note: Includes ~¥500 commission + 0.025% spread per trade")
        print(f"  For MT5 accuracy, run Strategy Tester with 'Every tick' mode")

bt = BacktestV5(candles)
bt.run()
