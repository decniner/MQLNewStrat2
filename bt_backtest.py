"""BTCJPY V5.0 Backtest using REAL MT5 data"""
import json
import math

# Load real BTCJPY data
with open(r'C:\Users\decni\projects\mql-bots\btc_data.json') as f:
    data = json.load(f)

candles = data['rates']
print(f"Loaded {len(candles)} candles from MT5")
print(f"Period: {data['period']}")

# Convert - data is already in dict format from JSON
for c in candles:
    c['time'] = c['t']
    del c['t']

# Strategy parameters matching V5.0
SL_PCT = 5.0
TP_PCT = 10.0
TRAIL_PCT = 3.0
RSI_PERIOD = 105
EMA_PERIOD = 200
RSI_OB = 58.5
RSI_OS = 25.0
LOT = 0.01
MAX_TRADES_DAY = 3
COMMISSION = 500

# Utility functions
def calc_ema(prices, period):
    if len(prices) < period: return None
    m = 2 / (period + 1)
    e = prices[0]
    for p in prices[1:]:
        e = (p - e) * m + e
    return e

def calc_rsi(prices, period):
    if len(prices) < period + 1: return 50
    gains = losses = 0
    for i in range(len(prices)-period, len(prices)):
        ch = prices[i] - prices[i-1]
        if ch > 0: gains += ch
        else: losses -= ch
    if losses == 0: return 100
    return 100 - 100 / (1 + gains/losses)

# Run backtest
balance = 1_000_000  # ¥1M
peak_bal = balance
position = None
trades = []
daily_trades = {}
daily_pnl = {}
max_dd = 0

prices = [c['c'] for c in candles]

for i in range(EMA_PERIOD, len(candles)):
    c = candles[i]
    p = c['c']
    ema_v = calc_ema(prices[:i], EMA_PERIOD)
    if ema_v is None: continue
    rsi_v = calc_rsi(prices[:i+1], RSI_PERIOD)
    
    day = datetime.fromtimestamp(c['time']).strftime('%Y-%m-%d') if hasattr(__builtins__, 'datetime') else ''
    
    try:
        from datetime import datetime
        day = datetime.fromtimestamp(c['time']).strftime('%Y-%m-%d')
    except:
        import time
        day = time.strftime('%Y-%m-%d', time.gmtime(c['time']))
    
    daily_trades.setdefault(day, 0)
    daily_pnl.setdefault(day, 0)
    
    # Equity
    eq = balance
    if position:
        if position['dir'] == 'L':
            fl = (p - position['entry']) / position['entry']
        else:
            fl = (position['entry'] - p) / position['entry']
        eq += fl * position['entry'] * LOT * 10000
    
    if eq > peak_bal: peak_bal = eq
    dd = (peak_bal - eq) / peak_bal * 100
    if dd > max_dd: max_dd = dd
    
    # Daily loss limit
    if day in daily_pnl and daily_pnl[day] < -80000:
        continue
    
    # Manage position
    if position:
        entry = position['entry']
        if position['dir'] == 'L':
            pnl_pct = (p - entry) / entry * 100
            if p <= entry * (1 - SL_PCT/100):
                pnl = -entry * LOT * 10000 * (SL_PCT/100) - COMMISSION
                balance += pnl; daily_pnl[day] += pnl
                position = None; trades.append({'r': -abs(pnl), 'w': 0, 'd': day}); continue
            if p >= entry * (1 + TP_PCT/100):
                pnl = entry * LOT * 10000 * (TP_PCT/100) - COMMISSION
                balance += pnl; daily_pnl[day] += pnl
                position = None; trades.append({'r': pnl, 'w': 1, 'd': day}); continue
            if pnl_pct > TRAIL_PCT:
                trail_sl = p * (1 - TRAIL_PCT/100)
                if trail_sl > position.get('ts', 0):
                    position['ts'] = trail_sl
            if position.get('ts', 0) > 0 and p < position['ts']:
                trail_pnl = (position['ts'] - entry) / entry * 100
                pnl = entry * LOT * 10000 * (trail_pnl/100) - COMMISSION
                balance += pnl; daily_pnl[day] += pnl
                position = None; trades.append({'r': pnl, 'w': 1 if pnl > 0 else 0, 'd': day}); continue
        else:  # SELL
            pnl_pct = (entry - p) / entry * 100
            if p >= entry * (1 + SL_PCT/100):
                pnl = -entry * LOT * 10000 * (SL_PCT/100) - COMMISSION
                balance += pnl; daily_pnl[day] += pnl
                position = None; trades.append({'r': -abs(pnl), 'w': 0, 'd': day}); continue
            if p <= entry * (1 - TP_PCT/100):
                pnl = entry * LOT * 10000 * (TP_PCT/100) - COMMISSION
                balance += pnl; daily_pnl[day] += pnl
                position = None; trades.append({'r': pnl, 'w': 1, 'd': day}); continue
            if pnl_pct > TRAIL_PCT:
                trail_sl = p * (1 + TRAIL_PCT/100)
                if position.get('ts') is None or trail_sl < position['ts']:
                    position['ts'] = trail_sl
            if position.get('ts', 99999999) > 0 and p > position['ts']:
                trail_pnl = (entry - position['ts']) / entry * 100
                pnl = entry * LOT * 10000 * (trail_pnl/100) - COMMISSION
                balance += pnl; daily_pnl[day] += pnl
                position = None; trades.append({'r': pnl, 'w': 1 if pnl > 0 else 0, 'd': day}); continue
    
    # Entry
    if position is None and daily_trades[day] < MAX_TRADES_DAY:
        deviation = (p - ema_v) / ema_v * 100
        
        # Find local support/resistance (supply/demand)
        lookback = 4
        if i >= lookback:
            local_high = max(candles[i-lookback]['h'] for c_ in [candles] for _ in [0] if True) or max(c['h'] for c in candles[i-lookback:i])
            local_low = min(c['l'] for c in candles[i-lookback:i])
            local_range = local_high - local_low
            
            # Fix the local high calculation
            local_high = max(candles[i-lookback:i], key=lambda x: x['h'])['h']
            local_low = min(candles[i-lookback:i], key=lambda x: x['l'])['l']
            local_range = local_high - local_low
            
            # Demand zone BUY
            if p <= local_low + local_range * 0.25 and p > ema_v and rsi_v < RSI_OB:
                position = {'dir': 'L', 'entry': p, 'ts': 0}
                daily_trades[day] += 1
            # Supply zone SELL
            elif p >= local_high - local_range * 0.25 and p < ema_v and rsi_v > RSI_OS:
                position = {'dir': 'S', 'entry': p, 'ts': 0}
                daily_trades[day] += 1

