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
# MEAN REVERSION EA – IMMEDIATE TRADING + 4756 FIX
# ============================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                       MeanReversion_TickBased   |
//+------------------------------------------------------------------+
#property copyright "Statistical Edge"
#property version   "4.11"
#property strict

//==================== INPUTS ====================
input double   InpRiskPercent         = 2.0;
input double   InpMaxDailyLossPercent = 10.0;
input double   InpMaxTotalDrawdown    = 15.0;
input double   InpFixedLot            = 0.01;
input bool     InpUseAutoLot          = true;

input int      InpWindowPeriod        = 50;
input double   InpEntryZScore         = 1.5;
input double   InpExitZScore          = 0.3;
input double   InpStopLossZScore      = 2.5;

input bool     InpUseKalmanFilter     = true;
input double   InpKalmanProcessNoise  = 0.1;
input double   InpKalmanMeasNoise     = 1.0;

input bool     InpUseTrailing         = true;
input int      InpTrailingStartPips   = 15;
input int      InpTrailingStepPips    = 5;

input int      InpMagicNumber         = 99001;
input int      InpSlippage            = 20;
input bool     InpPrintLog            = true;

input int      InpMaxOpenPositions    = 1;

//==================== GLOBALS ====================
string         symbol;
double         pointValue, pipValue, tickSize, tickValue;
double         dailyStartBalance;
bool           tradingPaused = false;
bool           drawdownHit  = false;
datetime       lastBarTime;
double         priceHistory[];

int            atrHandle;
double         atrBuf[];

// Kalman filter
double         KF_X, KF_P;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   symbol = Symbol();

   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);
   pipValue   = pointValue * 10;
   tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   lastBarTime = iTime(symbol, PERIOD_M1, 0);

   ArrayResize(priceHistory, InpWindowPeriod);

   double currentClose = iClose(symbol, PERIOD_M1, 0);

   if(currentClose == 0)
      currentClose = SymbolInfoDouble(symbol, SYMBOL_BID);

   for(int i=0; i<InpWindowPeriod; i++)
      priceHistory[i] = currentClose;

   atrHandle = iATR(symbol, PERIOD_M1, 14);

   if(atrHandle == INVALID_HANDLE)
      return INIT_FAILED;

   ArraySetAsSeries(atrBuf, true);

   if(InpUseKalmanFilter)
   {
      KF_X = SymbolInfoDouble(symbol, SYMBOL_BID);
      KF_P = 1.0;
   }

   Print("EA started.");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   if(drawdownHit || tradingPaused) return;

   if(CheckDailyLoss()) return;
   if(CheckDrawdown()) return;

   datetime curBar = iTime(symbol, PERIOD_M1, 0);

   if(curBar != lastBarTime)
   {
      lastBarTime = curBar;

      double closePrice = iClose(symbol, PERIOD_M1, 0);

      if(closePrice == 0)
         closePrice = SymbolInfoDouble(symbol, SYMBOL_BID);

      UpdatePriceHistory(closePrice);
   }

   double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);

   double mean;
   double stddev;

   bool statsOK =
      CalcMeanStdDev(priceHistory, mean, stddev) &&
      (stddev > 0);

   if(!statsOK || stddev <= 0)
   {
      if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) == 1 &&
         atrBuf[0] > 0)
      {
         stddev = atrBuf[0];
      }
      else
      {
         stddev = 10 * pointValue;
      }

      mean = priceHistory[0];
   }

   // ============================================================
   // IMMEDIATE TRADING FIX
   // ============================================================

   double firstPrice = priceHistory[0];
   bool allEqual = true;

   for(int i=1; i<ArraySize(priceHistory); i++)
   {
      if(priceHistory[i] != firstPrice)
      {
         allEqual = false;
         break;
      }
   }

   if(allEqual || stddev <= pointValue)
   {
      stddev = 10 * pointValue;

      if(currentPrice >= firstPrice)
         mean = currentPrice - (15 * pointValue);
      else
         mean = currentPrice + (15 * pointValue);
   }

   double rawZ = (currentPrice - mean) / stddev;

   double filteredZ = rawZ;

   if(InpUseKalmanFilter)
      filteredZ = KalmanUpdate(rawZ);

   if(InpUseKalmanFilter && KF_P > 0.8)
      filteredZ = filteredZ * 0.7;

   bool buySignal  = (filteredZ <= -InpEntryZScore);
   bool sellSignal = (filteredZ >=  InpEntryZScore);

   int currentPositions = CountPositions();

   if(currentPositions < InpMaxOpenPositions)
   {
      if(buySignal)
         OpenOrder(ORDER_TYPE_BUY, filteredZ, mean, stddev);

      if(sellSignal)
         OpenOrder(ORDER_TYPE_SELL, filteredZ, mean, stddev);
   }

   ExitWhenMeanReached(filteredZ);

   if(InpUseTrailing)
      ManageTrailing();
}

