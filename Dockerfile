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
//|                                           StatisticalMeanReversion|
//|                        Z‑Score + Kalman Filter + ONNX Confidence|
//|                                   Designed for $10 Cent Accounts|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Statistical Edge"
#property version   "1.00"
#property strict

//--- Input parameters
input double   InpRiskPercent        = 2.0;      // Risk per trade (% of equity)
input double   InpMaxDailyLossPercent = 10.0;    // Stop trading after X% daily loss
input double   InpMaxTotalDrawdown    = 15.0;    // Emergency close at X% drawdown
input double   InpFixedLot            = 0.01;    // Fixed lot (if UseAutoLot = false)
input bool     InpUseAutoLot          = true;    // Automatic lot sizing

input int      InpWindowPeriod        = 50;      // Rolling window for Z‑Score & Kalman
input double   InpEntryZScore         = 2.0;     // Entry threshold (abs value)
input double   InpExitZScore          = 0.5;     // Exit threshold (closer to mean)
input double   InpStopLossZScore      = 3.0;     // Invalidation threshold

input bool     InpUseKalmanFilter     = true;    // Use Kalman filter for noise reduction
input double   InpKalmanProcessNoise  = 0.1;     // Kalman process noise (adaptive)
input double   InpKalmanMeasNoise     = 1.0;     // Kalman measurement noise

input bool     InpUseONNX             = true;    // Use pre‑trained ONNX model
input string   InpONNXModelFile       = "reversal_model.onnx"; // Place in Files folder

input int      InpMagicNumber         = 99001;
input int      InpSlippage            = 20;
input bool     InpPrintLog            = true;

//--- Global variables
string         symbol;
double         pointValue, pipValue, tickSize, tickValue;
double         dailyStartBalance;
bool           tradingPaused = false;
bool           drawdownHit  = false;
datetime       lastBarTime;

//--- Kalman filter state variables
double         KF_X, KF_P;                     // State estimate and error covariance

//--- ONNX model handle
long           onnx_handle = INVALID_HANDLE;

//--- Dynamic array for rolling window
double         priceHistory[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   symbol       = Symbol();
   pointValue   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   pipValue     = pointValue * 10;
   tickSize     = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   tickValue    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastBarTime  = iTime(symbol, PERIOD_M1, 0);
   
   // Initialize dynamic array for rolling window
   ArrayResize(priceHistory, InpWindowPeriod);
   ArrayInitialize(priceHistory, 0.0);
   
   // Initialize Kalman filter
   if(InpUseKalmanFilter)
      KalmanFilterInit();
   
   // Load ONNX model
   if(InpUseONNX)
   {
      string onnx_path = "\\Files\\" + InpONNXModelFile;
      onnx_handle = OnnxCreate(onnx_path, ONNX_DEFAULT);
      if(onnx_handle == INVALID_HANDLE)
         Print("⚠️ ONNX model not found. Running without ML confidence.");
      else
         Print("✅ ONNX model loaded successfully.");
   }
   
   Print("📊 Statistical Mean Reversion EA initialized.");
   Print("   Z‑Score entry threshold: ±", DoubleToString(InpEntryZScore,1));
   Print("   Risk per trade: ", InpRiskPercent, "%");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(onnx_handle != INVALID_HANDLE)
      OnnxRelease(onnx_handle);
   Print("📉 EA removed. Final balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Safety checks -------------------------------------------------
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE)) return;
   if(drawdownHit || tradingPaused) return;
   if(CheckDailyLoss()) return;
   if(CheckDrawdown()) return;
   
   // --- Wait for a new bar (M1) to reduce redundant calculations -----
   datetime curBar = iTime(symbol, PERIOD_M1, 0);
   if(curBar == lastBarTime) return;
   lastBarTime = curBar;
   
   // --- Update rolling window with latest close price ----------------
   double currentPrice = iClose(symbol, PERIOD_M1, 0);
   UpdatePriceHistory(currentPrice);
   
   // --- Calculate Z‑Score --------------------------------------------
   double mean, stddev;
   if(!CalculateStats(priceHistory, mean, stddev) || stddev == 0.0)
      return;
   
   double zScore = (currentPrice - mean) / stddev;
   
   // --- Apply Kalman filter to reduce noise --------------------------
   double filteredZScore = zScore;
   if(InpUseKalmanFilter)
      filteredZScore = KalmanFilterUpdate(zScore);
   
   // --- Regime detection: trend strength via Kalman gain ------------
   double trendStrength = 0.0;
   if(InpUseKalmanFilter)
      trendStrength = MathAbs(KF_P * InpKalmanProcessNoise);
   if(trendStrength > 0.8)   // Strong trend detected -> widen thresholds
   {
      filteredZScore = filteredZScore * 0.5;
      if(InpPrintLog) Print("🧭 Strong trend mode: thresholds adapted.");
   }
   
   // --- Signal generation --------------------------------------------
   bool buySignal  = (filteredZScore <= -InpEntryZScore);
   bool sellSignal = (filteredZScore >=  InpEntryZScore);
   
   if((buySignal || sellSignal) && CountPositions() == 0)
   {
      // --- ONNX confidence check (if available) --------------------
      double confidence = 0.5;   // default neutral
      if(InpUseONNX && onnx_handle != INVALID_HANDLE)
         confidence = ONNXPredictReversalProb(currentPrice, mean, stddev, zScore);
      
      if(confidence >= 0.65)   // only trade high‑confidence setups
      {
         if(buySignal)
            OpenOrder(ORDER_TYPE_BUY, filteredZScore, mean, stddev);
         if(sellSignal)
            OpenOrder(ORDER_TYPE_SELL, filteredZScore, mean, stddev);
      }
      else
         if(InpPrintLog) Print("🧠 ONNX rejected signal (confidence: ", confidence, ")");
   }
   
   // --- Exit logic: close positions when Z‑Score returns to mean ----
   ExitWhenMeanReached(filteredZScore);
   
   // --- Manage existing positions (trailing stop) ------------------
   ManageTrailingStops();
}

