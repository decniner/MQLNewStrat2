import sys, os, time

# Clean up conflicting paths
sys.path = [p for p in sys.path if 'hermes-agent' not in p.lower() and 'venv' not in p.lower()]

import MetaTrader5 as mt5

# Kill any existing MT5 instances
os.system('taskkill /F /IM terminal64.exe 2>nul')
time.sleep(2)

# Initialize MT5
if not mt5.initialize(path=r'C:\Program Files\MetaTrader 5\terminal64.exe'):
    print(f'FAILED: {mt5.last_error()}')
    exit(1)

print('MT5 initialized')

# Try XM demo servers
servers = [
    'XMGlobal-MT5',      'XM.com-MT5 5',
    'XM Global-MT5',     'XMStandard-MT5 5',
    'XMStandard-MT5',    'XMGlobal-MT5 5',
    'XMTrading-MT5',     'XMTrading-MT5 5',
    'xmttrading-mt5',    'XMTrading-MT5 3',
    'XM.com-MT5',
]

for server in servers:
    result = mt5.demo_account_create(
        server=server,
        login=0,
        password='Den2026Demo!',
        email='decniner@gmail.com',
        leverage=500,
        deposit=1000000,
        currency='JPY',
    )
    
    if result is not None:
        print(f'✅ SUCCESS on server: {server}')
        print(f'   Login:     {result.login}')
        print(f'   Server:    {result.server}')
        print(f'   Balance:   ¥{result.balance:,.0f}')
        print(f'   Leverage:  1:{result.leverage}')
        print(f'   Currency:  {result.currency}')
        print(f'   Password:  Den2026Demo!')
        
        # Switch to this account
        if mt5.login(result.login, password='Den2026Demo!', server=server):
            print(f'✅ Logged in to demo account')
        break
    else:
        err = mt5.last_error()
        print(f'   {server}: {err}')

mt5.shutdown()
