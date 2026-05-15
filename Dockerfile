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

RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe \
    -O /root/mt5setup.exe

# ============================================================
# AGGRESSIVE MICRO SCALPER EA – FIXED 4756
# ============================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                        TickScalper_ProfitTarget  |
//|                     Closes at $0.50 profit, no stop loss        |
//+------------------------------------------------------------------+
#property copyright "Scalper for $10 Cent Account"
#property version   "5.00"
#property strict

// --- Inputs ---
input double   InpRiskPercent        = 2.0;      // Risk per trade (%)
input double   InpFixedLot           = 0.01;
input bool     InpUseAutoLot         = true;
input double   InpMaxDailyLoss       = 20.0;     // Stop after 20% daily loss
input double   InpMaxDrawdown        = 30.0;

input int      InpFastMA             = 10;
input int      InpSlowMA             = 30;
input int      InpRSIPeriod          = 7;
input int      InpRSIOverbought      = 65;
input int      InpRSIOversold        = 35;

input double   InpTakeProfitPips     = 0.0;      // Not used (profit target in USD)
input double   TargetProfitUSD       = 0.50;     // Close position when profit reaches this amount (USD)

input bool     InpUseTrailing        = false;    // Trailing stop disabled (profit target works instead)
input int      InpTrailingStart      = 5;
input int      InpTrailingStep       = 3;

input int      InpMagicNumber        = 20251001;
input int      InpSlippage           = 20;
input bool     InpPrintLog           = true;

// --- Globals ---
int            fastMAHandle, slowMAHandle, rsiHandle;
double         fastMA[], slowMA[], rsi[];
int            expertMagic;
string         symbol;
double         pointValue, pipValue;
double         dailyStartingBalance;
bool           isTradingPaused = false;
bool           drawdownLimitHit = false;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   symbol = Symbol();
   expertMagic = InpMagicNumber;
   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);
   pipValue = pointValue * 10;       // for 5-digit brokers
   dailyStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   fastMAHandle = iMA(symbol, PERIOD_M1, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(symbol, PERIOD_M1, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle    = iRSI(symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   
   if(fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
      return INIT_FAILED;
   
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(rsi, true);
   
   Print("Tick Scalper (Profit Target $", TargetProfitUSD, ") started on ", symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE) IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE) IndicatorRelease(slowMAHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   Print("EA removed. Final balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
}

//+------------------------------------------------------------------+
//| OnTick – trades on every tick                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Safety checks ---
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE)) return;
   if(drawdownLimitHit) return;
   if(CheckDailyLossLimit()) return;
   if(CheckDrawdownLimit()) return;
   
   // --- Close profitable positions at target ---
   CheckAndCloseProfitablePositions();
   
   // --- Update indicators ---
   if(!UpdateIndicators()) return;
   
   double fast = fastMA[0];
   double slow = slowMA[0];
   double rsiVal = rsi[0];
   
   bool uptrend = (fast > slow);
   bool downtrend = (fast < slow);
   
   bool buySignal = false;
   bool sellSignal = false;
   
   // Loose entry conditions
   if(uptrend)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(bid > fastMA[0] || rsiVal < InpRSIOverbought)
         buySignal = true;
   }
   else
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(bid > fastMA[0] && rsiVal < InpRSIOverbought)
         buySignal = true;
   }
   
   if(downtrend)
   {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(ask < fastMA[0] || rsiVal > InpRSIOversold)
         sellSignal = true;
   }
   else
   {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(ask < fastMA[0] && rsiVal > InpRSIOversold)
         sellSignal = true;
   }
   
   // Execute only one position at a time
   if(buySignal && CountOpenPositions() == 0)
      OpenBuy();
   if(sellSignal && CountOpenPositions() == 0)
      OpenSell();
   
   // Optional trailing stop (disabled by default, but kept for compatibility)
   if(InpUseTrailing)
      ManageTrailingStops();
}

