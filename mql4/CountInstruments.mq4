//+------------------------------------------------------------------+
//|                                          CountInstruments.mq4    |
//| Counts symbols by trade-allowed flag and dumps a per-symbol list. |
//|                                                                   |
//| Writes to <data_dir>/MQL4/Files/:                                 |
//|   count.json   - summary counts + logged-in account               |
//|   symbols.csv  - every symbol: name,trade_allowed,in_market_watch |
//|   done.flag    - signal for the host PowerShell                   |
//|                                                                   |
//| NB: MT4 has no TRADE_FULL vs TRADE_CLOSE_ONLY distinction; the    |
//| closest signal is MarketInfo(name, MODE_TRADEALLOWED) == 1.       |
//+------------------------------------------------------------------+
#property strict

int OnInit() {
   EventSetTimer(2);
   Print("CountInstruments: OnInit, timer armed");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTimer() {
   static int retries = 60;
   static bool wrote = false;
   if (wrote) return;

   int total = SymbolsTotal(false); // all available symbols
   if (total == 0 && retries > 0) {
      retries--;
      Print("CountInstruments: SymbolsTotal=0, waiting (", retries, " retries left)");
      return;
   }

   // Cache Market Watch (selected) symbol names.
   int mwTotal = SymbolsTotal(true);
   string mwNames[];
   ArrayResize(mwNames, mwTotal);
   for (int j = 0; j < mwTotal; j++) mwNames[j] = SymbolName(j, true);

   int allowedAll = 0;
   int allowedMw  = 0;

   int h = FileOpen("symbols.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h != INVALID_HANDLE)
      FileWriteString(h, "symbol,trade_allowed,in_market_watch\r\n");

   for (int i = 0; i < total; i++) {
      string name = SymbolName(i, false);
      if (StringLen(name) == 0) continue;
      int allowed = (int)MarketInfo(name, MODE_TRADEALLOWED);

      bool inMw = false;
      for (int k = 0; k < mwTotal; k++) {
         if (mwNames[k] == name) { inMw = true; break; }
      }

      if (allowed == 1) {
         allowedAll++;
         if (inMw) allowedMw++;
      }
      if (h != INVALID_HANDLE)
         FileWriteString(h, name + "," + IntegerToString(allowed) + "," + (inMw ? "1" : "0") + "\r\n");
   }
   if (h != INVALID_HANDLE) FileClose(h);

   int account = (int)AccountNumber();
   string json = "{\"full\": " + IntegerToString(allowedAll)
               + ", \"total\": " + IntegerToString(total)
               + ", \"full_marketwatch\": " + IntegerToString(allowedMw)
               + ", \"total_marketwatch\": " + IntegerToString(mwTotal)
               + ", \"account\": " + IntegerToString(account) + "}";

   int hj = FileOpen("count.json", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (hj != INVALID_HANDLE) {
      FileWriteString(hj, json);
      FileClose(hj);
      Print("CountInstruments: wrote ", json);
   } else {
      Print("CountInstruments: FileOpen(count.json) failed, error=", GetLastError());
   }

   int hd = FileOpen("done.flag", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (hd != INVALID_HANDLE) {
      FileWriteString(hd, "1");
      FileClose(hd);
   } else {
      Print("CountInstruments: FileOpen(done.flag) failed, error=", GetLastError());
   }

   wrote = true;
   EventKillTimer();
}
