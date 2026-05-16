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
//|      Institutional Crypto Scalper EA (UPGRADED VERSION)         |
//+------------------------------------------------------------------+
#property strict
#property version "5.00"

//================ INPUTS =================
input double RiskPercent        = 1.0;
input bool   UseAutoLot         = true;
input double FixedLot           = 0.01;

input int    FastEMA            = 9;
input int    SlowEMA            = 21;
input int    TrendEMA_M5        = 50;

input int    RSI_Period         = 14;
input int    ATR_Period         = 14;

input double ATR_SL_Mult        = 1.5;
input double ATR_TP_Mult        = 2.0;

input int    MaxSpreadPoints    = 8000;

input double MinATR             = 0.5;   // volatility filter (tune per broker)

input int    MagicNumber        = 99001;
input int    Slippage           = 20;

input bool   EnableBuy          = true;
input bool   EnableSell         = true;

//================ GLOBALS =================
string symbol;

int fastHandle, slowHandle, rsiHandle, atrHandle, trendHandle;

double fastEMA[], slowEMA[], rsiBuf[], atrBuf[], trendEMA[];

double pointValue;

//+------------------------------------------------------------------+
int OnInit()
{
   symbol = Symbol();
   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);

   fastHandle  = iMA(symbol, PERIOD_M1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle  = iMA(symbol, PERIOD_M1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle   = iRSI(symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   atrHandle   = iATR(symbol, PERIOD_M1, ATR_Period);

   trendHandle = iMA(symbol, PERIOD_M5, TrendEMA_M5, 0, MODE_EMA, PRICE_CLOSE);

   if(fastHandle==INVALID_HANDLE || slowHandle==INVALID_HANDLE ||
      rsiHandle==INVALID_HANDLE  || atrHandle==INVALID_HANDLE ||
      trendHandle==INVALID_HANDLE)
      return INIT_FAILED;

   ArraySetAsSeries(fastEMA,true);
   ArraySetAsSeries(slowEMA,true);
   ArraySetAsSeries(rsiBuf,true);
   ArraySetAsSeries(atrBuf,true);
   ArraySetAsSeries(trendEMA,true);

   Print("Institutional EA started");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(trendHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(GetSpread() > MaxSpreadPoints) return;

   if(!Update()) return;

   double atr = atrBuf[0];
   if(atr < MinATR) return; // LOW VOLATILITY FILTER

   double fast = fastEMA[0];
   double slow = slowEMA[0];
   double rsi  = rsiBuf[0];
   double trend = trendEMA[0];

   bool upTrend   = fast > slow && slow > trend;
   bool downTrend = fast < slow && slow < trend;

   bool buySignal = false;
   bool sellSignal = false;

   //================ BUY =================
   if(EnableBuy)
   {
      if(upTrend && rsi > 50 && rsi < 70)
         buySignal = true;
   }

   //================ SELL =================
   if(EnableSell)
   {
      if(downTrend && rsi < 50 && rsi > 30)
         sellSignal = true;
   }

   if(CountPositions() > 0) return;

   if(buySignal)  OpenOrder(ORDER_TYPE_BUY, atr);
   if(sellSignal) OpenOrder(ORDER_TYPE_SELL, atr);
}

//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type, double atr)
{
   double lot = CalcLot(atr);

   double price = (type==ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(symbol,SYMBOL_ASK)
                  : SymbolInfoDouble(symbol,SYMBOL_BID);

   double sl,tp;

   if(type==ORDER_TYPE_BUY)
   {
      sl = price - (atr * ATR_SL_Mult);
      tp = price + (atr * ATR_TP_Mult);
   }
   else
   {
      sl = price + (atr * ATR_SL_Mult);
      tp = price - (atr * ATR_TP_Mult);
   }

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.magic  = MagicNumber;
   req.type   = type;
   req.volume = lot;
   req.price  = price;
   req.sl     = sl;
   req.tp     = tp;
   req.deviation = Slippage;

   OrderSend(req,res);

   if(res.retcode == 10009 || res.retcode == 10008)
      Print("TRADE OK");
   else
      Print("TRADE FAIL: ",res.retcode);
}

//+------------------------------------------------------------------+
double CalcLot(double atr)
{
   if(!UseAutoLot) return FixedLot;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;

   double slDistance = atr * ATR_SL_Mult;
   double tickValue = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tickValue <= 0) return FixedLot;

   double lot = riskMoney / (slDistance * 1000.0);

   double minLot = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot/step)*step;

   return NormalizeDouble(lot,2);
}

//+------------------------------------------------------------------+
bool Update()
{
   return CopyBuffer(fastHandle,0,0,3,fastEMA) >= 3 &&
          CopyBuffer(slowHandle,0,0,3,slowEMA) >= 3 &&
          CopyBuffer(rsiHandle,0,0,3,rsiBuf) >= 3 &&
          CopyBuffer(atrHandle,0,0,3,atrBuf) >= 3 &&
          CopyBuffer(trendHandle,0,0,3,trendEMA) >= 3;
}

//+------------------------------------------------------------------+
int GetSpread()
{
   double ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol,SYMBOL_BID);
   return (int)((ask-bid)/pointValue);
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int c=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber)
            c++;
   }
   return c;
}
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
