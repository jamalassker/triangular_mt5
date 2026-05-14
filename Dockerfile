
FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# =========================================================
# V16.3 - PROFIT-MAX VELOCITY BOT (ULTRA PROFITABILITY)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                            MicroScalper_EA.mq5   |
//|                                    For $10 Cent Account Growth  |
//|                                            Realistic 10% Daily  |
//+------------------------------------------------------------------+
#property copyright "MicroScalper EA"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| INPUT PARAMETERS (Configure these before attaching to chart)    |
//+------------------------------------------------------------------+

// --- Lot Size & Risk Management ---
input double   InpRiskPercent        = 2.0;      // Risk per trade (% of balance)
input double   InpFixedLot           = 0.01;     // Fixed lot size (if RiskPercent=0)
input bool     InpUseAutoLot         = true;     // Use automatic lot sizing
input double   InpMaxDailyLoss       = 10.0;     // Max daily loss (%) - stops trading
input double   InpMaxDrawdown        = 15.0;     // Max total drawdown (%) - emergency stop

// --- Entry Conditions (EMA + RSI) ---
input int      InpFastEMA            = 20;       // Fast EMA period
input int      InpSlowEMA            = 50;       // Slow EMA period
input int      InpRSIPeriod          = 14;       // RSI period
input int      InpRSIOverbought      = 70;       // RSI overbought level
input int      InpRSIOversold        = 30;       // RSI oversold level
input int      InpATRPeriod          = 14;       // ATR period for dynamic stops

// --- Stop Loss & Take Profit ---
input double   InpATRMultiplierSL    = 1.5;      // Stop Loss = ATR * multiplier
input double   InpATRMultiplierTP    = 2.0;      // Take Profit = ATR * multiplier
input bool     InpUseTrailing        = true;     // Enable trailing stop
input int      InpTrailingStart      = 20;       // Trailing activates after X pips profit
input int      InpTrailingStep       = 10;       // Trail distance in pips

// --- Trading Session ---
input bool     InpUseSessionFilter   = true;     // Restrict trading to specific hours
input int      InpSessionStartHour   = 8;        // Session start (broker time)
input int      InpSessionEndHour     = 17;       // Session end (broker time)
input bool     InpAvoidNews          = true;     // Pause trading during high-impact news
input int      InpNewsMinutesBefore  = 30;       // Minutes before news to pause
input int      InpNewsMinutesAfter   = 30;       // Minutes after news to resume

