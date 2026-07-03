import os, re

# Read the MQL5 file (UTF-16 LE encoded)
path = r"C:\Users\decni\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\DEN_EA\BTCJPY_QuantumKingv1.2.mq5"

with open(path, 'rb') as f:
    raw = f.read()

# Try UTF-16 decoding (MQL5 files are usually UTF-16 LE)
try:
    text = raw.decode('utf-16-le')
except:
    text = raw.decode('utf-8', errors='replace')

print(f"File size: {len(raw)} bytes")
print(f"Lines: {len(text.splitlines())}")
print()
print(text[:6000])
