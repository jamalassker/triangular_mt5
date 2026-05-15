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
//|                                        TickScalper_ProfitTarget  |
//|                Closes instantly at $0.50 profit                  |
//+------------------------------------------------------------------+
#property copyright "Scalper for $10 Cent Account"
#property version   "6.10"
#property strict

// --- Inputs ---
input double   InpRiskPercent        = 2.0;
input double   InpFixedLot           = 0.01;
input bool     InpUseAutoLot         = true;

input int      InpFastMA             = 10;
input int      InpSlowMA             = 30;
input int      InpRSIPeriod          = 7;
input int      InpRSIOverbought      = 65;
input int      InpRSIOversold        = 35;

input double   TargetProfitUSD       = 0.50;

// GOLD STOP LOSS
input double   InpStopLossPoints     = 3000;

input bool     InpUseTrailing        = false;
input int      InpTrailingStart      = 5;
input int      InpTrailingStep       = 3;

input int      InpMagicNumber        = 20251001;
input int      InpSlippage           = 20;
input bool     InpPrintLog           = true;

// --- Globals ---
int            fastMAHandle, slowMAHandle, rsiHandle;
double         fastMA[], slowMA[], rsi[];
int            expertMagic;
string         symbol;
double         pointValue, pipValue;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   symbol = Symbol();
   expertMagic = InpMagicNumber;

   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);
   pipValue = pointValue * 10;

   fastMAHandle = iMA(symbol, PERIOD_M1, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(symbol, PERIOD_M1, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle    = iRSI(symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);

   if(fastMAHandle == INVALID_HANDLE ||
      slowMAHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE)
   {
      return INIT_FAILED;
   }

   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(rsi, true);

   Print("Tick Scalper started on ", symbol,
         " | Profit Target: $", TargetProfitUSD);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(fastMAHandle);

   if(slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(slowMAHandle);

   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);

   Print("EA removed.");
}

//+------------------------------------------------------------------+
//| Tick Function                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   // Close positions instantly at profit target
   CheckAndCloseProfitablePositions();

   // Update indicators
   if(!UpdateIndicators())
      return;

   double fast   = fastMA[0];
   double slow   = slowMA[0];
   double rsiVal = rsi[0];

   bool uptrend   = fast > slow;
   bool downtrend = fast < slow;

   bool buySignal  = false;
   bool sellSignal = false;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   // BUY logic
   if(uptrend)
   {
      if(bid > fast || rsiVal < InpRSIOverbought)
         buySignal = true;
   }
   else
   {
      if(bid > fast && rsiVal < InpRSIOverbought)
         buySignal = true;
   }

   // SELL logic
   if(downtrend)
   {
      if(ask < fast || rsiVal > InpRSIOversold)
         sellSignal = true;
   }
   else
   {
      if(ask < fast && rsiVal > InpRSIOversold)
         sellSignal = true;
   }

   // One trade at a time
   if(CountOpenPositions() == 0)
   {
      if(buySignal)
         OpenBuy();

      if(sellSignal)
         OpenSell();
   }

   // Optional trailing
   if(InpUseTrailing)
      ManageTrailingStops();
}