// --- General Settings ---
input int      InpMagicNumber        = 20251001; // Unique EA identifier
input int      InpSlippage           = 10;       // Allowed slippage in points
input bool     InpPrintLog           = true;     // Enable debug logging

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
int            emaFastHandle, emaSlowHandle, rsiHandle, atrHandle;
double         emaFast[], emaSlow[], rsi[], atr[];
int            expertMagic;
string         expertSymbol;
double         pointValue, tickSize;
datetime       lastBarTime;
double         dailyStartingBalance;
bool           isTradingPaused = false;
bool           drawdownLimitHit = false;
datetime       lastNewsCheck = 0;
string         newsTimes[];  // Will be populated from economic calendar

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   expertSymbol = Symbol();
   expertMagic = InpMagicNumber;
   pointValue = SymbolInfoDouble(expertSymbol, SYMBOL_POINT);
   tickSize = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_SIZE);
   lastBarTime = iTime(expertSymbol, PERIOD_M5, 0);
   dailyStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Initialize indicator handles
   emaFastHandle = iMA(expertSymbol, PERIOD_M5, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(expertSymbol, PERIOD_M5, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(expertSymbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   atrHandle = iATR(expertSymbol, PERIOD_M5, InpATRPeriod);
   
   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }
   
   // Set arrays as series for proper indexing
      ArraySetAsSeries(emaFast, true);
      ArraySetAsSeries(emaSlow, true);
      ArraySetAsSeries(rsi, true);
      ArraySetAsSeries(atr, true);
   
   if(InpPrintLog) Print("MicroScalper EA initialized on ", expertSymbol, " | Magic: ", expertMagic);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   
   if(InpPrintLog) Print("MicroScalper EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function - Main logic                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Safety Checks ---
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!SymbolInfoBoolean(expertSymbol, SYMBOL_TRADE_MODE)) return;
   if(drawdownLimitHit) return;
   
   // --- Daily Loss Limit Check ---
   if(CheckDailyLossLimit()) return;
   
   // --- Drawdown Protection Check ---
   if(CheckDrawdownLimit()) return;
   
   // --- News Filter (if enabled) ---
   if(InpAvoidNews && IsNewsTime()) return;
   
   // --- Session Filter (if enabled) ---
   if(InpUseSessionFilter && !IsTradingSession()) return;
   
   // --- Only trade on new bar to avoid multiple entries per candle ---
   datetime currentBarTime = iTime(expertSymbol, PERIOD_M5, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;
   
   // --- Update indicator data ---
   if(!UpdateIndicatorData()) return;
   
   // --- Get current indicator values ---
   double fastEMA = emaFast[0];
   double slowEMA = emaSlow[0];
   double rsiValue = rsi[0];
   double atrValue = atr[0];
   
   // --- Determine Market State ---
   int trend = DetermineTrend(fastEMA, slowEMA);
   
   // --- Skip trading in chop ---
   if(trend == 0) return;
   
   // --- Signal Generation ---
   bool buySignal = false;
   bool sellSignal = false;
   
   if(trend == 1)  // Uptrend
   {
      // Price near EMA (pullback) + RSI leaving oversold + momentum confirms
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
      double emaDistance = MathAbs(price - fastEMA) / pointValue;
      
      if(emaDistance <= atrValue / pointValue &&        // Price within 1 ATR of EMA
         rsiValue > InpRSIOversold && rsiValue < 50 && // RSI recovering from oversold
         rsi[1] < rsi[0])                              // RSI rising momentum
      {
         buySignal = true;
      }
   }
   else if(trend == -1)  // Downtrend
   {
      // Price near EMA (pullback) + RSI leaving overbought + momentum confirms
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
      double emaDistance = MathAbs(price - fastEMA) / pointValue;
      
      if(emaDistance <= atrValue / pointValue &&        // Price within 1 ATR of EMA
         rsiValue < InpRSIOverbought && rsiValue > 50 &&// RSI falling from overbought
         rsi[1] > rsi[0])                              // RSI falling momentum
      {
         sellSignal = true;
      }
   }
   
   // --- Execute Trades ---
   if(buySignal && CountOpenPositions(ORDER_TYPE_BUY) == 0)
   {
      OpenBuy(atrValue);
   }
   else if(sellSignal && CountOpenPositions(ORDER_TYPE_SELL) == 0)
   {
      OpenSell(atrValue);
   }
   
   // --- Manage existing positions (Trailing Stop) ---
   if(InpUseTrailing)
   {
      ManageTrailingStops();
   }
}

//+------------------------------------------------------------------+
//| Determine trend direction using EMA cross                        |
//+------------------------------------------------------------------+
int DetermineTrend(double fastEMA, double slowEMA)
{
   double emaDiff = fastEMA - slowEMA;
   double pointToPip = pointValue * 10;
   double threshold = pointToPip;  // Minimum ATR-based threshold to filter chop
   
   if(MathAbs(emaDiff) < threshold) return 0;   // Chop/ranging
   if(fastEMA > slowEMA) return 1;              // Uptrend
   if(fastEMA < slowEMA) return -1;             // Downtrend
   return 0;
}

//+------------------------------------------------------------------+
//| Open a Buy position                                              |
//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
{
   double lotSize = CalculateLotSize(atrValue, ORDER_TYPE_BUY);
   if(lotSize <= 0) return;
   
   double entry = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
   double sl = entry - (atrValue * InpATRMultiplierSL);
   double tp = entry + (atrValue * InpATRMultiplierTP);
   
   // Enforce broker minimum stop distance
   long stopsLevel = SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * pointValue;
   
   if(entry - sl < minStopDistance)
      sl = entry - minStopDistance;
   if(tp - entry < minStopDistance)
      tp = entry + minStopDistance;
   
   // Create trade request
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = expertSymbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = entry;
   request.sl = sl;
   request.tp = tp;
   request.deviation = InpSlippage;
   request.magic = expertMagic;
   request.comment = "MicroScalper BUY";
   request.type_filling = ORDER_FILLING_FOK;
   
   if(OrderSend(request, result))
   {
      if(InpPrintLog) Print("BUY opened | Lot: ", lotSize, " | Entry: ", entry, 
                            " | SL: ", sl, " | TP: ", tp);
   }
   else
   {
      Print("BUY order failed: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| Open a Sell position                                             |
//+------------------------------------------------------------------+
void OpenSell(double atrValue)
{
   double lotSize = CalculateLotSize(atrValue, ORDER_TYPE_SELL);
   if(lotSize <= 0) return;
   
   double entry = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
   double sl = entry + (atrValue * InpATRMultiplierSL);
   double tp = entry - (atrValue * InpATRMultiplierTP);
   
   // Enforce broker minimum stop distance
   long stopsLevel = SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * pointValue;
   
   if(sl - entry < minStopDistance)
      sl = entry + minStopDistance;
   if(entry - tp < minStopDistance)
      tp = entry - minStopDistance;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = expertSymbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = entry;
   request.sl = sl;
   request.tp = tp;
   request.deviation = InpSlippage;
   request.magic = expertMagic;
   request.comment = "MicroScalper SELL";
   request.type_filling = ORDER_FILLING_FOK;
   
   if(OrderSend(request, result))
   {
      if(InpPrintLog) Print("SELL opened | Lot: ", lotSize, " | Entry: ", entry,
                            " | SL: ", sl, " | TP: ", tp);
   }
   else
   {
      Print("SELL order failed: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage or fixed lot        |
//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue, int orderType)
{
   double lotSize = InpFixedLot;
   
   if(InpUseAutoLot && InpRiskPercent > 0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * (InpRiskPercent / 100.0);
      
      double slDistance;
      if(orderType == ORDER_TYPE_BUY)
         slDistance = atrValue * InpATRMultiplierSL;
      else
         slDistance = atrValue * InpATRMultiplierSL;
      
      double tickValue = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_SIZE);
      
      // Convert stop loss distance to ticks
      double slTicks = slDistance / tickSize;
      
      if(slTicks > 0 && tickValue > 0)
      {
         lotSize = riskAmount / (slTicks * tickValue);
         // Round to allowed lot step
         double lotStep = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_STEP);
         lotSize = MathFloor(lotSize / lotStep) * lotStep;
      }
   }
   
   // Safety limits
   double minLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MAX);
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   // Enforce maximum lot for account protection
   double maxAllowedLot = AccountInfoDouble(ACCOUNT_BALANCE) / 500.0;
   lotSize = MathMin(lotSize, maxAllowedLot);
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                 |
//+------------------------------------------------------------------+
int CountOpenPositions(int orderType = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == expertSymbol &&
            PositionGetInteger(POSITION_MAGIC) == expertMagic)
         {
            if(orderType == -1)
               count++;
            else if((int)PositionGetInteger(POSITION_TYPE) == orderType)
               count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Manage trailing stops for all open positions                    |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != expertSymbol ||
         PositionGetInteger(POSITION_MAGIC) != expertMagic)
         continue;
      
      double positionOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentPrice;
      double newSL;
      int orderType = (int)PositionGetInteger(POSITION_TYPE);
      
      if(orderType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
         double profitPips = (currentPrice - positionOpen) / pointValue;
         
         if(profitPips >= InpTrailingStart)
         {
            newSL = currentPrice - (InpTrailingStep * pointValue);
            if(newSL > currentSL)
            {
               ModifyStopLoss(ticket, newSL);
               if(InpPrintLog) Print("Trailing SL updated for BUY #", ticket, " to ", newSL);
            }
         }
      }
      else if(orderType == POSITION_TYPE_SELL)
      {
         currentPrice = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
         double profitPips = (positionOpen - currentPrice) / pointValue;
         
         if(profitPips >= InpTrailingStart)
         {
            newSL = currentPrice + (InpTrailingStep * pointValue);
            if(newSL < currentSL || currentSL == 0)
            {
               ModifyStopLoss(ticket, newSL);
               if(InpPrintLog) Print("Trailing SL updated for SELL #", ticket, " to ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify stop loss for a position                                  |
//+------------------------------------------------------------------+
void ModifyStopLoss(ulong ticket, double newSL)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = expertSymbol;
   request.sl = newSL;
   request.tp = PositionGetDouble(POSITION_TP);
   request.magic = expertMagic;
   
   if(!OrderSend(request, result))
   {
      Print("Failed to modify SL for #", ticket, ": ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| Update indicator buffer data                                     |
//+------------------------------------------------------------------+
bool UpdateIndicatorData()
{
   if(CopyBuffer(emaFastHandle, 0, 0, 3, emaFast) < 3) return false;
   if(CopyBuffer(emaSlowHandle, 0, 0, 3, emaSlow) < 3) return false;
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsi) < 3) return false;
   if(CopyBuffer(atrHandle, 0, 0, 3, atr) < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Check if within trading session hours                           |
//+------------------------------------------------------------------+
bool IsTradingSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentHour = dt.hour;
   int currentMinute = dt.min;
   int currentTimeMinutes = currentHour * 60 + currentMinute;
   int startTimeMinutes = InpSessionStartHour * 60;
   int endTimeMinutes = InpSessionEndHour * 60;
   
   if(startTimeMinutes <= endTimeMinutes)
      return (currentTimeMinutes >= startTimeMinutes && currentTimeMinutes < endTimeMinutes);
   else
      return (currentTimeMinutes >= startTimeMinutes || currentTimeMinutes < endTimeMinutes);
}

//+------------------------------------------------------------------+
//| Simple news filter (extendable with economic calendar)          |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   // This is a simplified version. For production, integrate with MT5 Economic Calendar.
   // Current implementation avoids trading on major news days (NFP, FOMC, ECB).
   
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Skip trading on known high-impact news days (Wednesdays for FOMC, Fridays for NFP)
   // and during specific hours (14:30-16:30 server time - typical US news releases)
   int currentHour = dt.hour;
   int dayOfWeek = dt.day_of_week;
   
   // Pause 30 minutes before and after major news hours
   if((dayOfWeek == 3 && currentHour >= 13 && currentHour <= 16) ||  // Wednesday (FOMC possibility)
      (dayOfWeek == 5 && currentHour >= 12 && currentHour <= 15))     // Friday (NFP possibility)
   {
      if(InpPrintLog) Print("News filter: Trading paused due to potential high-impact news");
      return true;
   }
   
   // Also check for user-defined news times if array is populated
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(newsTimes); i++)
   {
      datetime newsTime = StringToTime(newsTimes[i]);
      if(now >= newsTime - InpNewsMinutesBefore * 60 && 
         now <= newsTime + InpNewsMinutesAfter * 60)
      {
         if(InpPrintLog) Print("News filter: Trading paused for scheduled news");
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Daily loss limit check - stops trading after max daily loss     |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLossPercent = (dailyStartingBalance - currentBalance) / dailyStartingBalance * 100;
   
   if(dailyLossPercent >= InpMaxDailyLoss)
   {
      if(!isTradingPaused)
      {
         Print("Daily loss limit reached (", DoubleToString(dailyLossPercent, 2), "%). Trading paused.");
         isTradingPaused = true;
      }
      return true;
   }
   
   // Reset daily starting balance at new day
   MqlDateTime dt;
   TimeCurrent(dt);
   static int lastResetDay = dt.day;
   if(dt.day != lastResetDay)
   {
      dailyStartingBalance = currentBalance;
      lastResetDay = dt.day;
      isTradingPaused = false;
      if(InpPrintLog) Print("Daily tracker reset. New starting balance: ", dailyStartingBalance);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Maximum drawdown limit - emergency stop                         |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdownPercent = (balance - equity) / balance * 100;
   
   if(drawdownPercent >= InpMaxDrawdown && !drawdownLimitHit)
   {
      Print("EMERGENCY: Max drawdown reached (", DoubleToString(drawdownPercent, 2), "%). Closing all positions.");
      drawdownLimitHit = true;
      
      // Close all positions for this EA
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == expertSymbol &&
               PositionGetInteger(POSITION_MAGIC) == expertMagic)
            {
               ClosePosition(ticket);
            }
         }
      }
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Close a position by ticket                                      |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = expertSymbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.deviation = InpSlippage;
   request.magic = expertMagic;
   request.comment = "Close on drawdown limit";
   
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      request.type = ORDER_TYPE_SELL;
   else
      request.type = ORDER_TYPE_BUY;
      
   request.price = (request.type == ORDER_TYPE_BUY) ? 
                   SymbolInfoDouble(expertSymbol, SYMBOL_ASK) : 
                   SymbolInfoDouble(expertSymbol, SYMBOL_BID);
   
   if(!OrderSend(request, result))
   {
      Print("Failed to close position #", ticket, ": ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| Optimized strategy logic simplified for max drawdown reduction  |
//+------------------------------------------------------------------+

EOF

# ============================================
# 3. INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
