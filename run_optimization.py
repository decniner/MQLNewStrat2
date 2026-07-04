"""BTCJPY V5.1 Optimization — Python Grid Search (using cached data)"""
import json, math
from datetime import datetime

# Load cached BTCJPY data
print("Loading cached BTCJPY data...")
with open(r'C:\Users\decni\projects\mql-bots\btc_data.json') as f:
    data = json.load(f)

candles = data['rates']
print(f"Loaded {len(candles)} candles")
print(f"Period: {data.get('period', 'N/A')}")
print(f"Current bid: {data.get('current_bid', 'N/A')}")

prices = [c['c'] for c in candles]
N = len(prices)

print(f"\nRunning Optimization...")
print(f"Parameters to test: SL=[4,5,6,7,8] TP=[6,7,8,9,10,11,12] Trail=[2,3,4,5]")
print(f"Total combos: {5*7*4} = 140")
print()

def calc_ema(prices_list, period, idx):
    if idx < period: return None
    pp = prices_list[idx-period:idx]
    m = 2/(period+1)
    e = pp[0]
    for p in pp[1:]: e = (p-e)*m+e
    return e

def calc_rsi(prices_list, period, idx):
    if idx < period+1: return 50
    gains = losses = 0
    for i in range(idx-period, idx):
        ch = prices_list[i] - prices_list[i-1]
        if ch > 0: gains += ch
        else: losses -= ch
    if losses == 0: return 100
    return 100 - 100/(1 + gains/losses)

results = []
total = 5*7*4
done = 0

for sl_pct in [4.0, 5.0, 6.0, 7.0, 8.0]:
    for tp_pct in [6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0]:
        for trail_pct in [2.0, 3.0, 4.0, 5.0]:
            balance = 1_000_000
            peak = balance
            position = None
            trades = []
            max_dd = 0
            winners = losers = 0
            
            for i in range(200, N):
                c = candles[i]
                p = c['c']
                ema_v = calc_ema(prices, 200, i)
                if ema_v is None: continue
                rsi_v = calc_rsi(prices, 105, i)
                
                # Equity
                eq = balance
                if position:
                    if position['dir'] == 'L':
                        fl = (p - position['entry']) / position['entry']
                    else:
                        fl = (position['entry'] - p) / position['entry']
                    eq += fl * position['entry'] * 0.01 * 10000
                if eq > peak: peak = eq
                dd = (peak - eq) / peak * 100
                if dd > max_dd: max_dd = dd
                
                # Manage position
                if position:
                    entry = position['entry']
                    if position['dir'] == 'L':
                        pnl_pct = (p - entry) / entry * 100
                        if p <= entry * (1 - sl_pct/100):
                            pnl = -entry * 0.01 * 10000 * (sl_pct/100) - 500
                            balance += pnl; losers += 1
                            position = None; trades.append(pnl); continue
                        if p >= entry * (1 + tp_pct/100):
                            pnl = entry * 0.01 * 10000 * (tp_pct/100) - 500
                            balance += pnl; winners += 1
                            position = None; trades.append(pnl); continue
                        if pnl_pct > trail_pct:
                            ts = p * (1 - trail_pct/100)
                            if ts > position.get('ts', 0): position['ts'] = ts
                        if position.get('ts', 0) > 0 and p < position['ts']:
                            tp_pnl = (position['ts'] - entry) / entry * 100
                            pnl = entry * 0.01 * 10000 * (tp_pnl/100) - 500
                            balance += pnl; winners += 1
                            position = None; trades.append(pnl); continue
                    else:
                        pnl_pct = (entry - p) / entry * 100
                        if p >= entry * (1 + sl_pct/100):
                            pnl = -entry * 0.01 * 10000 * (sl_pct/100) - 500
                            balance += pnl; losers += 1
                            position = None; trades.append(pnl); continue
                        if p <= entry * (1 - tp_pct/100):
                            pnl = entry * 0.01 * 10000 * (tp_pct/100) - 500
                            balance += pnl; winners += 1
                            position = None; trades.append(pnl); continue
                        if pnl_pct > trail_pct:
                            ts = p * (1 + trail_pct/100)
                            if position.get('ts') is None or ts < position['ts']: position['ts'] = ts
                        if position.get('ts', 999999) > 0 and p > position['ts']:
                            tp_pnl = (entry - position['ts']) / entry * 100
                            pnl = entry * 0.01 * 10000 * (tp_pnl/100) - 500
                            balance += pnl; winners += 1
                            position = None; trades.append(pnl); continue
                
                # Entry
                if position is None and i >= 204:
                    # Simple supply/demand: local low/high over 4 bars
                    lo = min(c['l'] for c in candles[i-4:i])
                    hi = max(c['h'] for c in candles[i-4:i])
                    rng = hi - lo
                    if p <= lo + rng*0.25 and p > ema_v and rsi_v < 65:
                        position = {'dir': 'L', 'entry': p, 'ts': 0}
                    elif p >= hi - rng*0.25 and p < ema_v and rsi_v > 25:
                        position = {'dir': 'S', 'entry': p, 'ts': 0}
            
            total_trades = winners + losers
            gross_profit = sum(t for t in trades if t > 0)
            gross_loss = abs(sum(t for t in trades if t < 0))
            profit_factor = gross_profit / gross_loss if gross_loss > 0 else gross_profit
            win_rate = (winners/total_trades*100) if total_trades > 0 else 0
            net_profit = balance - 1_000_000
            return_pct = net_profit / 1_000_000 * 100
            
            results.append({
                'sl': sl_pct, 'tp': tp_pct, 'trail': trail_pct,
                'net_pnl': net_profit, 'return': return_pct,
                'trades': total_trades, 'wins': winners, 'losses': losers,
                'wr': win_rate, 'pf': profit_factor, 'dd': max_dd
            })
            
            done += 1
            if done % 20 == 0:
                print(f"  Progress: {done}/{total}")

