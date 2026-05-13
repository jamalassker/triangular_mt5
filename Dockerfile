
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
# =========================================================
# V17.0 - HFT PULLBACK CONTINUATION SCALPER (AGGRESSIVE)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                          HFT_Pullback_Continuation.mq5 |
//|                     Aggressive HFT - Pullback to EMA + Sweep Fixes |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "HFT Pullback"
#property version   "6.10"

// --- AGGRESSIVE INPUTS ---
input double   RiskPercent       = 2.0;        // Risk per trade (% of equity)
input int      StopLossPips      = 0;          // 0 = no fixed stop (trailing only)
input int      TakeProfitPips    = 0;          // 0 = no fixed target
input int      LookbackBars      = 20;         // EMA period
input double   PullbackPips      = 2.0;        // Max distance from EMA (pips)
input int      TrailingStartPips = 5;          // Start trailing when profit reaches this (pips)
input int      TrailingStepPips  = 3;          // Trail distance (pips)
input int      MaxDailyLoss      = 20;         // Stop after X losing trades
input bool     UseSessionFilter  = false;      // false = 24/7 trading
input int      SessionOffset     = 0;
input int      MaxOpenPositions  = 10;         // Concurrent positions

// --- GLOBALS ---
CTrade trade;
int    magic = 20250430;
int    dailyLoss = 0;
int    emaHandle;
double point, pipValue;
int    retryCount = 0;
datetime lastRetryTime = 0;

//+------------------------------------------------------------------+
//| Trade execution with retry (from sweep strategy)                |
//+------------------------------------------------------------------+
bool TradeWithRetry(ENUM_ORDER_TYPE type, double volume, double price, double sl, double tp, string comment)
{
   if(retryCount >= 5) { retryCount = 0; return false; }
   if(GetTickCount() - lastRetryTime < 1000 && retryCount > 0) return false;
   
   double use_sl = (sl == 0) ? 0.0 : sl;
   double use_tp = (tp == 0) ? 0.0 : tp;
   
   bool res = (type == ORDER_TYPE_BUY) 
              ? trade.Buy(volume, _Symbol, price, use_sl, use_tp, comment)
              : trade.Sell(volume, _Symbol, price, use_sl, use_tp, comment);
   
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
//| Trailing stop management (aggressive locking)                   |
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
            double trailPoints = TrailingStepPips * pipValue;
            double newSL = 0;
            bool modify = false;
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               newSL = currentPrice - trailPoints;
               if(sl == 0 || newSL > sl) modify = true;
            }
            else
            {
               newSL = currentPrice + trailPoints;
               if(sl == 0 || newSL < sl) modify = true;
            }
            if(modify && trade.PositionModify(ticket, newSL, tp))
               Print("Trailing stop updated on ", ticket, " to ", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pipValue = (digits == 5 || digits == 3) ? point * 10 : point;
   
   emaHandle = iMA(_Symbol, PERIOD_M1, LookbackBars, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE) return INIT_FAILED;
   
   long modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING fillMode = ORDER_FILLING_IOC;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) fillMode = ORDER_FILLING_IOC;
   else if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) fillMode = ORDER_FILLING_FOK;
   else fillMode = ORDER_FILLING_RETURN;
   
   trade.SetExpertMagicNumber(magic);
   trade.SetTypeFilling(fillMode);
   trade.SetDeviationInPoints(10);
   
   Print("==========================================");
   Print("HFT PULLBACK CONTINUATION - AGGRESSIVE");
   Print("Pullback distance: ", PullbackPips, " pips");
   Print("Trailing start: ", TrailingStartPips, " step: ", TrailingStepPips);
   Print("Max positions: ", MaxOpenPositions);
   Print("==========================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Daily loss limit
   static datetime lastDay = 0;
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != lastDay) { dailyLoss = 0; lastDay = today; }
   if(dailyLoss >= MaxDailyLoss) return;
   
   // Session filter
   if(UseSessionFilter)
   {
      MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
      int hour = (tm.hour + SessionOffset) % 24;
      if(!((hour >= 7 && hour < 10) || (hour >= 12 && hour < 15))) return;
   }
   
   // Position limit
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // Manage trailing stops on existing positions
   ManageTrailingStops();
   
   // Get current and previous EMA
   double ema[1], prevEMA[1];
   if(CopyBuffer(emaHandle, 0, 0, 1, ema) < 1) return;
   if(CopyBuffer(emaHandle, 0, 1, 1, prevEMA) < 1) return;
   double currentEMA = ema[0];
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Trend detection: price above EMA and EMA rising = uptrend
   bool uptrend = (ask > currentEMA) && (currentEMA > prevEMA[0]);
   bool downtrend = (bid < currentEMA) && (currentEMA < prevEMA[0]);
   
   // Pullback detection: price within PullbackPips of EMA
   double askDist = (ask - currentEMA) / pipValue;
   double bidDist = (currentEMA - bid) / pipValue;
   bool pullbackBuy = uptrend && (askDist >= 0 && askDist <= PullbackPips);
   bool pullbackSell = downtrend && (bidDist >= 0 && bidDist <= PullbackPips);
   
   // Force trade fallback (every 30 ticks if no signal) – keeps aggressiveness
   static int forceCounter = 0;
   forceCounter++;
   if(forceCounter >= 30 && !pullbackBuy && !pullbackSell)
   {
      forceCounter = 0;
      if(ask > currentEMA) pullbackBuy = true;
      else pullbackSell = true;
   }
   
   Comment(StringFormat("HFT Pullback | EMA=%.5f | BuyDist=%.1f SellDist=%.1f | Buy=%s Sell=%s | Positions=%d",
         currentEMA, askDist, bidDist, pullbackBuy?"★":"-", pullbackSell?"★":"-", PositionsTotal()));
   
   if(!pullbackBuy && !pullbackSell) return;
   
   // Lot size calculation (2% risk of equity)
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   ENUM_ORDER_TYPE tradeType;
   double price, sl = 0, tp = 0;
   string comment;
   
   if(pullbackBuy)
   {
      tradeType = ORDER_TYPE_BUY;
      price = ask;
      comment = "PullbackBuy";
   }
   else
   {
      tradeType = ORDER_TYPE_SELL;
      price = bid;
      comment = "PullbackSell";
   }
   
   // Execute with retry (using sweep’s improved TradeWithRetry)
   bool placed = false;
   for(int attempt = 0; attempt < 5 && !placed; attempt++)
   {
      placed = TradeWithRetry(tradeType, lot, price, sl, tp, comment);
      if(!placed && attempt < 4) Sleep(50);
   }
   if(placed) Print("🔥 Pullback trade: ", EnumToString(tradeType), " Lot=", lot, " @ ", price);
}

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
