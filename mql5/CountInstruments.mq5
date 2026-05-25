//+------------------------------------------------------------------+
//|                                          CountInstruments.mq5    |
//| Counts symbols by trade mode and dumps a per-symbol list so the  |
//| host can see exactly what is being counted.                       |
//|                                                                   |
//| Writes to <data_dir>/MQL5/Files/:                                 |
//|   count.json   - summary counts + logged-in account               |
//|   symbols.csv  - every symbol: name,trade_mode,in_market_watch    |
//|   done.flag    - signal for the host PowerShell                   |
//+------------------------------------------------------------------+
#property strict
#property version "1.20"

string TradeModeText(long m) {
   switch ((int)m) {
      case SYMBOL_TRADE_MODE_DISABLED:  return "DISABLED";
      case SYMBOL_TRADE_MODE_LONGONLY:  return "LONGONLY";
      case SYMBOL_TRADE_MODE_SHORTONLY: return "SHORTONLY";
      case SYMBOL_TRADE_MODE_CLOSEONLY: return "CLOSEONLY";
      case SYMBOL_TRADE_MODE_FULL:      return "FULL";
   }
   return "UNKNOWN";
}

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

   int total = SymbolsTotal(false); // all symbols in the broker tree
   if (total == 0 && retries > 0) {
      retries--;
      Print("CountInstruments: SymbolsTotal=0, waiting (", retries, " retries left)");
      return;
   }

   int mwTotal = SymbolsTotal(true); // Market Watch (selected) symbols only

   int fullAll = 0;     // FULL across the whole tree
   int fullMw  = 0;     // FULL among Market Watch symbols
   int cntClose = 0, cntDisabled = 0, cntLong = 0, cntShort = 0;

   int h = FileOpen("symbols.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h != INVALID_HANDLE)
      FileWriteString(h, "symbol,trade_mode,in_market_watch,category\r\n");

   for (int i = 0; i < total; i++) {
      string name = SymbolName(i, false);
      if (StringLen(name) == 0) continue;
      long mode = SymbolInfoInteger(name, SYMBOL_TRADE_MODE);
      bool selected = (bool)SymbolInfoInteger(name, SYMBOL_SELECT);
      switch ((int)mode) {
         case SYMBOL_TRADE_MODE_FULL:      fullAll++; if (selected) fullMw++; break;
         case SYMBOL_TRADE_MODE_CLOSEONLY: cntClose++; break;
         case SYMBOL_TRADE_MODE_DISABLED:  cntDisabled++; break;
         case SYMBOL_TRADE_MODE_LONGONLY:  cntLong++; break;
         case SYMBOL_TRADE_MODE_SHORTONLY: cntShort++; break;
      }
      // SYMBOL_PATH is the category tree, e.g. "Forex\Majors\EURUSD".
      // Strip the trailing symbol to leave just the category folder.
      string path = SymbolInfoString(name, SYMBOL_PATH);
      int slash = StringLen(path) - 1;
      while (slash >= 0 && StringGetCharacter(path, slash) != '\\') slash--;
      string category = (slash > 0) ? StringSubstr(path, 0, slash) : path;
      if (h != INVALID_HANDLE)
         FileWriteString(h, name + "," + TradeModeText(mode) + "," + (selected ? "1" : "0") + "," + category + "\r\n");
   }
   if (h != INVALID_HANDLE) FileClose(h);

   long account = AccountInfoInteger(ACCOUNT_LOGIN);
   string json = "{\"full\": " + IntegerToString(fullAll)
               + ", \"total\": " + IntegerToString(total)
               + ", \"closeonly\": " + IntegerToString(cntClose)
               + ", \"disabled\": " + IntegerToString(cntDisabled)
               + ", \"longonly\": " + IntegerToString(cntLong)
               + ", \"shortonly\": " + IntegerToString(cntShort)
               + ", \"full_marketwatch\": " + IntegerToString(fullMw)
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