# Results
wins = sum(1 for t in trades if t['w'])
losses = sum(1 for t in trades if not t['w'])
total = len(trades)
gross = sum(t['r'] for t in trades)
wr = (wins/total*100) if total > 0 else 0

print(f"\n{'='*55}")
print(f"  📊 BTCJPY V5.0 — REAL MT5 DATA BACKTEST")
print(f"{'='*55}")
print(f"  Data source: XM Trading MT5 (real BTCJPY ticks)")
print(f"  Period:      {data['period']}")
print(f"  Starting:    ¥1,000,000")
print(f"  Final:       ¥{balance:,.0f}")
print(f"  Return:      {((balance/1_000_000)-1)*100:+.1f}%")
print(f"{'─'*55}")
print(f"  Total trades: {total}")
print(f"  Wins:         {wins}")
print(f"  Losses:       {losses}")
print(f"  Win rate:     {wr:.1f}%")
print(f"  Gross P&L:    ¥{gross:,.0f}")
print(f"  Max DD:       {max_dd:.1f}%")
print(f"  Avg/trade:    ¥{gross/total:,.0f}" if total > 0 else "")
print(f"{'='*55}")

# Monthly breakdown
from collections import defaultdict
monthly = defaultdict(lambda: {'trades': 0, 'pnl': 0, 'wins': 0})
for t in trades:
    m = t['d'][:7]
    monthly[m]['trades'] += 1
    monthly[m]['pnl'] += t['r']
    if t['w']: monthly[m]['wins'] += 1

print(f"\n📅 Monthly:")
for m in sorted(monthly.keys()):
    d = monthly[m]
    print(f"  {m}: {d['trades']} trades, ¥{d['pnl']:+,.0f}, {d['wins']/d['trades']*100:.0f}% WR")
