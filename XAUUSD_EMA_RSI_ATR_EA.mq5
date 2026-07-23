//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(_Symbol != "XAUUSD" && StringFind(_Symbol,"XAUUSD") < 0)
     {
      Print("WARNING: This EA is designed for XAUUSD. Current symbol: ", _Symbol,
            ". It will still run, but SL/TP/risk logic is tuned for Gold's tick value.");
     }

   g_emaHandle = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, InpEMAPrice);
   g_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(g_emaHandle == INVALID_HANDLE || g_rsiHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handle(s). Error code: ", GetLastError());
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints((ulong)InpFixedSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   Print("XAUUSD EMA/RSI/ATR EA initialized successfully.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
  }

//+------------------------------------------------------------------+
//| Returns true only on the first tick of a new bar                 |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime != g_lastBarTime)
     {
      g_lastBarTime = currentBarTime;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Checks the native MQL5 Economic Calendar for high-impact news    |
//| within +/- InpNewsBlockMinutes of the current server time.       |
//| NOTE: Requires the terminal to have calendar data synced         |
//| (Tools > Options > Community, or broker-provided calendar feed). |
//| In Strategy Tester, calendar history must be available/enabled.  |
//+------------------------------------------------------------------+
bool IsHighImpactNewsBlackout()
  {
   if(!InpUseNewsFilter)
      return false;

   datetime now        = TimeCurrent();
   int      blockSecs  = InpNewsBlockMinutes * 60;
   datetime searchFrom  = now - blockSecs;
   datetime searchTo    = now + blockSecs;

   MqlCalendarValue values[];

   // Primary currency check (USD, since XAUUSD is priced in USD)
   bool gotValues = CalendarValueHistory(values, searchFrom, searchTo, NULL, InpNewsCurrency);

   if(gotValues)
     {
      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent evt;
         if(!CalendarEventById(values[i].event_id, evt))
            continue;

         if(evt.importance == CALENDAR_IMPORTANCE_HIGH)
           {
            datetime newsTime = values[i].time;
            long diffSeconds  = (long)MathAbs((long)(now - newsTime));
            if(diffSeconds <= blockSecs)
              {
               Print("News blackout active: High-impact ", InpNewsCurrency,
                     " event '", evt.name, "' at ", TimeToString(newsTime, TIME_DATE|TIME_MINUTES));
               return true;
              }
           }
        }
     }

   // Optional secondary check for Gold-specific calendar tags (some brokers tag "XAU" events)
   if(InpBlockGoldSpecific)
     {
      MqlCalendarValue xauValues[];
      if(CalendarValueHistory(xauValues, searchFrom, searchTo, NULL, "XAU"))
        {
         for(int i = 0; i < ArraySize(xauValues); i++)
           {
            MqlCalendarEvent evt;
            if(!CalendarEventById(xauValues[i].event_id, evt))
               continue;

            if(evt.importance == CALENDAR_IMPORTANCE_HIGH)
              {
               datetime newsTime = xauValues[i].time;
               long diffSeconds  = (long)MathAbs((long)(now - newsTime));
               if(diffSeconds <= blockSecs)
                 {
                  Print("News blackout active: High-impact XAU event '", evt.name,
                        "' at ", TimeToString(newsTime, TIME_DATE|TIME_MINUTES));
                  return true;
                 }
              }
           }
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Counts open positions for this symbol + magic number              |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Manages open positions: ATR breakeven + ATR trailing stop.       |
//| Runs on every tick (not just new bar) so SL reacts promptly.     |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakeven && !InpUseTrailing)
      return;

   // Latest ATR value (current forming bar) - used for live trade management
   double atrBuf[1];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atrBuf) < 1)
      return;
   double atrCurrent = atrBuf[0];
   if(atrCurrent <= 0)
      return;

   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double beTrigger    = atrCurrent * InpBE_Trigger_ATR_Mult;
   double trailTrigger = atrCurrent * InpTrail_Trigger_ATR_Mult;
   double trailDist    = atrCurrent * InpTrail_Distance_ATR_Mult;
   double trailStep    = atrCurrent * InpTrail_Step_ATR_Mult;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double newSL = currentSL;
      bool   wantModify = false;

      if(posType == POSITION_TYPE_BUY)
        {
         double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID); // exit price for a buy

         //--- Breakeven: move SL to entry + spread once profit >= beTrigger ---
         if(InpUseBreakeven && (currentPrice - entry) >= beTrigger)
           {
            double beSL = NormalizeDouble(entry + spread, digits);
            if(currentSL < beSL || currentSL == 0.0)
              {
               newSL = beSL;
               wantModify = true;
              }
           }

         //--- Trailing: once profit >= trailTrigger, trail SL behind price by trailDist,   |
         //--- only moving in increments of at least trailStep to avoid over-modifying     ---
         if(InpUseTrailing && (currentPrice - entry) >= trailTrigger)
           {
            double trailSL = NormalizeDouble(currentPrice - trailDist, digits);
            if(trailSL > newSL + trailStep)
              {
               newSL = trailSL;
               wantModify = true;
              }
           }

         // Never move SL backward (below the SL already set)
         if(wantModify && newSL > currentSL)
           {
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print("Position #", ticket, " (BUY) SL updated to ", newSL);
            else
               Print("Position #", ticket, " SL modify failed. Error: ", GetLastError());
           }
        }
      else
      if(posType == POSITION_TYPE_SELL)
        {
         double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // exit price for a sell

         //--- Breakeven: move SL to entry - spread once profit >= beTrigger ---
         if(InpUseBreakeven && (entry - currentPrice) >= beTrigger)
           {
            double beSL = NormalizeDouble(entry - spread, digits);
            if(currentSL > beSL || currentSL == 0.0)
              {
               newSL = beSL;
               wantModify = true;
              }
           }

         //--- Trailing: once profit >= trailTrigger, trail SL behind price by trailDist ---
         if(InpUseTrailing && (entry - currentPrice) >= trailTrigger)
           {
            double trailSL = NormalizeDouble(currentPrice + trailDist, digits);
            if(trailSL < newSL - trailStep || newSL == 0.0)
              {
               newSL = trailSL;
               wantModify = true;
              }
           }

         // Never move SL backward (above the SL already set) for a sell
         if(wantModify && (newSL < currentSL || currentSL == 0.0))
           {
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print("Position #", ticket, " (SELL) SL updated to ", newSL);
            else
               Print("Position #", ticket, " SL modify failed. Error: ", GetLastError());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Calculates lot size so that hitting the stop-loss risks exactly  |
//| InpRiskPercent of current account equity.                        |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   if(slDistancePrice <= 0)
      return 0.0;

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (InpRiskPercent / 100.0);

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
     {
      Print("ERROR: Invalid tick value/size for ", _Symbol, ". Cannot compute lot size.");
      return 0.0;
     }

   // Monetary loss for 1.0 lot if price moves slDistancePrice against the position
   double lossPerLot = (slDistancePrice / tickSize) * tickValue;

   if(lossPerLot <= 0)
      return 0.0;

   double rawLot = riskAmount / lossPerLot;

   // Normalize to broker's lot step, min, and max
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lot = MathFloor(rawLot / lotStep) * lotStep;

   // Apply safety floors/caps from inputs as well as broker limits
   lot = MathMax(lot, MathMax(lotMin, InpMinLot));
   lot = MathMin(lot, MathMin(lotMax, InpMaxLot));

   // Final sanity: if rawLot rounds to less than broker minimum, reject the trade
   if(rawLot < lotMin)
     {
      Print("WARNING: Calculated lot (", DoubleToString(rawLot,4),
            ") is below broker minimum (", DoubleToString(lotMin,2),
            "). Risk % may be too small for current SL distance/equity.");
     }

   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
//| Main entry logic: evaluates signals and opens trades              |
//+------------------------------------------------------------------+
void CheckForEntry()
  {
   // Only one open position at a time if configured
   if(InpOneTradeAtATime && CountOpenPositions() > 0)
      return;

   // Block trading around high-impact news
   if(IsHighImpactNewsBlackout())
      return;

   // --- Pull indicator data (index 1 = last CLOSED bar, index 2 = bar before that) ---
   double ema[3], rsi[3], atr[3];

   if(CopyBuffer(g_emaHandle, 0, 1, 2, ema) < 2) return;
   if(CopyBuffer(g_rsiHandle, 0, 1, 2, rsi) < 2) return;
   if(CopyBuffer(g_atrHandle, 0, 1, 2, atr) < 2) return;

   double closePrev1 = iClose(_Symbol, PERIOD_CURRENT, 1); // last closed bar
   double closePrev2 = iClose(_Symbol, PERIOD_CURRENT, 2); // bar before that

   double emaLast     = ema[1]; // EMA on last closed bar
   double rsiLast     = rsi[1]; // RSI on last closed bar
   double rsiPrev     = rsi[0]; // RSI one bar before that
   double atrLast     = atr[1]; // ATR on last closed bar

   if(atrLast <= 0) return;

   bool uptrend   = (closePrev1 > emaLast);
   bool downtrend = (closePrev1 < emaLast);

   // Pullback trigger: RSI crossing back up through oversold (buy) or down through overbought (sell)
   bool rsiBuyTrigger  = (rsiPrev < InpRSIOversold   && rsiLast >= InpRSIOversold);
   bool rsiSellTrigger = (rsiPrev > InpRSIOverbought && rsiLast <= InpRSIOverbought);

   double slDistance = atrLast * InpATR_SL_Mult;
   double tpDistance = atrLast * InpATR_TP_Mult;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- BUY: uptrend + RSI pullback recovery from oversold ---
   if(uptrend && rsiBuyTrigger)
     {
      double sl  = NormalizeDouble(ask - slDistance, digits);
      double tp  = NormalizeDouble(ask + tpDistance, digits);
      double lot = CalculateLotSize(slDistance);

      if(lot >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
        {
         if(trade.Buy(lot, _Symbol, ask, sl, tp, "EMA200+RSI14 Buy Pullback"))
            Print("BUY opened: lot=", lot, " SL=", sl, " TP=", tp, " ATR=", atrLast);
         else
            Print("BUY order failed. Error: ", GetLastError());
        }
      else
         Print("BUY signal detected but lot size too small to open (risk/SL too tight). Skipping.");

      return;
     }

   //--- SELL: downtrend + RSI pullback recovery from overbought ---
   if(downtrend && rsiSellTrigger)
     {
      double sl  = NormalizeDouble(bid + slDistance, digits);
      double tp  = NormalizeDouble(bid - tpDistance, digits);
      double lot = CalculateLotSize(slDistance);

      if(lot >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
        {
         if(trade.Sell(lot, _Symbol, bid, sl, tp, "EMA200+RSI14 Sell Pullback"))
            Print("SELL opened: lot=", lot, " SL=", sl, " TP=", tp, " ATR=", atrLast);
         else
            Print("SELL order failed. Error: ", GetLastError());
        }
      else
         Print("SELL signal detected but lot size too small to open (risk/SL too tight). Skipping.");

      return;
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Manage existing positions (breakeven / trailing) on every tick for responsiveness
   ManageOpenPositions();

   // Evaluate NEW entry signals only once per new bar close to avoid repainting/overtrading
   if(!IsNewBar())
      return;

   CheckForEntry();
  }
//+------------------------------------------------------------------+

