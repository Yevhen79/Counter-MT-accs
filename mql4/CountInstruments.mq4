//+------------------------------------------------------------------+
//|                                          CountInstruments.mq4    |
//|  Counts symbols on the current MT4 account where trading is      |
//|  allowed (MarketInfo MODE_TRADEALLOWED == 1) and writes a small  |
//|  JSON file the host PowerShell can pick up.                       |
//|                                                                   |
//|  NB: MT4's symbol API does NOT distinguish TRADE_FULL from        |
//|  TRADE_CLOSE_ONLY the way MT5 does. MODE_TRADEALLOWED == 1 is     |
//|  the closest available approximation.                              |
//+------------------------------------------------------------------+
#property strict

void OnInit() { /* placed at attach; OnTick does the work after first tick */ }

void OnTick() {
   static bool done = false;
   if (done) return;
   done = true;

   int total = SymbolsTotal(false); // false = all available symbols
   int allowed = 0;
   int checked = 0;

   for (int i = 0; i < total; i++) {
      string name = SymbolName(i, false);
      if (StringLen(name) == 0) continue;
      checked++;
      int v = (int)MarketInfo(name, MODE_TRADEALLOWED);
      if (v == 1) allowed++;
   }

   string json = StringFormat("{\"full\": %d, \"total\": %d}", allowed, checked);

   int h = FileOpen("count.json", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h != INVALID_HANDLE) {
      FileWriteString(h, json);
      FileClose(h);
      Print("CountInstruments: wrote ", json);
   } else {
      Print("CountInstruments: FileOpen(count.json) failed, error=", GetLastError());
   }

   int hdone = FileOpen("done.flag", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (hdone != INVALID_HANDLE) {
      FileWriteString(hdone, "1");
      FileClose(hdone);
   } else {
      Print("CountInstruments: FileOpen(done.flag) failed, error=", GetLastError());
   }
}
