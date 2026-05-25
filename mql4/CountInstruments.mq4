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

// We don't rely on ticks: if the terminal is not connected yet (or is on a
// dead symbol), OnTick never fires and the host script times out waiting
// for done.flag. Use OnTimer to poll every 2 seconds — once the symbols
// list is populated, do the count and write the result file.

int OnInit() {
   EventSetTimer(2);
   Print("CountInstruments: OnInit, timer armed");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTimer() {
   static int retries = 60; // 60 * 2s = 2 min max
   static bool wrote = false;
   if (wrote) return;

   int total = SymbolsTotal(false); // false = every available symbol
   if (total == 0 && retries > 0) {
      retries--;
      Print("CountInstruments: SymbolsTotal=0, waiting (", retries, " retries left)");
      return;
   }

   int allowed = 0;
   int checked = 0;
   for (int i = 0; i < total; i++) {
      string name = SymbolName(i, false);
      if (StringLen(name) == 0) continue;
      checked++;
      int v = (int)MarketInfo(name, MODE_TRADEALLOWED);
      if (v == 1) allowed++;
   }

   // Include the actually-logged-in account so the host can verify login.
   int account = (int)AccountNumber();
   string json = "{\"full\": " + IntegerToString(allowed)
               + ", \"total\": " + IntegerToString(checked)
               + ", \"account\": " + IntegerToString(account) + "}";

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

   wrote = true;
   EventKillTimer();
}
