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
//|                                         MeanReversion_ZScore.mq5 |
//|                      Statistical Z‑Score Mean Reversion Scalper  |
//|                                      Fixed for cent accounts     |
//+------------------------------------------------------------------+
#property copyright "Statistical Edge"
#property version   "2.00"
#property strict

//==================== INPUTS ====================
input double   InpRiskPercent         = 2.0;      // Risk per trade (% of equity)
input double   InpMaxDailyLossPercent = 10.0;     // Stop trading after X% daily loss
input double   InpMaxTotalDrawdown    = 15.0;     // Emergency close at X% drawdown
input double   InpFixedLot            = 0.01;     // Fixed lot (if UseAutoLot = false)
input bool     InpUseAutoLot          = true;     // Automatic lot sizing

input int      InpWindowPeriod        = 50;       // Rolling window for Z‑Score
input double   InpEntryZScore         = 1.5;      // Entry threshold (abs value) – lowered
input double   InpExitZScore          = 0.3;      // Exit when |Z| drops below this
input double   InpStopLossZScore      = 2.5;      // Invalidation threshold

input bool     InpUseKalmanFilter     = true;     // Use Kalman filter for noise
input double   InpKalmanProcessNoise  = 0.1;
input double   InpKalmanMeasNoise     = 1.0;

input bool     InpUseTrailing         = true;     // Enable trailing stop
input int      InpTrailingStartPips   = 15;       // Start trailing after profit (pips)
input int      InpTrailingStepPips    = 5;        // Trail distance

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
double         priceHistory[];              // rolling window of closes

// Kalman filter state
double         KF_X, KF_P;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
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

   // Initialize rolling window with zeros
   ArrayResize(priceHistory, InpWindowPeriod);
   ArrayInitialize(priceHistory, 0.0);

   // Kalman filter init
   if(InpUseKalmanFilter)
   {
      KF_X = SymbolInfoDouble(symbol, SYMBOL_BID);
      KF_P = 1.0;
   }

   Print("✅ Mean Reversion EA started on ", symbol);
   Print("   Entry Z‑Score threshold: ±", DoubleToString(InpEntryZScore,1));
   Print("   Risk per trade: ", InpRiskPercent, "%");
   Print("   Window: ", InpWindowPeriod, " bars");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("📉 EA removed from ", symbol, ". Final balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- safety checks ---
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(drawdownHit || tradingPaused) return;
   if(CheckDailyLoss()) return;
   if(CheckDrawdown()) return;

   //--- wait for new M1 bar to reduce noise ---
   datetime curBar = iTime(symbol, PERIOD_M1, 0);
   if(curBar == lastBarTime) return;
   lastBarTime = curBar;

   //--- update rolling window with latest close price ---
   double closePrice = iClose(symbol, PERIOD_M1, 0);
   UpdatePriceHistory(closePrice);

   //--- count valid bars (non-zero) ---
   int validBars = 0;
   for(int i=0; i<InpWindowPeriod; i++)
      if(priceHistory[i] != 0.0) validBars++;

   if(validBars < 20)   // need at least 20 bars for reliable stats
   {
      if(InpPrintLog && (TimeCurrent() % 60 == 0))
         Print("⌛ Collecting price history... ", validBars, "/", InpWindowPeriod, " bars");
      return;
   }

   //--- calculate mean and standard deviation ---
   double mean, stddev;
   if(!CalcMeanStdDev(priceHistory, mean, stddev) || stddev == 0.0)
      return;

   //--- current price for Z‑Score (use last close) ---
   double currentPrice = priceHistory[0];
   double rawZ = (currentPrice - mean) / stddev;

   //--- apply Kalman filter if enabled ---
   double filteredZ = rawZ;
   if(InpUseKalmanFilter)
      filteredZ = KalmanUpdate(rawZ);

   //--- optional: trend strength adaptation (widen thresholds if trending) ---
   if(InpUseKalmanFilter && KF_P > 0.8)
   {
      filteredZ = filteredZ * 0.7;   // reduce sensitivity during strong trends
      if(InpPrintLog && (TimeCurrent() % 60 == 0))
         Print("🧭 Trend mode active (gain=", DoubleToString(KF_P,2), ")");
   }

   //--- signal generation ---
   bool buySignal  = (filteredZ <= -InpEntryZScore);
   bool sellSignal = (filteredZ >=  InpEntryZScore);

   //--- debug print every minute ---
   static datetime lastPrint = 0;
   if(TimeCurrent() - lastPrint >= 60)
   {
      lastPrint = TimeCurrent();
      Print("Z-Score: ", DoubleToString(filteredZ,3), " | Mean: ", DoubleToString(mean,5), " | StdDev: ", DoubleToString(stddev,5));
   }

   //--- open trade if signal and no existing position ---
   if((buySignal || sellSignal) && CountPositions() == 0)
   {
      if(buySignal)
         OpenOrder(ORDER_TYPE_BUY, filteredZ, mean, stddev);
      if(sellSignal)
         OpenOrder(ORDER_TYPE_SELL, filteredZ, mean, stddev);
   }

   //--- exit positions when Z‑Score returns near mean ---
   ExitWhenMeanReached(filteredZ);

   //--- trailing stop (if enabled) ---
   if(InpUseTrailing)
      ManageTrailing();
}

//+------------------------------------------------------------------+
//| Update rolling window (newest at index 0)                        |
//+------------------------------------------------------------------+
void UpdatePriceHistory(double newPrice)
{
   // shift all elements to the right
   for(int i = InpWindowPeriod-1; i >= 1; i--)
      priceHistory[i] = priceHistory[i-1];
   priceHistory[0] = newPrice;
}

