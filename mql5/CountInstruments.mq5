//+------------------------------------------------------------------+
//|                                          CountInstruments.mq5    |
//| MT5 counterpart of mql4/CountInstruments.mq4. Counts symbols     |
//| with SYMBOL_TRADE_MODE == SYMBOL_TRADE_MODE_FULL and writes      |
//| count.json + done.flag to <data_dir>/MQL5/Files/.                 |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

int OnInit() {
   EventSetTimer(2);
   Print("CountInstruments: OnInit, timer armed");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTimer() {
   static int retries = 60; // 60 * 2s = 2 min budget for symbols list
   static bool wrote = false;
   if (wrote) return;

   int total = SymbolsTotal(false); // false = all known symbols
   if (total == 0 && retries > 0) {
      retries--;
      Print("CountInstruments: SymbolsTotal=0, waiting (", retries, " retries left)");
      return;
   }

   int full = 0;
   int checked = 0;
   for (int i = 0; i < total; i++) {
      string name = SymbolName(i, false);
      if (StringLen(name) == 0) continue;
      checked++;
      long mode = SymbolInfoInteger(name, SYMBOL_TRADE_MODE);
      if (mode == SYMBOL_TRADE_MODE_FULL) full++;
   }

   // Include the actually-logged-in account so the host can verify the
   // terminal switched accounts (and isn't showing cached symbols).
   long account = AccountInfoInteger(ACCOUNT_LOGIN);
   string json = "{\"full\": " + IntegerToString(full)
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