# Sort by profit factor
results.sort(key=lambda r: -r['pf'])

print(f"\n{'='*80}")
print(f"  OPTIMIZATION RESULTS — Sorted by Profit Factor")
print(f"{'='*80}")
print(f"  {'SL':>4} {'TP':>4} {'Trail':>5} {'Trades':>6} {'W/L':>7} {'WR':>5} {'Profit':>10} {'Return':>7} {'PF':>5} {'DD':>5}")
print(f"  {'-'*4} {'-'*4} {'-'*5} {'-'*6} {'-'*7} {'-'*5} {'-'*10} {'-'*7} {'-'*5} {'-'*5}")

for r in results[:15]:
    wl = f"{r['wins']}/{r['losses']}"
    print(f"  {r['sl']:>4.0f} {r['tp']:>4.0f} {r['trail']:>5.1f} {r['trades']:>6} {wl:>7} {r['wr']:>4.0f}% {r['net_pnl']:>9,}¥ {r['return']:>+5.0f}% {r['pf']:>4.1f} {r['dd']:>4.1f}%")

print(f"\n{'='*80}")
print(f"  TOP 3 RECOMMENDATIONS:")
print()

for i in range(min(3, len(results))):
    r = results[i]
    print(f"  #{i+1}: SL={r['sl']:.0f}% | TP={r['tp']:.0f}% | Trail={r['trail']:.0f}%")
    print(f"       Trades: {r['trades']} ({r['wins']}W/{r['losses']}L) | WR: {r['wr']:.0f}%")
    print(f"       P&L: ¥{r['net_pnl']:+,.0f} ({r['return']:+.0f}%) | PF: {r['pf']:.1f} | DD: {r['dd']:.1f}%")
    print()

# Save results
with open(r'C:\Users\decni\projects\mql-bots\optimization_results.txt', 'w') as f:
    for r in results:
        f.write(f"{r['sl']},{r['tp']},{r['trail']},{r['trades']},{r['wins']},{r['losses']},{r['wr']:.1f},{r['net_pnl']:.0f},{r['pf']:.2f},{r['dd']:.1f}\n")

print("Results saved to optimization_results.txt")
