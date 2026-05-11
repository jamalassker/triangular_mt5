
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
//|               TICK SCALP HYPER AGGRESSIVE BOT                   |
//|          Tick-Based Mean Reversion Micro Scalper                |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property strict
#property version "8.0"

input string SymbolToTrade = "EURUSD.vx";

input double FixedLot = 0.01;

input int TickLookback = 25;

input double TickMovePoints = 3;

input double ProfitCloseUSD = 0.03;

input double EmergencyLossUSD = -4.0;

input bool AllowMultiplePositions = true;

input int MaxPositions = 10;

input int CooldownMilliseconds = 300;

input int MaxSpreadPoints = 25;

input bool UseTrendFilter = false;

input int EMA_Period = 20;

input bool DebugPrint = false;

input int MagicNumber = 989898;

CTrade trade;

double point;

ulong lastTradeMs = 0;

// TICK STORAGE
double tickPrices[200];
int tickCount = 0;

//+------------------------------------------------------------------+
int CountPositions()
{
   int total = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC)
            == MagicNumber &&
            PositionGetString(POSITION_SYMBOL)
            == SymbolToTrade)
         {
            total++;
         }
      }
   }

   return total;
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC)
            != MagicNumber)
            continue;

         double profit =
            PositionGetDouble(POSITION_PROFIT);

         // CLOSE ANY PROFIT FAST
         if(profit >= ProfitCloseUSD)
         {
            trade.PositionClose(ticket);

            if(DebugPrint)
               Print("💰 QUICK EXIT: ", profit);
         }

         // EMERGENCY EXIT
         if(profit <= EmergencyLossUSD)
         {
            trade.PositionClose(ticket);

            if(DebugPrint)
               Print("🛑 LOSS EXIT: ", profit);
         }
      }
   }
}

//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread =
      (SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK)
      -
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID))
      / point;

   return spread <= MaxSpreadPoints;
}

//+------------------------------------------------------------------+
bool BuyTrendOK()
{
   if(!UseTrendFilter)
      return true;

   double ema =
      iMA(
         SymbolToTrade,
         PERIOD_M1,
         EMA_Period,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   double price =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   return price > ema;
}

//+------------------------------------------------------------------+
bool SellTrendOK()
{
   if(!UseTrendFilter)
      return true;

   double ema =
      iMA(
         SymbolToTrade,
         PERIOD_M1,
         EMA_Period,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   double price =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   return price < ema;
}

//+------------------------------------------------------------------+
void StoreTick(double price)
{
   if(tickCount < 200)
   {
      tickPrices[tickCount] = price;
      tickCount++;
   }
   else
   {
      for(int i=0; i<199; i++)
      {
         tickPrices[i] = tickPrices[i+1];
      }

      tickPrices[199] = price;
   }
}

//+------------------------------------------------------------------+
double GetLowestTick()
{
   double low = DBL_MAX;

   int start =
      MathMax(0, tickCount - TickLookback);

   for(int i=start; i<tickCount; i++)
   {
      if(tickPrices[i] < low)
         low = tickPrices[i];
   }

   return low;
}

//+------------------------------------------------------------------+
double GetHighestTick()
{
   double high = -DBL_MAX;

   int start =
      MathMax(0, tickCount - TickLookback);

   for(int i=start; i<tickCount; i++)
   {
      if(tickPrices[i] > high)
         high = tickPrices[i];
   }

   return high;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

   bool ok =
      trade.Buy(
         FixedLot,
         SymbolToTrade,
         ask,
         0,
         0,
         "TICK BUY"
      );

   if(ok)
   {
      lastTradeMs = GetTickCount64();

      if(DebugPrint)
         Print("🔥 BUY OPENED");
   }
   else
   {
      Print(
         "❌ BUY FAILED: ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double bid =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   bool ok =
      trade.Sell(
         FixedLot,
         SymbolToTrade,
         bid,
         0,
         0,
         "TICK SELL"
      );

   if(ok)
   {
      lastTradeMs = GetTickCount64();

      if(DebugPrint)
         Print("🔥 SELL OPENED");
   }
   else
   {
      Print(
         "❌ SELL FAILED: ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   trade.SetTypeFillingBySymbol(SymbolToTrade);

   SymbolSelect(SymbolToTrade, true);

   point =
      SymbolInfoDouble(
         SymbolToTrade,
         SYMBOL_POINT
      );

   Print("================================");
   Print("⚡ TICK SCALPER STARTED");
   Print("================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(!SpreadOK())
      return;

   if(!AllowMultiplePositions)
   {
      if(CountPositions() > 0)
         return;
   }

   if(CountPositions() >= MaxPositions)
      return;

   ulong nowMs = GetTickCount64();

   if(nowMs - lastTradeMs <
      (ulong)CooldownMilliseconds)
   {
      return;
   }

   double bid =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   double ask =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

   double mid =
      (bid + ask) / 2.0;

   // STORE LIVE TICK
   StoreTick(mid);

   if(tickCount < TickLookback)
      return;

   double lowestTick =
      GetLowestTick();

   double highestTick =
      GetHighestTick();

   // AGGRESSIVE MICRO REVERSAL

   bool buySignal =
      bid <
      (lowestTick -
      TickMovePoints * point);

   bool sellSignal =
      ask >
      (highestTick +
      TickMovePoints * point);

   if(DebugPrint)
   {
      Print(
         "BID=", bid,
         " LOWEST=", lowestTick,
         " ASK=", ask,
         " HIGHEST=", highestTick
      );
   }

   // BUY
   if(buySignal && BuyTrendOK())
   {
      OpenBuy();
   }

   // SELL
   if(sellSignal && SellTrendOK())
   {
      OpenSell();
   }
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
