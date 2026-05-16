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
//|           AI Adaptive Crypto Scalper FIXED VERSION               |
//|                BTCUSD / ETHUSD Aggressive EA                     |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"

// ================= INPUTS =================
input double RiskPercent              = 1.0;
input double FixedLot                 = 0.01;
input bool   UseAutoLot               = true;

input double ProfitCloseUSD           = 0.50;
input double EmergencyLossUSD         = -2.00;

input int    FastEMA                  = 9;
input int    SlowEMA                  = 21;

input int    RSI_Period               = 7;
input int    ATR_Period               = 14;

input int    MaxSpreadPoints          = 8000;

input double VolumeMultiplier         = 0.8;

input int    MagicNumber              = 99001;
input int    Slippage                 = 20;

input bool   EnableBuy                = true;
input bool   EnableSell               = true;

input bool   PrintLogs                = true;

// ================= GLOBALS =================
string symbol;

int fastEMAHandle;
int slowEMAHandle;
int rsiHandle;
int atrHandle;

double fastEMA[];
double slowEMA[];
double rsiBuffer[];
double atrBuffer[];

double pointValue;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   symbol = Symbol();

   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);

   fastEMAHandle = iMA(symbol, PERIOD_M1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);

   slowEMAHandle = iMA(symbol, PERIOD_M1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   rsiHandle = iRSI(symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);

   atrHandle = iATR(symbol, PERIOD_M1, ATR_Period);

   if(fastEMAHandle == INVALID_HANDLE ||
      slowEMAHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE ||
      atrHandle == INVALID_HANDLE)
   {
      return INIT_FAILED;
   }

   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(atrBuffer, true);

   Print("AI Adaptive Crypto Scalper FIXED Started on ", symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(fastEMAHandle);
   IndicatorRelease(slowEMAHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(GetSpreadPoints() > MaxSpreadPoints)
      return;

   // MANUAL PROFIT / LOSS CLOSE
   CheckProfitClose();

   if(!UpdateIndicators())
      return;

   double fast = fastEMA[0];
   double slow = slowEMA[0];

   double prevFast = fastEMA[1];

   double rsi = rsiBuffer[0];

   double slope = fast - prevFast;

   double currentVolume = iVolume(symbol, PERIOD_M1, 0);

   double avgVolume = GetAverageVolume();

   bool volumeStrong =
      currentVolume >= (avgVolume * VolumeMultiplier);

   bool buySignal = false;
   bool sellSignal = false;

   // ================= BUY =================
   if(EnableBuy)
   {
      if(
         (
            fast > slow ||
            slope > 0 ||
            rsi > 45
         )
         &&
         volumeStrong
      )
      {
         buySignal = true;
      }
   }

   // ================= SELL =================
   if(EnableSell)
   {
      if(
         (
            fast < slow ||
            slope < 0 ||
            rsi < 55
         )
         &&
         volumeStrong
      )
      {
         sellSignal = true;
      }
   }

   // FORCE ENTRIES
   if(!buySignal && !sellSignal)
   {
      if(rsi > 50)
         buySignal = true;
      else
         sellSignal = true;
   }

   // MAX 1 POSITION
   if(CountPositions() >= 1)
      return;

   if(buySignal)
      OpenBuy();

   if(sellSignal)
      OpenSell();
}

//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double lot = CalculateLotSize();

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   ENUM_ORDER_TYPE_FILLING filling;

   int fillMode =
      (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.magic        = MagicNumber;
   req.type         = ORDER_TYPE_BUY;
   req.volume       = lot;
   req.price        = ask;

   // IMPORTANT FIX
   req.sl           = 0;
   req.tp           = 0;

   req.deviation    = Slippage;
   req.type_filling = filling;
   req.comment      = "AI BUY";

   if(OrderSend(req, res))
   {
      Print("BUY OPENED | Lot: ", lot);
   }
   else
   {
      Print("BUY FAILED | Retcode: ",
            res.retcode,
            " | Comment: ",
            res.comment);
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL                                                        |
//+------------------------------------------------------------------+
void OpenSell()
{
   double lot = CalculateLotSize();

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   ENUM_ORDER_TYPE_FILLING filling;

   int fillMode =
      (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.magic        = MagicNumber;
   req.type         = ORDER_TYPE_SELL;
   req.volume       = lot;
   req.price        = bid;

   // IMPORTANT FIX
   req.sl           = 0;
   req.tp           = 0;

   req.deviation    = Slippage;
   req.type_filling = filling;
   req.comment      = "AI SELL";

   if(OrderSend(req, res))
   {
      Print("SELL OPENED | Lot: ", lot);
   }
   else
   {
      Print("SELL FAILED | Retcode: ",
            res.retcode,
            " | Comment: ",
            res.comment);
   }
}

//+------------------------------------------------------------------+
//| MANUAL PROFIT CLOSE                                              |
//+------------------------------------------------------------------+
void CheckProfitClose()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      double profit =
         PositionGetDouble(POSITION_PROFIT);

      // TAKE PROFIT
      if(profit >= ProfitCloseUSD)
      {
         ClosePosition(ticket);

         Print("PROFIT CLOSED: ", profit);
      }

      // EMERGENCY STOP LOSS
      if(profit <= EmergencyLossUSD)
      {
         ClosePosition(ticket);

         Print("LOSS CLOSED: ", profit);
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE POSITION                                                   |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   ENUM_ORDER_TYPE_FILLING filling;

   int fillMode =
      (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;

   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = symbol;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.magic        = MagicNumber;
   req.deviation    = Slippage;
   req.type_filling = filling;

   if(type == POSITION_TYPE_BUY)
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(symbol, SYMBOL_BID);
   }
   else
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   }

   if(!OrderSend(req, res))
   {
      Print("CLOSE FAILED: ", res.retcode);
   }
}

//+------------------------------------------------------------------+
//| LOT SIZE                                                         |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   if(!UseAutoLot)
      return FixedLot;

   double balance =
      AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney =
      balance * RiskPercent / 100.0;

   double tickValue =
      SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickValue <= 0)
      return FixedLot;

   double lot = riskMoney / 1000.0;

   double minLot =
      SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   double step =
      SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;

   if(lot < minLot)
      lot = minLot;

   if(lot > maxLot)
      lot = maxLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| UPDATE INDICATORS                                                |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(fastEMAHandle, 0, 0, 3, fastEMA) < 3)
      return false;

   if(CopyBuffer(slowEMAHandle, 0, 0, 3, slowEMA) < 3)
      return false;

   if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuffer) < 3)
      return false;

   if(CopyBuffer(atrHandle, 0, 0, 3, atrBuffer) < 3)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| COUNT POSITIONS                                                  |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == symbol)
      {
         count++;
      }
   }

   return count;
}

//+------------------------------------------------------------------+
//| SPREAD                                                           |
//+------------------------------------------------------------------+
int GetSpreadPoints()
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   return (int)((ask - bid) / pointValue);
}

//+------------------------------------------------------------------+
//| AVERAGE VOLUME                                                   |
//+------------------------------------------------------------------+
double GetAverageVolume()
{
   double total = 0;

   for(int i=1; i<=20; i++)
      total += iVolume(symbol, PERIOD_M1, i);

   return total / 20.0;
}
//+------------------------------------------------------------------+
EOF
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