//+------------------------------------------------------------------+
//| Update price history (rolling window)                            |
//+------------------------------------------------------------------+
void UpdatePriceHistory(double newPrice)
{
   for(int i = ArraySize(priceHistory)-1; i >= 1; i--)
      priceHistory[i] = priceHistory[i-1];
   priceHistory[0] = newPrice;
}

//+------------------------------------------------------------------+
//| Calculate mean and standard deviation of an array                |
//+------------------------------------------------------------------+
bool CalculateStats(double &arr[], double &mean, double &stddev)
{
   int size = ArraySize(arr);
   if(size < 10) return false;
   
   double sum = 0.0, sumSq = 0.0;
   int count = 0;
   for(int i = 0; i < size; i++)
   {
      if(arr[i] != 0.0)   // ignore uninitialized values
      {
         sum += arr[i];
         count++;
      }
   }
   if(count < 10) return false;
   
   mean = sum / count;
   for(int i = 0; i < size; i++)
   {
      if(arr[i] != 0.0)
         sumSq += MathPow(arr[i] - mean, 2);
   }
   stddev = MathSqrt(sumSq / count);
   return true;
}

//+------------------------------------------------------------------+
//| Kalman filter initialization                                     |
//+------------------------------------------------------------------+
void KalmanFilterInit()
{
   // Initial state estimate: assume first price observation
   KF_X = SymbolInfoDouble(symbol, SYMBOL_BID);
   KF_P = 1.0;   // initial uncertainty
}

//+------------------------------------------------------------------+
//| Kalman filter update step (prediction + correction)              |
//+------------------------------------------------------------------+
double KalmanFilterUpdate(double measurement)
{
   // --- Prediction ----------------------------------------------------
   // State estimate: x = x (no state transition model)
   double X_pred = KF_X;
   // Error covariance: P = P + Q
   double P_pred = KF_P + InpKalmanProcessNoise;
   
   // --- Correction ---------------------------------------------------
   // Kalman Gain: K = P_pred / (P_pred + R)
   double K_gain = P_pred / (P_pred + InpKalmanMeasNoise);
   // Updated state estimate: X_new = X_pred + K * (z - X_pred)
   double X_new = X_pred + K_gain * (measurement - X_pred);
   // Updated error covariance: P_new = (1 - K) * P_pred
   double P_new = (1 - K_gain) * P_pred;
   
   // Update global state for next iteration
   KF_X = X_new;
   KF_P = P_new;
   
   return X_new;
}

