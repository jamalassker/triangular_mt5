pairs arbitrage bot

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
//|                                 Triangular_Arbitrage_FastOut.mq5|
//|                     Fast in/out: close as soon as profit > 0    |
//|                     + max hold time + loss cut                  |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Fast Triangular Arbitrage"
#property version   "4.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   Symbol1         = "GBPUSD.vx";     // Use your broker's symbols
input string   Symbol2         = "USDJPY.vx";
input string   Symbol3         = "GBPJPY.vx";
input double   RiskPercent     = 2.0;             // % equity per basket
input int      MinProfitPoints = 0;               // 0 = close as soon as profit > 0
input int      MaxHoldSeconds  = 5;               // Max seconds to hold basket (fast exit)
input double   MaxLossPercent  = 0.5;             // Max loss % of equity per basket (cut loss)
input int      MaxOpenBaskets  = 1;               // Only one basket at a time (avoid stacking)
input int      MagicNumber     = 888999;
input int      StartHour       = 0;
input int      EndHour         = 24;
input bool     DebugPrint      = true;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime last_debug = 0;
datetime last_trade = 0;

struct Basket {
   ulong t1, t2, t3;
   datetime openTime;
   bool closed;
};
Basket baskets[];
int arraySizeBaskets = 0;

//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
void CloseBasket(int idx, string reason) {
   if(baskets[idx].closed) return;
   if(baskets[idx].t1 > 0) trade.PositionClose(baskets[idx].t1);
   if(baskets[idx].t2 > 0) trade.PositionClose(baskets[idx].t2);
   if(baskets[idx].t3 > 0) trade.PositionClose(baskets[idx].t3);
   baskets[idx].closed = true;
   Print("Closed basket: ", reason);
}

