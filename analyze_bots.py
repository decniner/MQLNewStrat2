import os

bots = [
    "BTCJPY_QuantumKingv1.2.mq5",
    "BTCJPY_LowDDWithBoS.mq5", 
    "BTCJPY_HybridBot.mq5",
    "BTCJPY_BotEQTrailProximityArrow.mq5",
    "BTCJPY_BotEQTrailv2.mq5",
    "BTCJPY_BotMultiv2.mq5",
]

base = r"C:\Users\decni\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\DEN_EA"

for bot in bots:
    path = os.path.join(base, bot)
    with open(path, 'rb') as f:
        raw = f.read()
    try:
        text = raw.decode('utf-16-le')
    except:
        text = raw.decode('utf-8', errors='replace')
    
    lines = text.splitlines()
    
    # Extract key info
    version = ""
    strategy = ""
    inputs = []
    for line in lines:
        if '#property version' in line:
            version = line.strip()
        if 'Mean-Reversion' in line or 'Grid' in line or 'Trail' in line or 'Proximity' in line or 'Hybrid' in line or 'Break' in line:
            strategy = line.strip() if not strategy else strategy
    
    # Get input parameters
    in_inputs = False
    for line in lines:
        if 'INPUT PARAMETERS' in line:
            in_inputs = True
            continue
        if in_inputs and 'GLOBALS' in line:
            break
        if in_inputs and ('input ' in line):
            inputs.append(line.strip())
    
    print(f"\n{'='*60}")
    print(f"📁 {bot}")
    print(f"   Size: {len(raw)//1024}KB | Lines: {len(lines)}")
    print(f"   {strategy[:80]}")
    print(f"   Key inputs:")
    for inp in inputs[:15]:
        print(f"     {inp}")
