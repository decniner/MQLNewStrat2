"""
BTCJPY Hybrid V5.0 Simplified Backtest
Simulates the core strategy logic using historical 1H data from a free API
"""
import json
import urllib.request
from datetime import datetime, timedelta

# Fetch 3 months of BTCJPY 1H data
symbol = 'BTCJPY'
end = datetime.utcnow()
start = end - timedelta(days=90)

# Use Binance API for BTCUSDT (since BTCJPY data is hard to get free)
# We'll approximate: BTCJPY = BTCUSDT * JPY/USD rate (~160)
# Fetch BTCJPY 1H data with pagination
url = f"https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1h&startTime={int(start.timestamp()*1000)}&endTime={int(end.timestamp()*1000)}&limit=1000"

print("Fetching BTC data from Binance...")
raw = []
try:
    # Paginate to get more data
    current_end = end
    while len(raw) < 2200:
        url = f"https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1h&endTime={int(current_end.timestamp()*1000)}&limit=1000"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=15) as resp:
            batch = json.loads(resp.read().decode())
        if not batch:
            break
        raw = batch + raw
        if len(batch) < 1000:
            break
        current_end = datetime.fromtimestamp(batch[0][0]/1000) - timedelta(hours=1)
    print(f"Got {len(raw)} candles")
except Exception as e:
    print(f"Failed: {e}")
    raw = []

# Convert to our format
candles = []
for c in raw:
    candles.append({
        'time': datetime.fromtimestamp(c[0]/1000),
        'open': float(c[1]),
        'high': float(c[2]),
        'low': float(c[3]),
        'close': float(c[4])
    })

print(f"\nPeriod: {candles[0]['time'].date()} to {candles[-1]['time'].date()}")
print(f"Range: ${min(c['low'] for c in candles):.0f} - ${max(c['high'] for c in candles):.0f}")
print(f"Current: ${candles[-1]['close']:.0f}")

# Simulate V5.0 Strategy
# Simplified: 200 EMA + Supply/Demand + RSI-like overbought/oversold
# Since we don't have real RSI, use price deviation from EMA as proxy