//+------------------------------------------------------------------+
//| Calculate mean and standard deviation of array                   |
//+------------------------------------------------------------------+
bool CalcMeanStdDev(double &arr[], double &mean, double &stddev)
{
   int size = ArraySize(arr);
   if(size < 10) return false;

   double sum = 0.0, sum2 = 0.0;
   int cnt = 0;
   for(int i=0; i<size; i++)
   {
      if(arr[i] != 0.0)
      {
         sum += arr[i];
         cnt++;
      }
   }
   if(cnt < 10) return false;

   mean = sum / cnt;
   for(int i=0; i<size; i++)
   {
      if(arr[i] != 0.0)
         sum2 += (arr[i] - mean) * (arr[i] - mean);
   }
   stddev = MathSqrt(sum2 / cnt);
   return true;
}

//+------------------------------------------------------------------+
//| Kalman filter update                                             |
//+------------------------------------------------------------------+
double KalmanUpdate(double measurement)
{
   // prediction
   double X_pred = KF_X;
   double P_pred = KF_P + InpKalmanProcessNoise;

   // correction
   double K = P_pred / (P_pred + InpKalmanMeasNoise);
   double X_new = X_pred + K * (measurement - X_pred);
   double P_new = (1 - K) * P_pred;

   KF_X = X_new;
   KF_P = P_new;
   return X_new;
}

//+------------------------------------------------------------------+
//| Exit position when Z‑Score returns near mean and trade is +ve    |
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
         if(InpPrintLog) Print("🔒 Closed profitable trade | Z=", DoubleToString(currentZ,3), " | Profit=$", DoubleToString(profit,2));
      }
   }
}

//+------------------------------------------------------------------+
//| Open market order                                                |
//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type, double zScore, double mean, double stddev)
{
   double lot = CalculateLot();
   if(lot <= 0) return;

   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);

   // SL based on stop-out Z‑Score level
   double slDistance = (InpStopLossZScore - InpEntryZScore) * stddev;
   double tpDistance = slDistance * 1.5;   // reward:risk = 1.5

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

   // enforce minimum stop distance
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * pointValue;
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

   // auto-detect filling mode
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
   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = symbol;
   req.volume      = lot;
   req.type        = type;
   req.price       = price;
   req.sl          = sl;
   req.tp          = tp;
   req.deviation   = InpSlippage;
   req.magic       = InpMagicNumber;
   req.comment     = (type == ORDER_TYPE_BUY) ? "MeanRev BUY" : "MeanRev SELL";
   req.type_filling = filling;

   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
      {
         Print((type == ORDER_TYPE_BUY)?"📈 BUY":"📉 SELL", " opened | Lot=", lot,
               " | Z=", DoubleToString(zScore,2), " | Entry=", price);
      }
      else
         Print("Order rejected | retcode=", res.retcode, " | ", res.comment);
   }
   else
      Print("OrderSend error: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percent                         |
//+------------------------------------------------------------------+
double CalculateLot()
{
   if(!InpUseAutoLot) return InpFixedLot;

   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickVal   = tickValue;
   if(tickVal <= 0) return InpFixedLot;

   // use fixed SL distance of 10 pips for risk calculation
   // 1. Get the handle for the ATR indicator (do this once, usually in OnInit)
int atrHandle = iATR(symbol, PERIOD_M1, 14);

// 2. Create a dynamic array to hold the ATR values
double atrValues[];

// 3. Copy the most recent value (1 element from index 0) into your array
if(CopyBuffer(atrHandle, 0, 0, 1, atrValues) > 0)
{
    // 4. Calculate your stop loss distance using the copied value
    double slDistance = InpStopLossZScore * atrValues[0];
    double slDistance = InpStopLossZScore * (iATR(symbol, PERIOD_M1, 14)[0]);
    // Use slDistance here...
}
else
{
    Print("Failed to copy ATR data. Error code: ", GetLastError());
}
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

   // safety: maximum 5% of balance in single trade
   double maxAllowed = balance / 200.0;
   if(lot > maxAllowed) lot = maxAllowed;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Count positions of this EA                                       |
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
//| Trailing stop management                                         |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      int    typ  = (int)PositionGetInteger(POSITION_TYPE);

      double price, newSL;
      if(typ == POSITION_TYPE_BUY)
      {
         price = SymbolInfoDouble(symbol, SYMBOL_BID);
         if((price - open) / pipValue >= InpTrailingStartPips)
         {
            newSL = price - InpTrailingStepPips * pipValue;
            if(newSL > sl) ModifyStopLoss(t, newSL);
         }
      }
      else
      {
         price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         if((open - price) / pipValue >= InpTrailingStartPips)
         {
            newSL = price + InpTrailingStepPips * pipValue;
            if(newSL < sl || sl == 0) ModifyStopLoss(t, newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify stop loss                                                |
//+------------------------------------------------------------------+
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
      Print("Trail modify error: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Close a single position                                          |
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

//+------------------------------------------------------------------+
//| Daily loss limit                                                 |
//+------------------------------------------------------------------+
bool CheckDailyLoss()
{
   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct = (dailyStartBalance - curBal) / dailyStartBalance * 100;
   if(lossPct >= InpMaxDailyLossPercent)
   {
      if(!tradingPaused)
         Print("🚨 Daily loss limit hit (", DoubleToString(lossPct,1), "%). Trading paused.");
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

//+------------------------------------------------------------------+
//| Max drawdown emergency                                           |
//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct = (bal - eq) / bal * 100;
   if(ddPct >= InpMaxTotalDrawdown && !drawdownHit)
   {
      Print("🚨 EMERGENCY: Max drawdown reached (", DoubleToString(ddPct,1), "%). Closing all.");
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
