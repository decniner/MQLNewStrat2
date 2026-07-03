import os

bots = [
    ("BTCJPY_LowDDWithBoS.mq5", "LowDD + Break of Structure"),
    ("BTCJPY_HybridBot.mq5", "Hybrid Bot"),
    ("BTCJPY_BotEQTrailProximityArrow.mq5", "EQ Trail + Proximity Arrow"),
]

base = r"C:\Users\decni\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\DEN_EA"

for bot_name, desc in bots:
    path = os.path.join(base, bot_name)
    with open(path, 'rb') as f:
        raw = f.read()
    try:
        text = raw.decode('utf-16-le')
    except:
        text = raw.decode('utf-8', errors='replace')

    lines = text.split('\r\n')
    print(f"\n{'='*60}")
    print(f"  {bot_name}  ({desc})")
    print(f"  Lines: {len(lines)} | {len(raw)//1024}KB")
    print(f"{'='*60}")
    for line in lines[:90]:
        print(line.rstrip())