class Backtest:
    def __init__(self, candles):
        self.candles = candles
        self.ema_period = 200
        self.rsi_period = 105
        self.sl_pct = 5.0
        self.tp_pct = 10.0
        self.trail_pct = 3.0
        self.partial_tp_pct = 5.0
        self.partial_close = 0.30
        self.max_trades_per_day = 3
        self.max_daily_loss_pct = 8.0
        self.lot_size = 0.01
        self.ob_level = 58.5
        self.os_level = 25.0  # FIXED from 7.5
        
        # Realistic costs
        self.spread_cost_pct = 0.02  # ~0.02% per trade for BTCJPY
        self.commission_per_trade = 500  # ¥500 per trade
        
        self.balance = 1000000  # ¥1M starting
        self.equity = self.balance
        self.position = None
        self.partial_taken = False
        self.trades = []
        self.daily_trades = {}
        self.daily_pnl = {}
        self.peak_equity = self.equity
    
    def ema(self, period, idx):
        if idx < period:
            return None
        prices = [c['close'] for c in self.candles[idx-period:idx]]
        multiplier = 2 / (period + 1)
        ema_val = prices[0]
        for p in prices[1:]:
            ema_val = (p - ema_val) * multiplier + ema_val
        return ema_val
    
    def rsi(self, period, idx):
        if idx < period + 1:
            return 50
        gains, losses = 0, 0
        for i in range(idx - period, idx):
            change = self.candles[i]['close'] - self.candles[i-1]['close']
            if change > 0: gains += change
            else: losses -= change
        if losses == 0: return 100
        rs = gains / losses if losses > 0 else 100
        return 100 - (100 / (1 + rs))
    
    def run(self):
        wins = 0
        losses = 0
        total_pnl = 0
        
        for i in range(200, len(self.candles)):
            c = self.candles[i]
            ema_val = self.ema(self.ema_period, i)
            if ema_val is None: continue
            
            rsi_val = self.rsi(self.rsi_period, i)
            price = c['close']
            
            # Update equity tracking
            if self.position:
                if self.position['type'] == 'BUY':
                    floating = (price - self.position['entry']) / self.position['entry'] * 100
                else:
                    floating = (self.position['entry'] - price) / self.position['entry'] * 100
                self.equity = self.balance + (floating / 100 * self.position['entry'] * self.lot_size * 10000)
            else:
                self.equity = self.balance
            
            if self.equity > self.peak_equity:
                self.peak_equity = self.equity
            
            # Daily tracking
            day_key = c['time'].strftime('%Y-%m-%d')
            if day_key not in self.daily_trades:
                self.daily_trades[day_key] = 0
                self.daily_pnl[day_key] = 0
            
            day_start_eq = self.balance  # simplified
            
            # Check daily loss limit
            if day_key in self.daily_pnl and self.daily_pnl[day_key] < 0:
                daily_loss_pct = abs(self.daily_pnl[day_key]) / self.balance * 100
                if daily_loss_pct >= self.max_daily_loss_pct:
                    continue  # Skip trading for the day
            
            # Close position if SL or TP hit
            if self.position:
                if self.position['type'] == 'BUY':
                    pnl_pct = (price - self.position['entry']) / self.position['entry'] * 100
                    sl_hit = price <= self.position['entry'] * (1 - self.position['sl_pct']/100)
                    tp_hit = price >= self.position['entry'] * (1 + self.position['tp_pct']/100)
                else:
                    pnl_pct = (self.position['entry'] - price) / self.position['entry'] * 100
                    sl_hit = price >= self.position['entry'] * (1 + self.position['sl_pct']/100)
                    tp_hit = price <= self.position['entry'] * (1 - self.position['tp_pct']/100)
                
                # Partial TP
                if not self.position.get('partial_done') and pnl_pct >= self.partial_tp_pct:
                    self.position['partial_done'] = True
                
                # Trailing stop - simplified
                if self.position.get('trail_high') is None:
                    self.position['trail_high'] = pnl_pct
                else:
                    if pnl_pct > self.position['trail_high']:
                        self.position['trail_high'] = pnl_pct
                    elif pnl_pct < self.position['trail_high'] - self.trail_pct:
                        # Trail triggered
                        tp_hit = True
                
                if sl_hit or tp_hit:
                    if sl_hit:
                        pnl = -self.position['entry'] * self.lot_size * 10000 * (self.position['sl_pct']/100)
                        losses += 1
                    else:
                        pnl_pct_actual = self.position['trail_high'] if self.position.get('trail_high') else pnl_pct
                        pnl = self.position['entry'] * self.lot_size * 10000 * (pnl_pct_actual/100)
                        wins += 1
                    
                    # Apply partial TP adjustment
                    if self.position.get('partial_done'):
                        pnl *= (1 - self.partial_close * 0.3)  # rough adjustment
                    
                    self.balance += pnl
                    total_pnl += pnl
                    self.daily_pnl[day_key] = self.daily_pnl.get(day_key, 0) + pnl
                    self.position = None
                    continue
            
            # Entry logic (no open position + daily limit check)
            if self.position is None and self.daily_trades[day_key] < self.max_trades_per_day:
                deviation = (price - ema_val) / ema_val * 100
                
                # Simplified Supply/Demand simulation
                # When price is below EMA and RSI not oversold = look for demand (BUY)
                if price > ema_val and rsi_val < self.ob_level:
                    # Above EMA + RSI not overbought = bullish zone demand
                    self.position = {
                        'type': 'BUY',
                        'entry': price,
                        'sl_pct': self.sl_pct,
                        'tp_pct': self.tp_pct,
                        'entry_time': c['time'],
                        'trail_high': None,
                        'partial_done': False
                    }
                    self.daily_trades[day_key] += 1
                
                # When price is above EMA and RSI not oversold = look for supply (SELL)
                elif price < ema_val and rsi_val > self.os_level:
                    # Below EMA + RSI not oversold = bearish zone supply
                    self.position = {
                        'type': 'SELL',
                        'entry': price,
                        'sl_pct': self.sl_pct,
                        'tp_pct': self.tp_pct,
                        'entry_time': c['time'],
                        'trail_high': None,
                        'partial_done': False
                    }
                    self.daily_trades[day_key] += 1
        
        # Close any open position at end
        if self.position:
            pnl_pct = (self.candles[-1]['close'] - self.position['entry']) / self.position['entry'] * 100
            if self.position['type'] == 'SELL':
                pnl_pct = -pnl_pct
            pnl = self.position['entry'] * self.lot_size * 10000 * (pnl_pct/100)
            self.balance += pnl
            total_pnl += pnl
            if pnl > 0: wins += 1
            else: losses += 1
        
        total = wins + losses
        win_rate = (wins / total * 100) if total > 0 else 0
        print(f"\n{'='*50}")
        print(f"📊 BTCJPY Hybrid V5.0 — Backtest Results")
        print(f"{'='*50}")
        print(f"Period: {self.candles[200]['time'].date()} to {self.candles[-1]['time'].date()}")
        print(f"Starting Balance: ¥{1000000:,.0f}")
        print(f"Final Balance:    ¥{self.balance:,.0f}")
        print(f"Total P&L:        ¥{total_pnl:,.0f}")
        print(f"Return:           {((self.balance/1000000)-1)*100:.1f}%")
        print(f"Total Trades:     {total}")
        print(f"Wins:             {wins}")
        print(f"Losses:           {losses}")
        print(f"Win Rate:         {win_rate:.1f}%")
        print(f"Peak Equity:      ¥{self.peak_equity:,.0f}")
        max_dd = (1 - self.balance/self.peak_equity)*100 if self.peak_equity > 0 else 0
        print(f"Max Drawdown:     {max_dd:.1f}%")
        
        # Monthly breakdown
        print(f"\n📅 Daily Trade Summary:")
        sorted_days = sorted(self.daily_trades.items())
        for day, count in sorted_days[-10:]:
            pnl = self.daily_pnl.get(day, 0)
            sign = "+" if pnl >= 0 else ""
            print(f"  {day}: {count} trades | P&L {sign}¥{pnl:,.0f}")

bt = Backtest(candles)
bt.run()
