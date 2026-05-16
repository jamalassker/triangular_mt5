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
# AGGRESSIVE MICRO SCALPER EA – FIXED 4756 (min SL distance)
# ============================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                         MeanReversion_FastStart  |
//|                              No waiting – trades within 1 minute |
//+------------------------------------------------------------------+
#property copyright "Statistical Edge"
#property version   "3.01"
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
//| Expert initialization – seed history with current price         |
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

   // --- Seed price history with current close price (avoid waiting) ---
   ArrayResize(priceHistory, InpWindowPeriod);
   double currentClose = iClose(symbol, PERIOD_M1, 0);
   if(currentClose == 0) currentClose = SymbolInfoDouble(symbol, SYMBOL_BID);
   for(int i=0; i<InpWindowPeriod; i++)
      priceHistory[i] = currentClose;   // fill entire window with same price

   // ATR handle
   atrHandle = iATR(symbol, PERIOD_M1, 14);
   if(atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   ArraySetAsSeries(atrBuf, true);

   if(InpUseKalmanFilter)
   {
      KF_X = SymbolInfoDouble(symbol, SYMBOL_BID);
      KF_P = 1.0;
   }

   Print("✅ Fast‑Start EA on ", symbol, " | History seeded. Trading active.");
   Print("   Entry Z‑Score: ±", DoubleToString(InpEntryZScore,1));
   Print("   Risk per trade: ", InpRiskPercent, "%");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Print("EA removed from ", symbol);
}

//+------------------------------------------------------------------+
//| OnTick – trades immediately                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(drawdownHit || tradingPaused) return;
   if(CheckDailyLoss()) return;
   if(CheckDrawdown()) return;

   // --- Update price history on new M1 bar ---
   datetime curBar = iTime(symbol, PERIOD_M1, 0);
   if(curBar != lastBarTime)
   {
      lastBarTime = curBar;
      double closePrice = iClose(symbol, PERIOD_M1, 0);
      if(closePrice == 0) closePrice = SymbolInfoDouble(symbol, SYMBOL_BID);
      UpdatePriceHistory(closePrice);
   }

   // --- Use the current price for Z‑Score (not only on new bar) ---
   double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
   double mean, stddev;
   
   // Calculate stats from history (now always valid because seeded)
   if(!CalcMeanStdDev(priceHistory, mean, stddev) || stddev == 0.0)
   {
      // Fallback: use ATR as proxy for standard deviation
      if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) == 1)
         stddev = atrBuf[0] * 0.8;
      else
         stddev = 10 * pointValue;
      mean = priceHistory[0];   // last close as mean
   }

   double rawZ = (currentPrice - mean) / stddev;
   double filteredZ = rawZ;
   if(InpUseKalmanFilter)
      filteredZ = KalmanUpdate(rawZ);

   // Adaptive: reduce sensitivity in strong trends
   if(InpUseKalmanFilter && KF_P > 0.8)
      filteredZ = filteredZ * 0.7;

   bool buySignal  = (filteredZ <= -InpEntryZScore);
   bool sellSignal = (filteredZ >=  InpEntryZScore);

   // Debug print every 10 seconds
   static datetime lastPrint = 0;
   if(TimeCurrent() - lastPrint >= 10)
   {
      lastPrint = TimeCurrent();
      Print("Z=", DoubleToString(filteredZ,2), " | Mean=", DoubleToString(mean,5), " | StdDev=", DoubleToString(stddev,5));
   }

   if((buySignal || sellSignal) && CountPositions() == 0)
   {
      if(buySignal) OpenOrder(ORDER_TYPE_BUY, filteredZ, mean, stddev);
      if(sellSignal) OpenOrder(ORDER_TYPE_SELL, filteredZ, mean, stddev);
   }

   ExitWhenMeanReached(filteredZ);
   if(InpUseTrailing) ManageTrailing();
}

//+------------------------------------------------------------------+
//| Update rolling window (shift new price)                         |
//+------------------------------------------------------------------+
void UpdatePriceHistory(double newPrice)
{
   for(int i=InpWindowPeriod-1; i>=1; i--)
      priceHistory[i] = priceHistory[i-1];
   priceHistory[0] = newPrice;
}

//+------------------------------------------------------------------+
//| Calculate mean and standard deviation                           |
//+------------------------------------------------------------------+
bool CalcMeanStdDev(double &arr[], double &mean, double &stddev)
{
   int size = ArraySize(arr);
   if(size < 5) return false;   // reduced from 10 to 5
   double sum = 0.0, sum2 = 0.0;
   for(int i=0; i<size; i++)
   {
      sum += arr[i];
   }
   mean = sum / size;
   for(int i=0; i<size; i++)
   {
      sum2 += (arr[i] - mean) * (arr[i] - mean);
   }
   stddev = MathSqrt(sum2 / size);
   return (stddev > 0);
}

//+------------------------------------------------------------------+
//| Kalman filter                                                   |
//+------------------------------------------------------------------+
double KalmanUpdate(double measurement)
{
   double X_pred = KF_X;
   double P_pred = KF_P + InpKalmanProcessNoise;
   double K = P_pred / (P_pred + InpKalmanMeasNoise);
   double X_new = X_pred + K * (measurement - X_pred);
   double P_new = (1 - K) * P_pred;
   KF_X = X_new;
   KF_P = P_new;
   return X_new;
}

