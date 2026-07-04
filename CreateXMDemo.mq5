//+------------------------------------------------------------------+
//|                                          CreateXMDemo.mq5        |
//|                                                  Auto-generated   |
//+------------------------------------------------------------------+
#property strict
void OnStart()
{
   // Try to create demo account on XM Trading MT5
   bool created = AccountCreate("xmttrading-mt5 3", "Den2026Demo!", "Den2026Demo!",
                                500, 1000000, "JPY", "decniner@gmail.com");
                                
   if(created)
   {
      Print("✅ XM Demo account created successfully!");
      Print("Server: xmttrading-mt5 3");
      Print("Login: Check terminal for login number");
      Print("Password: Den2026Demo!");
   }
   else
   {
      int err = GetLastError();
      Print("❌ Failed to create demo account. Error: ", err);
      Print("Server might require manual signup. Try: File → Open Account → XM");
   }
}
