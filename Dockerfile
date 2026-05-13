
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
//|                                MicroPullback_Continuation.mq5    |
//|                     Trend Sniping + Trailing Stop (HFT inspired) |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "PullbackScalper"
#property version   "2.00"

// --- INPUTS (win‑rate focused) ---
input double   RiskPercent       = 2.0;        // Risk per trade (2-3%)
input int      StopLossPips      = 8;          // Fixed stop loss (pips)
input int      TrailingStartPips = 5;          // Start trailing when profit >=5 pips
input int      TrailingStepPips  = 3;          // Trail distance (pips)
input int      LookbackBars      = 20;         // EMA period (M5 for trend)
input int      PullbackCandles   = 2;          // Max number of pullback candles (1-3)
input double   PullbackDistance  = 2.0;        // Max distance from EMA (pips)
input int      MaxDailyLoss      = 3;          // Stop after 3 losses
input bool     UseSessionFilter  = true;       // London/NY only
input int      SessionOffset     = 0;
input int      MaxOpenPositions  = 1;

// --- GLOBALS ---
CTrade trade;
int    magic = 20250425;
int    dailyLoss = 0;
int    emaHandleM5;          // 5‑min EMA for trend direction
int    emaHandleM1;          // 1‑min EMA for pullback detection
double point, pipValue;
datetime lastBarTime = 0;    // for 1‑min bar change detection
int    retryCount = 0;
datetime lastRetryTime = 0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pipValue = (digits == 5 || digits == 3) ? point * 10 : point;

   // Create EMA handles
   emaHandleM5 = iMA(_Symbol, PERIOD_M5, LookbackBars, 0, MODE_EMA, PRICE_CLOSE);
   emaHandleM1 = iMA(_Symbol, PERIOD_M1, LookbackBars, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandleM5 == INVALID_HANDLE || emaHandleM1 == INVALID_HANDLE)
      return INIT_FAILED;

   // Detect broker filling mode
   long modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING fillMode = ORDER_FILLING_IOC;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) fillMode = ORDER_FILLING_IOC;
   else if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) fillMode = ORDER_FILLING_FOK;
   else fillMode = ORDER_FILLING_RETURN;

   trade.SetExpertMagicNumber(magic);
   trade.SetTypeFilling(fillMode);
   trade.SetDeviationInPoints(10);

   Print("==========================================");
   Print("MICRO PULLBACK CONTINUATION SCALPER");
   Print("Trend: 5-min EMA", LookbackBars);
   Print("Pullback entry: 1-min touch of EMA", LookbackBars);
   Print("Stop loss: ", StopLossPips, " pips");
   Print("Trailing: start at ", TrailingStartPips, " step ", TrailingStepPips);
   Print("==========================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Trailing stop management (inspired by your code)                 |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == magic)
      {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                               ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         double profitPips = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                             ? (currentPrice - openPrice) / pipValue
                             : (openPrice - currentPrice) / pipValue;

         if(profitPips >= TrailingStartPips)
         {
            double trailPoints = TrailingStepPips * (pipValue / point);
            double newSL = 0;
            bool modify = false;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               newSL = currentPrice - trailPoints * point;
               if(sl == 0 || newSL > sl) modify = true;
            }
            else
            {
               newSL = currentPrice + trailPoints * point;
               if(sl == 0 || newSL < sl) modify = true;
            }

            if(modify && trade.PositionModify(ticket, newSL, tp))
               Print("Trailing stop updated on ticket ", ticket, " to ", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Trade execution with retry (same as your HFT EA)                 |
//+------------------------------------------------------------------+
bool TradeWithRetry(ENUM_ORDER_TYPE type, double volume, double price, double sl, double tp, string comment)
{
   if(retryCount >= 5) { retryCount = 0; return false; }
   if(GetTickCount() - lastRetryTime < 1000 && retryCount > 0) return false;

   bool res = (type == ORDER_TYPE_BUY)
              ? trade.Buy(volume, _Symbol, price, sl, tp, comment)
              : trade.Sell(volume, _Symbol, price, sl, tp, comment);

   if(!res)
   {
      retryCount++;
      lastRetryTime = GetTickCount();
      Print("Trade attempt ", retryCount, " failed. Error: ", GetLastError(),
            " | Retcode: ", trade.ResultRetcode());
      return false;
   }
   retryCount = 0;
   return true;
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Daily loss limit reset ---
   static datetime lastDay = 0;
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != lastDay) { dailyLoss = 0; lastDay = today; }
   if(dailyLoss >= MaxDailyLoss) return;

   // --- Session filter (London/NY) ---
   if(UseSessionFilter)
   {
      MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
      int hour = (tm.hour + SessionOffset) % 24;
      if(!((hour >= 7 && hour < 10) || (hour >= 12 && hour < 15))) return;
   }

   // --- Position limit ---
   if(PositionsTotal() >= MaxOpenPositions) return;

   // --- Manage trailing stops on existing positions ---
   ManageTrailingStops();

   // --- Only evaluate new signals on new 1‑min bar ---
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   // --- Get trend direction from 5‑min EMA ---
   double emaM5[1], emaM5_prev[1];
   if(CopyBuffer(emaHandleM5, 0, 0, 1, emaM5) < 1) return;
   if(CopyBuffer(emaHandleM5, 0, 1, 1, emaM5_prev) < 1) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool uptrend = (ask > emaM5[0]) && (emaM5[0] > emaM5_prev[0]);   // price above rising EMA
   bool downtrend = (bid < emaM5[0]) && (emaM5[0] < emaM5_prev[0]); // price below falling EMA

   if(!uptrend && !downtrend) return;   // flat market, no signal

   // --- Get 1‑min EMA and recent candlesticks for pullback detection ---
   double emaM1[1];
   if(CopyBuffer(emaHandleM1, 0, 0, 1, emaM1) < 1) return;
   double currentEMA = emaM1[0];

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, PullbackCandles+3, rates) < PullbackCandles+2) return;

   // --- Detect pullback to EMA (on 1‑min) ---
   bool pullbackDetected = false;
   double pullbackPrice = 0;

   // For uptrend: look for a low that touched near EMA (within PullbackDistance pips)
   if(uptrend)
   {
      for(int i = 1; i <= PullbackCandles; i++)
      {
         double lowDist = (currentEMA - rates[i].low) / pipValue;
         if(lowDist >= 0 && lowDist <= PullbackDistance)
         {
            pullbackDetected = true;
            pullbackPrice = rates[i].low;
            break;
         }
      }
      // Also require the current asked price to be above EMA (continuation)
      if(pullbackDetected && ask > currentEMA)
      {
         double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
         lot = MathMax(0.01, lot);
         double sl = ask - StopLossPips * pipValue;
         double tp = 0;   // no fixed TP, rely on trailing stop

         if(TradeWithRetry(ORDER_TYPE_BUY, lot, ask, sl, tp, "PullbackBuy"))
            Print("🔥 BUY opened | Lot=", lot, " @ ", ask);
      }
   }
   // For downtrend: look for a high that touched near EMA
   else if(downtrend)
   {
      for(int i = 1; i <= PullbackCandles; i++)
      {
         double highDist = (rates[i].high - currentEMA) / pipValue;
         if(highDist >= 0 && highDist <= PullbackDistance)
         {
            pullbackDetected = true;
            pullbackPrice = rates[i].high;
            break;
         }
      }
      if(pullbackDetected && bid < currentEMA)
      {
         double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
         lot = MathMax(0.01, lot);
         double sl = bid + StopLossPips * pipValue;
         double tp = 0;

         if(TradeWithRetry(ORDER_TYPE_SELL, lot, bid, sl, tp, "PullbackSell"))
            Print("🔥 SELL opened | Lot=", lot, " @ ", bid);
      }
   }

   // Debug comment (optional)
   Comment(StringFormat("Pullback EA | Trend: %s | EMA=%.5f | Pullback: %s",
         uptrend ? "UP" : (downtrend ? "DOWN" : "FLAT"),
         currentEMA, pullbackDetected ? "YES" : "NO"));
}

//+------------------------------------------------------------------+
//| Track daily losses                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(HistoryDealSelect(deal) && HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         if(HistoryDealGetDouble(deal, DEAL_PROFIT) < 0) dailyLoss++;
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
