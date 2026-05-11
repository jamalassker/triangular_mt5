
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
//|           EXPONENTIAL SWEEP SCALPER - M1                          |
//|   Opens dozens of trades, closes at 1-2 pips profit, compounds   |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property strict
#property version "4.0"

// --- INPUTS ---
input string   SymbolToTrade       = "EURUSD.vx";
input double   BaseLot             = 0.01;          // Starting lot
input double   RiskPercent         = 1.0;           // % of equity per trade (dynamic lot)
input bool     UseExponentialLot   = true;          // Lot = base * (equity/initial)^2

input int      LookbackBars        = 5;             // Smaller = more sweeps
input double   SweepPoints         = 0;             // 0 = break of low/high triggers
input bool     RequireCloseAbove   = false;         // False breakout filter (optional)

input int      StopLossPoints      = 150;           // Wider SL (15 pips)
input int      TakeProfitPoints    = 15;            // TINY TP (1.5 pips) → FAST CLOSE
input double   MinProfitToClose    = 0.20;          // Close only if profit > 0.20$
input int      CloseAfterSeconds   = 20;            // Force close after 20 seconds

input bool     AllowMultipleTrades = true;
input int      MaxPositions        = 15;            // More positions = more compounding

input int      MagicNumber         = 777999;
input bool     DebugPrint          = false;

CTrade trade;
double point;
double initialEquity;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int CountPositions()
{
   int total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == SymbolToTrade)
            total++;
   }
   return total;
}

//+------------------------------------------------------------------+
double GetLowestLow(int shiftFrom = 2)
{
   double low = DBL_MAX;
   for(int i = shiftFrom; i <= LookbackBars; i++)
   {
      double l = iLow(SymbolToTrade, PERIOD_M1, i);
      if(l < low) low = l;
   }
   return low;
}

//+------------------------------------------------------------------+
double GetHighestHigh(int shiftFrom = 2)
{
   double high = -DBL_MAX;
   for(int i = shiftFrom; i <= LookbackBars; i++)
   {
      double h = iHigh(SymbolToTrade, PERIOD_M1, i);
      if(h > high) high = h;
   }
   return high;
}

//+------------------------------------------------------------------+
double CalculateDynamicLot()
{
   double lot = BaseLot;
   if(UseExponentialLot)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double ratio = equity / initialEquity;
      lot = BaseLot * ratio * ratio;       // Quadratic growth
      lot = MathMin(lot, 1.0);             // Cap at 1.0 (adjust as needed)
   }
   else if(RiskPercent > 0)
   {
      double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(SymbolToTrade, SYMBOL_TRADE_TICK_VALUE);
      double slPoints = StopLossPoints;
      lot = riskMoney / (slPoints * tickValue);
   }
   lot = MathMax(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MAX));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double lot = CalculateDynamicLot();
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double sl = ask - StopLossPoints * point;
   double tp = ask + TakeProfitPoints * point;

   if(trade.Buy(lot, SymbolToTrade, ask, sl, tp, "EXP SWEEP BUY"))
   {
      if(DebugPrint) Print("🔥 BUY opened | Lot=", lot, " TP=", TakeProfitPoints*point*10000, "pips");
   }
   else Print("❌ BUY failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double lot = CalculateDynamicLot();
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double sl = bid + StopLossPoints * point;
   double tp = bid - TakeProfitPoints * point;

   if(trade.Sell(lot, SymbolToTrade, bid, sl, tp, "EXP SWEEP SELL"))
   {
      if(DebugPrint) Print("🔥 SELL opened | Lot=", lot);
   }
   else Print("❌ SELL failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = (direction == 1) ? SymbolInfoDouble(SymbolToTrade, SYMBOL_BID) 
                                             : SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
      double pointsGain = (currentPrice - openPrice) / point * direction;

      // --- Close conditions ---
      bool closeProfit = (profit > MinProfitToClose);
      bool closeTimeout = (TimeCurrent() - openTime >= CloseAfterSeconds);
      bool closeTrailing = (pointsGain > 5 && pointsGain < TakeProfitPoints); // partial take

      if(closeProfit || closeTimeout)
      {
         if(trade.PositionClose(ticket))
            if(DebugPrint) Print("💰 CLOSED | profit=", profit, " | time=", (TimeCurrent()-openTime), "sec");
      }
      // Optional: move SL to breakeven after 3 points profit
      else if(pointsGain > 3)
      {
         double newSL = (direction == 1) ? openPrice : openPrice;
         if(PositionGetDouble(POSITION_SL) != newSL)
         {
            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(SymbolToTrade);
   SymbolSelect(SymbolToTrade, true);
   point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("========================================");
   Print("EXPONENTIAL SWEEP SCALPER v4 STARTED");
   Print("Symbol: ", SymbolToTrade, " | Point: ", point);
   Print("Initial Equity: ", initialEquity);
   Print("Risk: ", (UseExponentialLot ? "Compound (equity²)" : (string)RiskPercent+"%"));
   Print("TP: ", TakeProfitPoints*point*10000, " pips | SL: ", StopLossPoints*point*10000, " pips");
   Print("========================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(!AllowMultipleTrades && CountPositions() > 0) return;
   if(CountPositions() >= MaxPositions) return;

   // New bar logic (avoid multiple triggers per bar)
   datetime currentBarTime = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   double lowestLow   = GetLowestLow(2);
   double highestHigh = GetHighestHigh(2);
   double currentLow  = iLow(SymbolToTrade, PERIOD_M1, 0);
   double currentHigh = iHigh(SymbolToTrade, PERIOD_M1, 0);
   double prevLow     = iLow(SymbolToTrade, PERIOD_M1, 1);
   double prevHigh    = iHigh(SymbolToTrade, PERIOD_M1, 1);

   // Aggressive sweep triggers (break of recent range)
   bool buySweep   = (currentLow < (lowestLow - SweepPoints * point));
   bool sellSweep  = (currentHigh > (highestHigh + SweepPoints * point));

   // Optional: false breakout filter – requires bar to close above/below previous bar
   if(RequireCloseAbove)
   {
      buySweep  = buySweep && (iClose(SymbolToTrade, PERIOD_M1, 0) > prevHigh);
      sellSweep = sellSweep && (iClose(SymbolToTrade, PERIOD_M1, 0) < prevLow);
   }

   if(DebugPrint)
      Print("Low=", currentLow, " LL=", lowestLow, " High=", currentHigh, " HH=", highestHigh,
            " Buy=", buySweep, " Sell=", sellSweep);

   if(buySweep)  OpenBuy();
   if(sellSweep) OpenSell();
}
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