//+------------------------------------------------------------------+
//| ONNX prediction: estimate reversal probability                   |
//+------------------------------------------------------------------+
double ONNXPredictReversalProb(double price, double mean, double stddev, double zScore)
{
   // Prepare input tensor: [price, mean, stddev, zScore]
   float inputData[4] = {(float)price, (float)mean, (float)stddev, (float)zScore};
   float outputData[1];
   
   // Set input/output shapes
   ulong inputShape[]  = {1, 4};
   ulong outputShape[] = {1, 1};
   
   if(OnnxRun(onnx_handle, ONNX_NO_CONVERSION, inputData, inputShape, outputData, outputShape))
      return (double)outputData[0];   // Probability between 0 and 1
   else
      return 0.5;   // fallback neutral
}

//+------------------------------------------------------------------+
//| Exit position when Z‑Score returns to the mean                   |
//+------------------------------------------------------------------+
void ExitWhenMeanReached(double currentZ)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 0 && MathAbs(currentZ) <= InpExitZScore)
      {
         ClosePosition(ticket);
         if(InpPrintLog) Print("🔒 Position closed: Z‑Score returned to mean (", currentZ, ")");
      }
   }
}

//+------------------------------------------------------------------+
//| Open a market order                                              |
//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type, double zScore, double mean, double stddev)
{
   double lot = CalcLot();
   if(lot <= 0) return;
   
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);
   
   // Set stop loss based on Z‑Score invalidation threshold
   double slDistance = (InpStopLossZScore - InpEntryZScore) * stddev;
   double tpDistance = slDistance * 1.5;   // reward:risk = 1.5:1
   
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
   
   // Enforce minimum distance rules
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist   = stopsLevel * pointValue;
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
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action  = TRADE_ACTION_DEAL;
   req.symbol  = symbol;
   req.volume  = lot;
   req.type    = type;
   req.price   = price;
   req.sl      = sl;
   req.tp      = tp;
   req.deviation = InpSlippage;
   req.magic   = InpMagicNumber;
   req.comment = (type == ORDER_TYPE_BUY) ? "MeanRev BUY" : "MeanRev SELL";
   
   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
         Print((type == ORDER_TYPE_BUY)?"📈 BUY":"📉 SELL", " opened | Z‑Score:", DoubleToString(zScore,2),
               " | Confidence: High | Lot:", lot);
      else
         Print("Order failed: ", res.retcode, " | ", res.comment);
   }
   else
      Print("OrderSend error: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Dynamic lot size based on risk percent                           |
//+------------------------------------------------------------------+
double CalcLot()
{
   if(!InpUseAutoLot) return InpFixedLot;
   
   double balance  = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickVal   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tickVal <= 0) return InpFixedLot;
   
   double slDistance = InpStopLossZScore * (iATR(symbol, PERIOD_M1, 14)[0]);
   if(slDistance <= 0) return InpFixedLot;
   
   double slTicks   = slDistance / tickSize;
   double riskPerLot = slTicks * tickVal;
   if(riskPerLot <= 0) return InpFixedLot;
   
   double lot = riskMoney / riskPerLot;
   
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   
   // Safety cap: 10% of equity per trade maximum
   double maxAllowed = balance / 500.0;
   if(lot > maxAllowed) lot = maxAllowed;
   
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Count positions belonging to this EA                             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Trailing stop management                                         |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      int    type = (int)PositionGetInteger(POSITION_TYPE);
      
      double price, newSL;
      if(type == POSITION_TYPE_BUY)
      {
         price = SymbolInfoDouble(symbol, SYMBOL_BID);
         if(price - open >= 10 * pipValue)   // start trailing after 10 pips
         {
            newSL = price - 5 * pipValue;
            if(newSL > sl) ModifyStopLoss(ticket, newSL);
         }
      }
      else
      {
         price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         if(open - price >= 10 * pipValue)
         {
            newSL = price + 5 * pipValue;
            if(newSL < sl || sl == 0) ModifyStopLoss(ticket, newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify stop loss of a position                                   |
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
//| Close a specific position                                        |
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
         Print("🚨 Daily loss limit reached (", lossPct, "%). Trading paused.");
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
      Print("📅 Daily tracker reset. New starting balance: ", dailyStartBalance);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Maximum drawdown limit (emergency)                               |
//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct = (bal - eq) / bal * 100;
   if(ddPct >= InpMaxTotalDrawdown && !drawdownHit)
   {
      Print("🚨 EMERGENCY: Max drawdown reached (", ddPct, "%). Closing all positions.");
      drawdownHit = true;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            ClosePosition(ticket);
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
