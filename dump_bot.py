import os

# Read HybridBot source
path = r"C:\Users\decni\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\DEN_EA\BTCJPY_HybridBot.mq5"
with open(path, 'rb') as f:
    raw = f.read()
text = raw.decode('utf-16-le')
print(text)