//+------------------------------------------------------------------+
//| Exit positions when Z‑Score returns near mean and profit >0    |
//+------------------------------------------------------------------+
void ExitWhenMeanReached(double currentZ)
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 0 && MathAbs(currentZ) <= InpExitZScore)
      {
         ClosePosition(ticket);
         if(InpPrintLog) Print("🔒 Closed | Z=", DoubleToString(currentZ,2), " profit=$", DoubleToString(profit,2));
      }
   }
}

//+------------------------------------------------------------------+
//| Open order – FIXED for error 4756                               |
//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type, double zScore, double mean, double stddev)
{
   double lot = CalculateLot();
   if(lot <= 0) return;

   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);
   // Normalize entry price to digits
   price = NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));

   double slDistance = (InpStopLossZScore - InpEntryZScore) * stddev;
   // MINIMUM SL DISTANCE: 10 points (1 pip on 5-digit brokers)
   double minSLPoints = 10.0 * pointValue;
   if(slDistance < minSLPoints) slDistance = minSLPoints;

   double tpDistance = slDistance * 1.5;

   double sl, tp;
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

   // Enforce broker's minimum stop level
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * pointValue;
   if(minDist < minSLPoints) minDist = minSLPoints;

   if(type == ORDER_TYPE_BUY)
   {
      if(price - sl < minDist) sl = price - minDist;
      if(tp - price < minDist) tp = price + minDist;
   }
   else
   {
      if(sl - price < minDist) sl = price + minDist;
      if(price - tp < minDist) tp = price - minDist;
   }

   // Normalize SL and TP
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // Final safety: SL and TP must be different from entry price
   if(sl == price) sl = (type == ORDER_TYPE_BUY) ? price - minDist : price + minDist;
   if(tp == price) tp = (type == ORDER_TYPE_BUY) ? price + minDist : price - minDist;

   // Auto-detect filling mode
   int fillMode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING filling;
   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.volume = lot;
   req.type = type;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = InpSlippage;
   req.magic = InpMagicNumber;
   req.comment = (type == ORDER_TYPE_BUY) ? "MeanRev BUY" : "MeanRev SELL";
   req.type_filling = filling;

   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
         Print((type==ORDER_TYPE_BUY)?"📈 BUY":"📉 SELL", " Lot=", lot, " Z=", DoubleToString(zScore,2));
      else
         Print("Order reject | retcode=", res.retcode);
   }
   else
      Print("OrderSend error: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Calculate lot size (fixed ATR error)                            |
//+------------------------------------------------------------------+
double CalculateLot()
{
   if(!InpUseAutoLot) return InpFixedLot;

   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickVal   = tickValue;
   if(tickVal <= 0) return InpFixedLot;

   double atrValue = 0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) == 1)
      atrValue = atrBuf[0];
   else
      atrValue = 10 * pipValue;

   double slDistance = InpStopLossZScore * atrValue;
   if(slDistance <= 0) slDistance = 10 * pipValue;

   double slTicks = slDistance / tickSize;
   double riskPerLot = slTicks * tickVal;
   if(riskPerLot <= 0) return InpFixedLot;

   double lot = riskMoney / riskPerLot;

   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;

   double maxAllowed = balance / 200.0;
   if(lot > maxAllowed) lot = maxAllowed;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Count positions                                                 |
//+------------------------------------------------------------------+
int CountPositions()
{
   int cnt = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| Trailing stop (unchanged)                                       |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      int typ = (int)PositionGetInteger(POSITION_TYPE);
      double price, newSL;
      if(typ == POSITION_TYPE_BUY)
      {
         price = SymbolInfoDouble(symbol, SYMBOL_BID);
         if((price - open)/pipValue >= InpTrailingStartPips)
         {
            newSL = price - InpTrailingStepPips * pipValue;
            if(newSL > sl) ModifyStopLoss(t, newSL);
         }
      }
      else
      {
         price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         if((open - price)/pipValue >= InpTrailingStartPips)
         {
            newSL = price + InpTrailingStepPips * pipValue;
            if(newSL < sl || sl == 0) ModifyStopLoss(t, newSL);
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
   req.magic = InpMagicNumber;
   if(!OrderSend(req, res))
      Print("Trail error: ", res.retcode);
}

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
   req.magic = InpMagicNumber;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      req.type = ORDER_TYPE_SELL;
   else
      req.type = ORDER_TYPE_BUY;
   req.price = (req.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(symbol, SYMBOL_BID);
   if(!OrderSend(req, res))
      Print("Close error: ", res.retcode);
}

bool CheckDailyLoss()
{
   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct = (dailyStartBalance - curBal) / dailyStartBalance * 100;
   if(lossPct >= InpMaxDailyLossPercent)
   {
      if(!tradingPaused) Print("Daily loss limit hit (", DoubleToString(lossPct,1), "%). Paused.");
      tradingPaused = true;
      return true;
   }
   MqlDateTime dt;
   TimeCurrent(dt);
   static int lastDay = dt.day;
   if(dt.day != lastDay)
   {
      dailyStartBalance = curBal;
      lastDay = dt.day;
      tradingPaused = false;
   }
   return false;
}

bool CheckDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct = (bal - eq) / bal * 100;
   if(ddPct >= InpMaxTotalDrawdown && !drawdownHit)
   {
      Print("EMERGENCY: Max drawdown (", DoubleToString(ddPct,1), "%). Closing all.");
      drawdownHit = true;
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            ClosePosition(t);
      }
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+
EOF

# ============================================================
# ENTRYPOINT SCRIPT (unchanged)
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