//+------------------------------------------------------------------+
double CalculateMispricingPoints() {
   double bid1 = SymbolInfoDouble(Symbol1, SYMBOL_BID);
   double ask1 = SymbolInfoDouble(Symbol1, SYMBOL_ASK);
   double bid2 = SymbolInfoDouble(Symbol2, SYMBOL_BID);
   double ask2 = SymbolInfoDouble(Symbol2, SYMBOL_ASK);
   double bid3 = SymbolInfoDouble(Symbol3, SYMBOL_BID);
   double ask3 = SymbolInfoDouble(Symbol3, SYMBOL_ASK);
   if(bid1<=0||ask1<=0||bid2<=0||ask2<=0||bid3<=0||ask3<=0) return 0;
   
   double synthetic_bid = bid1 * bid2;
   double actual_mid = (bid3 + ask3) / 2.0;
   double mispricing_price = synthetic_bid - actual_mid;
   double point3 = SymbolInfoDouble(Symbol3, SYMBOL_POINT);
   if(point3 <= 0) point3 = 0.001;
   return mispricing_price / point3;
}

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(Symbol1, true);
   SymbolSelect(Symbol2, true);
   SymbolSelect(Symbol3, true);
   ArrayResize(baskets,0);
   Print("==============================================");
   Print("⚡ FAST TRIANGULAR ARBITRAGE");
   Print("   ", Symbol1, " + ", Symbol2, " -> ", Symbol3);
   Print("   MinProfitPoints: ", MinProfitPoints, " | MaxHoldSeconds: ", MaxHoldSeconds);
   Print("   MaxLossPercent: ", MaxLossPercent, "%");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
   if(!IsTradingTime()) {
      for(int i=0; i<ArraySize(baskets); i++) if(!baskets[i].closed) CloseBasket(i, "Session end");
      return;
   }
   
   datetime now = TimeCurrent();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Manage existing baskets
   for(int i=0; i<ArraySize(baskets); i++) {
      if(baskets[i].closed) continue;
      
      // Calculate total profit
      double profit = 0;
      if(baskets[i].t1 > 0 && PositionSelectByTicket(baskets[i].t1)) profit += PositionGetDouble(POSITION_PROFIT);
      if(baskets[i].t2 > 0 && PositionSelectByTicket(baskets[i].t2)) profit += PositionGetDouble(POSITION_PROFIT);
      if(baskets[i].t3 > 0 && PositionSelectByTicket(baskets[i].t3)) profit += PositionGetDouble(POSITION_PROFIT);
      
      // Fast exit on profit (any positive, or >= MinProfitPoints if set > 0)
      if(MinProfitPoints == 0 && profit > 0) {
         CloseBasket(i, "Profit > 0 ($" + DoubleToString(profit,2) + ")");
         continue;
      }
      if(MinProfitPoints > 0 && profit >= MinProfitPoints) {
         CloseBasket(i, "Profit goal reached ($" + DoubleToString(profit,2) + ")");
         continue;
      }
      
      // Loss cut: if loss exceeds MaxLossPercent of equity
      if(MaxLossPercent > 0 && -profit >= (equity * MaxLossPercent / 100.0)) {
         CloseBasket(i, "Loss limit reached ($" + DoubleToString(-profit,2) + ")");
         continue;
      }
      
      // Max holding time
      if(MaxHoldSeconds > 0 && (now - baskets[i].openTime) >= MaxHoldSeconds) {
         CloseBasket(i, "Max hold time reached (profit: $" + DoubleToString(profit,2) + ")");
         continue;
      }
   }
   
   // Remove closed baskets
   for(int i=ArraySize(baskets)-1; i>=0; i--) {
      if(baskets[i].closed) {
         for(int j=i; j<ArraySize(baskets)-1; j++) baskets[j]=baskets[j+1];
         ArrayResize(baskets, ArraySize(baskets)-1);
      }
   }
   
   // Limit and cooldown
   if(ArraySize(baskets) >= MaxOpenBaskets) return;
   if(now - last_trade < 2) return;  // 2 seconds cooldown
   
   // Entry signal
   double mispricing = CalculateMispricingPoints();
   if(DebugPrint && now - last_debug >= 2) {
      last_debug = now;
      Print("📊 Mispricing: ", DoubleToString(mispricing,2), " points");
   }
   
   // Trade only if absolute mispricing > 0 (or > MinProfitPoints if you want a threshold)
   if(mispricing == 0) return;
   
   bool buySynthetic = (mispricing > 0);
   bool sellSynthetic = (mispricing < 0);
   if(!buySynthetic && !sellSynthetic) return;
   
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, MathMin(lot, SymbolInfoDouble(Symbol1, SYMBOL_VOLUME_MAX)));
   
   double ask1 = SymbolInfoDouble(Symbol1, SYMBOL_ASK);
   double bid1 = SymbolInfoDouble(Symbol1, SYMBOL_BID);
   double ask2 = SymbolInfoDouble(Symbol2, SYMBOL_ASK);
   double bid2 = SymbolInfoDouble(Symbol2, SYMBOL_BID);
   double ask3 = SymbolInfoDouble(Symbol3, SYMBOL_ASK);
   double bid3 = SymbolInfoDouble(Symbol3, SYMBOL_BID);
   
   Basket newBasket;
   newBasket.closed = false;
   newBasket.openTime = now;
   
   if(buySynthetic) {
      newBasket.t1 = trade.Buy(lot, Symbol1, ask1, 0, 0, "Tri Leg1");
      newBasket.t2 = trade.Buy(lot, Symbol2, ask2, 0, 0, "Tri Leg2");
      newBasket.t3 = trade.Sell(lot, Symbol3, bid3, 0, 0, "Tri Leg3");
   } else {
      newBasket.t1 = trade.Sell(lot, Symbol1, bid1, 0, 0, "Tri Leg1");
      newBasket.t2 = trade.Sell(lot, Symbol2, bid2, 0, 0, "Tri Leg2");
      newBasket.t3 = trade.Buy(lot, Symbol3, ask3, 0, 0, "Tri Leg3");
   }
   
   if(newBasket.t1 && newBasket.t2 && newBasket.t3) {
      int sz = ArraySize(baskets);
      ArrayResize(baskets, sz+1);
      baskets[sz] = newBasket;
      last_trade = now;
      Print("🔥 Opened basket. Mispricing: ", mispricing, " pts | Lot: ", lot);
   } else {
      // Clean partial fills
      if(newBasket.t1) trade.PositionClose(newBasket.t1);
      if(newBasket.t2) trade.PositionClose(newBasket.t2);
      if(newBasket.t3) trade.PositionClose(newBasket.t3);
      Print("❌ Failed to open basket");
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