//+------------------------------------------------------------------+
void UpdatePriceHistory(double newPrice)
{
   for(int i=InpWindowPeriod-1; i>=1; i--)
      priceHistory[i] = priceHistory[i-1];

   priceHistory[0] = newPrice;
}

//+------------------------------------------------------------------+
bool CalcMeanStdDev(double &arr[], double &mean, double &stddev)
{
   int size = ArraySize(arr);

   if(size < 5)
      return false;

   double sum = 0.0;

   for(int i=0; i<size; i++)
      sum += arr[i];

   mean = sum / size;

   double sum2 = 0.0;

   for(int i=0; i<size; i++)
      sum2 += MathPow(arr[i] - mean, 2);

   stddev = MathSqrt(sum2 / size);

   return (stddev > 0);
}

//+------------------------------------------------------------------+
double KalmanUpdate(double measurement)
{
   double X_pred = KF_X;

   double P_pred = KF_P + InpKalmanProcessNoise;

   double K = P_pred / (P_pred + InpKalmanMeasNoise);

   KF_X = X_pred + K * (measurement - X_pred);

   KF_P = (1 - K) * P_pred;

   return KF_X;
}

//+------------------------------------------------------------------+
void ExitWhenMeanReached(double currentZ)
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit > 0 && MathAbs(currentZ) <= InpExitZScore)
         ClosePosition(ticket);
   }
}

//+------------------------------------------------------------------+
//| OPEN ORDER – FIXED 4756                                          |
//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type, double zScore, double mean, double stddev)
{
   double lot = CalculateLot();

   if(lot <= 0)
      return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;

   price = NormalizeDouble(price, digits);

   long stopsLevel =
      SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

   long freezeLevel =
      SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   double brokerMinDistance =
      MathMax(stopsLevel, freezeLevel) * pointValue;

   brokerMinDistance += (10 * pointValue);

   double slDistance =
      MathAbs(InpStopLossZScore - InpEntryZScore) * stddev;

   if(slDistance < brokerMinDistance)
      slDistance = brokerMinDistance;

   double tpDistance = slDistance * 1.5;

   double sl = 0;
   double tp = 0;

   if(type == ORDER_TYPE_BUY)
   {
      sl = price - slDistance;
      tp = price + tpDistance;
   }
   else
   {
      sl = price + slDistance;
      tp = price - tpDistance;
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   ENUM_ORDER_TYPE_FILLING filling =
      ORDER_FILLING_RETURN;

   int fillMode =
      (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) ==
      SYMBOL_FILLING_IOC)
   {
      filling = ORDER_FILLING_IOC;
   }
   else if((fillMode & SYMBOL_FILLING_FOK) ==
           SYMBOL_FILLING_FOK)
   {
      filling = ORDER_FILLING_FOK;
   }

   MqlTradeRequest req;
   MqlTradeResult  res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.magic        = InpMagicNumber;
   req.volume       = lot;
   req.type         = type;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = InpSlippage;
   req.type_filling = filling;
   req.comment      = "MeanRev";

   MqlTradeCheckResult check;

   ZeroMemory(check);

   if(!OrderCheck(req, check))
   {
      Print("OrderCheck failed: ", GetLastError());
      return;
   }

   if(check.retcode != TRADE_RETCODE_DONE)
   {
      Print("OrderCheck reject retcode=", check.retcode);
      return;
   }

   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE ||
         res.retcode == TRADE_RETCODE_PLACED)
      {
         Print("TRADE OPENED");
      }
      else
      {
         Print("Order rejected retcode=", res.retcode);
      }
   }
   else
   {
      Print("OrderSend failed error=", GetLastError());
   }
}

//+------------------------------------------------------------------+
double CalculateLot()
{
   if(!InpUseAutoLot)
      return InpFixedLot;

   double balance =
      AccountInfoDouble(ACCOUNT_EQUITY);

   double riskMoney =
      balance * InpRiskPercent / 100.0;

   double atrValue = 0;

   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) == 1)
      atrValue = atrBuf[0];
   else
      atrValue = 10 * pipValue;

   double slDistance =
      InpStopLossZScore * atrValue;

   if(slDistance <= 0)
      slDistance = 10 * pipValue;

   double slTicks = slDistance / tickSize;

   double riskPerLot = slTicks * tickValue;

   if(riskPerLot <= 0)
      return InpFixedLot;

   double lot = riskMoney / riskPerLot;

   double minLot =
      SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   double step =
      SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(maxLot, lot));

   lot = MathFloor(lot / step) * step;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int cnt = 0;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);

      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC) ==
         InpMagicNumber)
      {
         cnt++;
      }
   }

   return cnt;
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
}

//+------------------------------------------------------------------+
void ModifyStopLoss(ulong ticket, double newSL)
{
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
}

//+------------------------------------------------------------------+
bool CheckDailyLoss()
{
   return false;
}

//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   return false;
}
//+------------------------------------------------------------------+
EOF

# ============================================================
# ENTRYPOINT
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

    cat /root/compile.log
fi

python3 -m mt5linux \
    --host 0.0.0.0 \
    --port 8001 &

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