//+------------------------------------------------------------------+
//| Open BUY                                                        |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double lotSize = CalculateLotSize();

   if(lotSize <= 0)
      return;

   double entry = SymbolInfoDouble(symbol, SYMBOL_ASK);

   // GOLD STOP LOSS
   double sl = entry - (InpStopLossPoints * pointValue);

   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillMode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;

   MqlTradeRequest req;
   MqlTradeResult  res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.volume       = lotSize;
   req.type         = ORDER_TYPE_BUY;
   req.price        = entry;
   req.sl           = NormalizeDouble(sl, _Digits);
   req.tp           = 0;
   req.deviation    = InpSlippage;
   req.magic        = expertMagic;
   req.comment      = "TickScalper BUY";
   req.type_filling = filling;

   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE ||
         res.retcode == TRADE_RETCODE_PLACED)
      {
         if(InpPrintLog)
            Print("BUY OPENED | Lot: ", lotSize,
                  " | Price: ", entry,
                  " | SL: ", req.sl);
      }
      else
      {
         Print("BUY rejected | Retcode: ", res.retcode);
      }
   }
   else
   {
      Print("BUY OrderSend failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Open SELL                                                       |
//+------------------------------------------------------------------+
void OpenSell()
{
   double lotSize = CalculateLotSize();

   if(lotSize <= 0)
      return;

   double entry = SymbolInfoDouble(symbol, SYMBOL_BID);

   // GOLD STOP LOSS
   double sl = entry + (InpStopLossPoints * pointValue);

   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillMode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      filling = ORDER_FILLING_FOK;
   else
      filling = ORDER_FILLING_RETURN;

   MqlTradeRequest req;
   MqlTradeResult  res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.volume       = lotSize;
   req.type         = ORDER_TYPE_SELL;
   req.price        = entry;
   req.sl           = NormalizeDouble(sl, _Digits);
   req.tp           = 0;
   req.deviation    = InpSlippage;
   req.magic        = expertMagic;
   req.comment      = "TickScalper SELL";
   req.type_filling = filling;

   if(OrderSend(req, res))
   {
      if(res.retcode == TRADE_RETCODE_DONE ||
         res.retcode == TRADE_RETCODE_PLACED)
      {
         if(InpPrintLog)
            Print("SELL OPENED | Lot: ", lotSize,
                  " | Price: ", entry,
                  " | SL: ", req.sl);
      }
      else
      {
         Print("SELL rejected | Retcode: ", res.retcode);
      }
   }
   else
   {
      Print("SELL OrderSend failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Close profitable positions                                      |
//+------------------------------------------------------------------+
void CheckAndCloseProfitablePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != expertMagic)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit >= TargetProfitUSD)
      {
         ClosePosition(ticket);

         if(InpPrintLog)
         {
            Print("PROFIT TARGET HIT | Ticket: ",
                  ticket,
                  " | Profit: $",
                  DoubleToString(profit, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close position                                                  |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   MqlTradeRequest req;
   MqlTradeResult  res;

   ZeroMemory(req);
   ZeroMemory(res);

   ENUM_POSITION_TYPE posType =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   req.action    = TRADE_ACTION_DEAL;
   req.position  = ticket;
   req.symbol    = symbol;
   req.volume    = PositionGetDouble(POSITION_VOLUME);
   req.deviation = InpSlippage;
   req.magic     = expertMagic;

   if(posType == POSITION_TYPE_BUY)
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(symbol, SYMBOL_BID);
   }
   else
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   }

   if(!OrderSend(req, res))
   {
      Print("Close failed: ", res.retcode);
   }
}

//+------------------------------------------------------------------+
//| Lot size                                                        |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double lot = InpFixedLot;

   if(InpUseAutoLot && InpRiskPercent > 0)
   {
      double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * InpRiskPercent / 100.0;

      double stopPips   = 10.0;
      double slDistance = stopPips * pipValue;

      double tickVal = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSiz = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

      double slTicks = slDistance / tickSiz;

      if(slTicks > 0 && tickVal > 0)
      {
         lot = riskAmount / (slTicks * tickVal);

         double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

         if(step > 0)
            lot = MathFloor(lot / step) * step;
      }
   }

   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   if(lot < minLot)
      lot = minLot;

   if(lot > maxLot)
      lot = maxLot;

   lot = NormalizeDouble(lot, 2);

   return lot;
}

//+------------------------------------------------------------------+
//| Count positions                                                 |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == expertMagic)
      {
         count++;
      }
   }

   return count;
}

//+------------------------------------------------------------------+
//| Trailing stop                                                   |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != expertMagic)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);

      int type = (int)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

         double profitPips = (bid - open) / pipValue;

         if(profitPips >= InpTrailingStart)
         {
            double newSL = bid - InpTrailingStep * pipValue;

            if(newSL > sl)
               ModifyStopLoss(ticket, newSL);
         }
      }
      else
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

         double profitPips = (open - ask) / pipValue;

         if(profitPips >= InpTrailingStart)
         {
            double newSL = ask + InpTrailingStep * pipValue;

            if(sl == 0 || newSL < sl)
               ModifyStopLoss(ticket, newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify stop loss                                                |
//+------------------------------------------------------------------+
void ModifyStopLoss(ulong ticket, double newSL)
{
   MqlTradeRequest req;
   MqlTradeResult  res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = symbol;
   req.sl       = newSL;
   req.tp       = PositionGetDouble(POSITION_TP);

   if(!OrderSend(req, res))
   {
      Print("Modify SL failed: ", res.retcode);
   }
}

//+------------------------------------------------------------------+
//| Update indicators                                               |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(fastMAHandle, 0, 0, 2, fastMA) < 2)
      return false;

   if(CopyBuffer(slowMAHandle, 0, 0, 2, slowMA) < 2)
      return false;

   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2)
      return false;

   return true;
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
