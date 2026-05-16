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
//|                    XAUUSD Smart Scalper EA                       |
//|          Safer momentum scalper for small cent accounts          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

// ================= INPUTS =================
input double RiskPercent            = 1.0;
input double FixedLot               = 0.01;
input bool   UseAutoLot             = true;

input double ProfitTargetUSD        = 0.50;

input int    FastEMA                = 20;
input int    SlowEMA                = 50;
input int    RSI_Period             = 14;
input int    ATR_Period             = 14;

input double ATR_SL_Multiplier      = 1.2;
input double ATR_TP_Multiplier      = 0.8;

input int    MaxSpreadPoints        = 300;
input int    MaxConsecutiveLosses   = 3;

input int    MagicNumber            = 777001;
input int    Slippage               = 20;

input bool   PrintLogs              = true;

// Trading Session UTC
input int    SessionStartHour       = 13;
input int    SessionEndHour         = 18;

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

int consecutiveLosses = 0;

double pointValue;

//+------------------------------------------------------------------+
//| Expert Init                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   symbol = Symbol();

   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);

   fastEMAHandle = iMA(symbol, PERIOD_M1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowEMAHandle = iMA(symbol, PERIOD_M1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   atrHandle     = iATR(symbol, PERIOD_M1, ATR_Period);

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

   Print("XAUUSD Smart Scalper Started");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert Deinit                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(fastEMAHandle);
   IndicatorRelease(slowEMAHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(!IsTradingSession())
      return;

   if(GetSpreadPoints() > MaxSpreadPoints)
      return;

   if(consecutiveLosses >= MaxConsecutiveLosses)
      return;

   CheckCloseByProfit();

   if(CountPositions() > 0)
      return;

   if(!UpdateIndicators())
      return;

   double fast = fastEMA[0];
   double slow = slowEMA[0];
   double rsi  = rsiBuffer[0];
   double atr  = atrBuffer[0];

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   bool buySignal  = false;
   bool sellSignal = false;

   // BUY CONDITIONS
   if(fast > slow)
   {
      if(bid <= fast && rsi > 45 && rsi < 65)
         buySignal = true;
   }

   // SELL CONDITIONS
   if(fast < slow)
   {
      if(ask >= fast && rsi < 55 && rsi > 35)
         sellSignal = true;
   }

   if(buySignal)
      OpenBuy(atr);

   if(sellSignal)
      OpenSell(atr);
}

//+------------------------------------------------------------------+
//| Open BUY                                                        |
//+------------------------------------------------------------------+
void OpenBuy(double atr)
{
   double lot = CalculateLotSize(atr);

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   double sl = ask - (atr * ATR_SL_Multiplier);
   double tp = ask + (atr * ATR_TP_Multiplier);

   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.magic        = MagicNumber;
   req.type         = ORDER_TYPE_BUY;
   req.volume       = lot;
   req.price        = ask;
   req.sl           = NormalizeDouble(sl, _Digits);
   req.tp           = NormalizeDouble(tp, _Digits);
   req.deviation    = Slippage;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment      = "SmartScalper BUY";

   if(OrderSend(req, res))
   {
      if(PrintLogs)
         Print("BUY OPENED | Lot:", lot);
   }
}

//+------------------------------------------------------------------+
//| Open SELL                                                       |
//+------------------------------------------------------------------+
void OpenSell(double atr)
{
   double lot = CalculateLotSize(atr);

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   double sl = bid + (atr * ATR_SL_Multiplier);
   double tp = bid - (atr * ATR_TP_Multiplier);

   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.magic        = MagicNumber;
   req.type         = ORDER_TYPE_SELL;
   req.volume       = lot;
   req.price        = bid;
   req.sl           = NormalizeDouble(sl, _Digits);
   req.tp           = NormalizeDouble(tp, _Digits);
   req.deviation    = Slippage;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment      = "SmartScalper SELL";

   if(OrderSend(req, res))
   {
      if(PrintLogs)
         Print("SELL OPENED | Lot:", lot);
   }
}

//+------------------------------------------------------------------+
//| Profit Close                                                    |
//+------------------------------------------------------------------+
void CheckCloseByProfit()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit >= ProfitTargetUSD)
      {
         ClosePosition(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Close Position                                                  |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.position  = ticket;
   req.symbol    = symbol;
   req.volume    = PositionGetDouble(POSITION_VOLUME);
   req.magic     = MagicNumber;
   req.deviation = Slippage;

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

   OrderSend(req, res);
}

//+------------------------------------------------------------------+
//| Calculate Lot                                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double atr)
{
   if(!UseAutoLot)
      return FixedLot;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney = balance * RiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickValue <= 0)
      return FixedLot;

   double slValue = atr * ATR_SL_Multiplier;

   double lot = riskMoney / (slValue / pointValue * tickValue);

   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;

   if(lot < minLot)
      lot = minLot;

   if(lot > maxLot)
      lot = maxLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Count Positions                                                 |
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
//| Spread Filter                                                   |
//+------------------------------------------------------------------+
int GetSpreadPoints()
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   return (int)((ask - bid) / pointValue);
}

//+------------------------------------------------------------------+
//| Session Filter                                                  |
//+------------------------------------------------------------------+
bool IsTradingSession()
{
   MqlDateTime tm;
   TimeToStruct(TimeGMT(), tm);

   if(tm.hour >= SessionStartHour &&
      tm.hour < SessionEndHour)
   {
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Update Indicators                                               |
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