//+------------------------------------------------------------------+
//| Open Buy – NO stop loss, only take profit target in USD         |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double lotSize = CalculateLotSize();
   if(lotSize <= 0) return;
   
   double entry = SymbolInfoDouble(symbol, SYMBOL_ASK);
   // No stop loss
   double sl = 0;
   // Take profit is not set (we close by profit target in USD)
   double tp = 0;
   
   // Auto-detect filling mode
   int fillMode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING filling;
   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;
   
   ZeroMemory(req);
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.volume = lotSize;
   req.type = ORDER_TYPE_BUY;
   req.price = entry;
   req.sl = sl;
   req.tp = tp;
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "TickScalper BUY";
   req.type_filling = filling;
   
   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
      {
         if(InpPrintLog) Print("BUY opened | Lot:", lotSize, " Entry:", entry);
      }
      else
      {
         Print("BUY rejected | retcode:", res.retcode, " comment:", res.comment);
      }
   }
   else
   {
      Print("BUY OrderSend failed, error:", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Open Sell – NO stop loss                                        |
//+------------------------------------------------------------------+
void OpenSell()
{
   double lotSize = CalculateLotSize();
   if(lotSize <= 0) return;
   
   double entry = SymbolInfoDouble(symbol, SYMBOL_BID);
   double sl = 0;
   double tp = 0;
   
   int fillMode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING filling;
   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;
   
   ZeroMemory(req);
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.volume = lotSize;
   req.type = ORDER_TYPE_SELL;
   req.price = entry;
   req.sl = sl;
   req.tp = tp;
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "TickScalper SELL";
   req.type_filling = filling;
   
   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
      {
         if(InpPrintLog) Print("SELL opened | Lot:", lotSize, " Entry:", entry);
      }
      else
      {
         Print("SELL rejected | retcode:", res.retcode, " comment:", res.comment);
      }
   }
   else
   {
      Print("SELL OrderSend failed, error:", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Close any position with profit >= TargetProfitUSD               |
//+------------------------------------------------------------------+
void CheckAndCloseProfitablePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol || PositionGetInteger(POSITION_MAGIC) != expertMagic)
         continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);  // Profit in account currency (USD for cent accounts)
      if(profit >= TargetProfitUSD)
      {
         // Close this position
         ClosePosition(ticket);
         if(InpPrintLog) Print("Closed profitable position | Ticket:", ticket, " Profit: $", profit);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size (unchanged)                                  |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double lot = InpFixedLot;
   if(InpUseAutoLot && InpRiskPercent > 0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * InpRiskPercent / 100.0;
      // Use a fixed stop loss distance for risk calculation (e.g., 10 pips)
      double stopPips = 10.0;
      double slDistance = stopPips * pipValue;
      double tickVal = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSiz = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double slTicks = slDistance / tickSiz;
      if(slTicks > 0 && tickVal > 0)
      {
         lot = riskAmount / (slTicks * tickVal);
         double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
         if(step > 0) lot = MathFloor(lot / step) * step;
      }
   }
   
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot || lot <= 0) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   double maxAllowed = AccountInfoDouble(ACCOUNT_BALANCE) / 200.0;
   if(lot > maxAllowed) lot = maxAllowed;
   
   lot = NormalizeDouble(lot, 2);
   if(lot < minLot) lot = minLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Count own positions                                             |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == expertMagic)
         cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| Manage trailing stops (optional, disabled by default)           |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol || PositionGetInteger(POSITION_MAGIC) != expertMagic)
         continue;
      
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      int typ = (int)PositionGetInteger(POSITION_TYPE);
      double price, newSL;
      
      if(typ == POSITION_TYPE_BUY)
      {
         price = SymbolInfoDouble(symbol, SYMBOL_BID);
         double profitPips = (price - open) / pipValue;
         if(profitPips >= InpTrailingStart)
         {
            newSL = price - InpTrailingStep * pipValue;
            if(newSL > sl && sl != 0) ModifyStopLoss(t, newSL);
         }
      }
      else
      {
         price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double profitPips = (open - price) / pipValue;
         if(profitPips >= InpTrailingStart)
         {
            newSL = price + InpTrailingStep * pipValue;
            if((newSL < sl || sl == 0) && sl != 0) ModifyStopLoss(t, newSL);
         }
      }
   }
}

void ModifyStopLoss(ulong ticket, double newSL)
{
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol = symbol;
   req.sl = newSL;
   req.tp = PositionGetDouble(POSITION_TP);
   req.magic = expertMagic;
   if(!OrderSend(req, res))
      Print("Trail modify error: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Update indicators                                               |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(fastMAHandle, 0, 0, 2, fastMA) < 2) return false;
   if(CopyBuffer(slowMAHandle, 0, 0, 2, slowMA) < 2) return false;
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Close position (used by profit target and drawdown)             |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = symbol;
   req.volume = PositionGetDouble(POSITION_VOLUME);
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "Close profit target or drawdown";
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      req.type = ORDER_TYPE_SELL;
   else
      req.type = ORDER_TYPE_BUY;
   req.price = (req.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   if(!OrderSend(req, res))
      Print("Close error: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Daily loss & drawdown limits (unchanged)                        |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct = (dailyStartingBalance - curBal) / dailyStartingBalance * 100;
   if(lossPct >= InpMaxDailyLoss)
   {
      if(!isTradingPaused) Print("Daily loss limit reached – trading paused");
      isTradingPaused = true;
      return true;
   }
   MqlDateTime dt;
   TimeCurrent(dt);
   static int lastDay = dt.day;
   if(dt.day != lastDay)
   {
      dailyStartingBalance = curBal;
      lastDay = dt.day;
      isTradingPaused = false;
   }
   return false;
}

bool CheckDrawdownLimit()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = (bal - eq) / bal * 100;
   if(dd >= InpMaxDrawdown && !drawdownLimitHit)
   {
      Print("Drawdown limit hit – closing all positions");
      drawdownLimitHit = true;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == expertMagic)
            ClosePosition(t);
      }
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+

# ============================================================
# ENTRYPOINT SCRIPT
# ============================================================
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

if [ ! -f "$MT5_EXE" ]; then
    wine /root/mt5setup.exe /auto
    sleep 90
fi

wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)

if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

mkdir -p "$DATA_DIR/Experts"

cp /root/VALETAX_TICK_BOT_V16.mq5 \
   "$DATA_DIR/Experts/"

METAEDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"

if [ -f "$METAEDITOR" ]; then
    wine "$METAEDITOR" \
    /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" \
    /log:"/root/compile.log"

    echo "Compilation log:"
    cat /root/compile.log
else
    echo "metaeditor64.exe not found. EA not compiled."
fi

python3 -m mt5linux \
    --host 0.0.0.0 \
    --port 8001 &

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
