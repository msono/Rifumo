//+------------------------------------------------------------------+
//|                                     Rifumo RSI Pro Trader EA     |
//|                                  Copyright 2026, Gemini Adaptive |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

// --- EA Input Parameters ---
input bool              EnableTrading           = true;
input double            LotSize                 = 0.2;
input int               StopLoss                = 50;    //Fallback: stop loss
input int               StopLossOffset          = 10;
input int               TakeProfit              = 200;   
input int               MagicNumber             = 987654321;
input bool              EnableBreakEven         = true;
input int               BreakEvenOffset         = 20;

// --- Indicator Inputs ---
input int               RSIPeriod               = 14;    
input int               RSIHighLimit            = 80;    
input int               RSILowLimit             = 20;    
input ENUM_TIMEFRAMES   SDTimeframe             = PERIOD_M30;
input int               SDLookbackBars          = 300;   
input double            SDStrengthThreshold     = 2.0;   
input bool              UseDemandSupplyZones    = false;

// --- EMA Trend Re-entry Inputs ---
input int               EMA_Fast_Period         = 50;   // Fast EMA for Rejection
input int               EMA_Slow_Period         = 200;  // Slow EMA for Trend
input int               EMA_Signal_Period       = 10;           // EMA for the "Bounce" trigger
input ENUM_TIMEFRAMES   Trend_Filter_TF         = PERIOD_M15;
input int               MaximumPyramidPositions = 3; // Max number of additional re-entry trades
input bool              UseRSITrendFilter       = true;         // Optional RSI filter
input ENUM_TIMEFRAMES   RSI_Trend_TF            = PERIOD_M15;   // RSI Trend timeframe

// --- Risk Management Inputs ---
input double            MaxDailyRiskPercent     = 2.5;   // Max loss % per day (e.g., 2.5%)
input bool              ClosePositionsOnMaxRisk = true;  // Close all trades when limit is hit
input bool              EnableDailyRiskLimit    = false;
input bool              EnableDailyProfitTarget = false;  // Enable profit target check
input double            DailyProfitTargetPercent = 10.0;  // Target profit % per day

// --- Trailing Stop Inputs ---
input bool              EnableTrailingStop      = true; 
input int               TrailingStop            = 200;   
input int               TrailingStep            = 50;    
input int               ATR_Period              = 14;    // ATR Period for Trailing Stop
input double            ATR_Multiplier          = 2.0;   // ATR Multiplier for Trailing Distance

input ENUM_TIMEFRAMES   Main_TF                 = PERIOD_M1;    // EA execution timeframe

// --- Global Variables ---
CTrade trade;
int   handleRSI;
int   handleEMA50;
int   handleEMA200;
int   handleEMA10; // Handle for the 10 EMA bounce trigger
int   handleATR;

double upperBuffer[];
double lowerBuffer[];
datetime LastBarTime = 0;
string signalRsiValues;
long defaultStopLossLevel;

int PointsOffset = 10000;

double allowedLotSize;

enum ENUM_TRADE_SIGNAL { SIGNAL_BUY = 1, SIGNAL_SELL = -1, SIGNAL_NEUTRAL = 0 };

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   handleRSI = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);
   if(handleRSI == INVALID_HANDLE) return INIT_FAILED;
   
   //Onitialise TrendMovingAverage
   handleEMA50 = iMA(_Symbol, _Period, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA200 = iMA(_Symbol, _Period, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA10 = iMA(_Symbol, PERIOD_M1, EMA_Signal_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(handleEMA50 == INVALID_HANDLE || handleEMA200 == INVALID_HANDLE || handleEMA10 == INVALID_HANDLE) return INIT_FAILED;
   
   handleATR = iATR(_Symbol, _Period, ATR_Period);
   if(handleATR == INVALID_HANDLE) return INIT_FAILED;
   
   trade.SetExpertMagicNumber(MagicNumber);
   
   // Get the broker's minimum stop distance (in points)
   defaultStopLossLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   
   Print("Verified Minimum Stop Level: ", IntegerToString(defaultStopLossLevel));
   
   allowedLotSize = CalculateValidLot();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Main Tick Function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // High Priority: Check Daily Drawdown Limit
    if(IsDailyRiskLimitReached()) 
    {
         static bool limitNotified = false;
         if(!limitNotified) {
            Print("Trading disabled for the day: Daily Risk Limit Reached.");
            limitNotified = true;
         }
         return;
    }
    
    if(!IsNewBar())
    {
        if (EnableBreakEven) CheckBreakEven();
        if (EnableTrailingStop) ManageTrailingStop();
        return;
    }
    
   if (!EnableTrading) return;

    string symbolName = _Symbol;

    // 1. Get Rsi Signal (Primary))
    ENUM_TRADE_SIGNAL rsiSignal = CheckSignal();
    
    // 2. Get EMA Re-entry Signal
    ENUM_TRADE_SIGNAL emaReentry = CheckEMAReentrySignal();
    
    // Map signal to position type
    ENUM_POSITION_TYPE targetType = (rsiSignal == SIGNAL_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
    
    // Count only positions of the current signal direction
    int specificTypeCount = CountCurrentPositions(targetType);
    
    // Primary RSI Entry
    if(rsiSignal != SIGNAL_NEUTRAL)
    {
        string comment = (specificTypeCount == 0) ? "Primary RSI Entry" : "Seconday/Re-entry Pyramid RSI. " + signalRsiValues;
        ExecuteTrade(rsiSignal, comment);
    }
    
    //3. PYRAMID RE-ENTRY (EMA Trend & RSI Alignment)
    // Only enters when RSI aligns AND EMA rejection occurs AND current trades are in profit
    if(emaReentry != SIGNAL_NEUTRAL && rsiSignal == emaReentry)
    {
         if(specificTypeCount > 0 && specificTypeCount <= MaximumPyramidPositions)
         {
             if(AreAllCurrentPositionsInProfit())
             {
                  // Verify we are adding to the SAME direction
                  bool existingBuy = false;
                  bool existingSell = false;
                  
                  for(int i=0; i<PositionsTotal(); i++) {
                     if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                        if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) existingBuy = true;
                        if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) existingSell = true;
                     }
                  }
      
                  if((emaReentry == SIGNAL_BUY && existingBuy) || (emaReentry == SIGNAL_SELL && existingSell))
                  {
                      ExecuteTrade(emaReentry, "EMA Re-entry Pyramid");
                  }       
             }
         }
    }
}

//+------------------------------------------------------------------+
//| Management Logic (1:1 Risk Reward Filter)                        |
//+------------------------------------------------------------------+
void CheckBreakEven()
{
   //Move the Stop Loss of all positions to the open price of the latest (most recent) trade once the 1:1 Risk/Reward is hit

    double latestOpenPrice = 0;
    datetime latestTime = 0;

    // First: Find the open price of the most recent position
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetSymbol(i) == _Symbol)
            {
                datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
                if(posTime > latestTime)
                {
                    latestTime = posTime;
                    latestOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                }
            }
        }
    }

    if(latestOpenPrice == 0) return;

    // Second: Apply BreakEven logic and sync all trades to that latest entry
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) != MagicNumber || PositionGetSymbol(i) != _Symbol) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double initialRiskPrice = MathAbs(openPrice - currentSL);
            if(initialRiskPrice <= 0) initialRiskPrice = StopLoss * _Point;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
                // If the LATEST trade is at 1:1 RR, move ALL trades to latest entry
                if((bid - latestOpenPrice) >= (initialRiskPrice - (_Point / 2.0)))
                {
                    double newSL = NormalizeDouble(latestOpenPrice + (BreakEvenOffset * _Point), _Digits);
                    if(currentSL < newSL) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
            else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
                if((latestOpenPrice - ask) >= (initialRiskPrice - (_Point / 2.0)))
                {
                    double newSL = NormalizeDouble(latestOpenPrice - (BreakEvenOffset * _Point), _Digits);
                    
                    if(currentSL > newSL || currentSL == 0) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trailing Stop Loss Based on ATR                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!EnableTrailingStop) return;

    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(handleATR, 0, 0, 1, atrBuffer) < 1) return;
    
    // Calculate dynamic trailing distance in points
    double currentATR = atrBuffer[0];
    double trailingDistPoints = (currentATR * ATR_Multiplier) / _Point;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) != MagicNumber || PositionGetSymbol(i) != _Symbol) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            double initialRiskPrice = MathAbs(openPrice - currentSL);
            if(initialRiskPrice <= 0) initialRiskPrice = StopLoss * _Point;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
                double currentProfitPrice = (bid - openPrice);
                
                // 1:1 RR reached AND profit is greater than ATR-based Trailing Distance [cite: 75]
                if(currentProfitPrice >= (initialRiskPrice - (_Point / 2.0)) && currentProfitPrice > (trailingDistPoints * _Point))
                {
                    double newSL = NormalizeDouble(bid - (trailingDistPoints * _Point), _Digits);
                    
                    // Only modify if the new SL is higher than current SL plus the TrailingStep [cite: 76]
                    if(newSL > currentSL + TrailingStep * _Point) 
                        trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
            else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
                double currentProfitPrice = (openPrice - ask);
                
                // 1:1 RR reached AND profit is greater than ATR-based Trailing Distance
                if(currentProfitPrice >= (initialRiskPrice - (_Point / 2.0)) && currentProfitPrice > (trailingDistPoints * _Point))
                {
                    double newSL = NormalizeDouble(ask + (trailingDistPoints * _Point), _Digits);
                    
                    // Only modify if new SL is lower than current SL (or if SL is 0)
                    if(newSL < currentSL - TrailingStep * _Point || currentSL == 0) 
                        trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Core Helpers                                                     |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentTime = iTime(_Symbol, _Period, 0);
    if(currentTime != LastBarTime) { LastBarTime = currentTime; return true; }
    return false;
}

//+------------------------------------------------------------------+
//| Primary RSI Signal Logic                                         |
//+------------------------------------------------------------------+
ENUM_TRADE_SIGNAL CheckSignal()
{
    signalRsiValues = "";
    
    double rsiBuffer[];
    ArraySetAsSeries(rsiBuffer, true);
    if(CopyBuffer(handleRSI, 0, 0, 3, rsiBuffer) < 3) return SIGNAL_NEUTRAL;

    ENUM_TRADE_SIGNAL rawSignal = SIGNAL_NEUTRAL;
    if (rsiBuffer[2] <= RSIHighLimit && rsiBuffer[1] > RSIHighLimit) 
    { 
       Print("rsiBuffer[2]: {" + DoubleToString(rsiBuffer[2],2) + "} <= RSIHighLimit: {" + IntegerToString(RSIHighLimit) + "} && rsiBuffer[1]: {" + DoubleToString(rsiBuffer[1],2) + "} > RSIHighLimit: {" + IntegerToString(RSIHighLimit) + "}");
       
       rawSignal = SIGNAL_SELL;
    }
    else if (rsiBuffer[2] >= RSILowLimit && rsiBuffer[1] < RSILowLimit) 
    { 
      signalRsiValues = "rsiBuffer[2]: {" + DoubleToString(rsiBuffer[2],2) + "}. rsiBuffer[1]: {" + DoubleToString(rsiBuffer[1],2) + "}";
      
      rawSignal = SIGNAL_BUY;
    }
    
    if(rawSignal != SIGNAL_NEUTRAL)
    {
         signalRsiValues = ". rsiBuffer[2]: {" + DoubleToString(rsiBuffer[2],2) + "}. rsiBuffer[1]: {" + DoubleToString(rsiBuffer[1],2) + "}. UseDemandSupplyZones = {" + (UseDemandSupplyZones ? "true" : "false") + "}. IsInSDZone => {" + (IsInSDZone(rawSignal)  ? "true" : "false") + "}";
    }
    
    if(rawSignal == SIGNAL_NEUTRAL) return SIGNAL_NEUTRAL;
    
    if (UseDemandSupplyZones && !IsInSDZone(rawSignal)) return SIGNAL_NEUTRAL;
    
    return rawSignal;
}

//+------------------------------------------------------------------+
//| Supply & Demand Zone Check In Higher TF                                       |
//+------------------------------------------------------------------+
bool IsInSDZone(ENUM_TRADE_SIGNAL type)
{
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if(CopyRates(_Symbol, SDTimeframe, 0, SDLookbackBars, rates) < SDLookbackBars) return false;
    double price = (type == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    for(int i = 1; i < SDLookbackBars - 1; i++)
    {
        double bodySize = MathAbs(rates[i].open - rates[i].close);
        double prevBody = MathAbs(rates[i+1].open - rates[i+1].close);
        if(type == SIGNAL_BUY && rates[i].close > rates[i].open && bodySize > prevBody * SDStrengthThreshold)
        {
            if(price <= rates[i].high && price >= rates[i].low) return true;
        }
        if(type == SIGNAL_SELL && rates[i].close < rates[i].open && bodySize > prevBody * SDStrengthThreshold)
        {
            if(price >= rates[i].low && price <= rates[i].high) return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Check MA Rejection (Secondary Signal for Pyramiding)             |
//+------------------------------------------------------------------+
ENUM_TRADE_SIGNAL CheckEMAReentrySignal()
{
    double ema10[], ema50[], ema200[], rsi15m[];
    MqlRates ratesM1[];
    
    ArraySetAsSeries(ema10, true);
    ArraySetAsSeries(ema50, true);
    ArraySetAsSeries(ema200, true);
    ArraySetAsSeries(ratesM1, true);
    ArraySetAsSeries(rsi15m, true);

    // 1. Fetch 1M EMA and Price data
    if(CopyBuffer(handleEMA10, 0, 0, 2, ema10) < 2 || 
       CopyBuffer(handleEMA50, 0, 0, 1, ema50) < 1 || 
       CopyBuffer(handleEMA200, 0, 0, 1, ema200) < 1 || 
       CopyRates(_Symbol, PERIOD_M1, 0, 2, ratesM1) < 2) 
        return SIGNAL_NEUTRAL;

    // 2. Determine 1M Trend
    bool isBullishTrend = (ema50[0] > ema200[0]); 
    bool isBearishTrend = (ema50[0] < ema200[0]);

    // 3. Optional 15M RSI Trend Confirmation
    if(UseRSITrendFilter)
    {
        if(CopyBuffer(handleRSI, 0, 0, 1, rsi15m) < 1) return SIGNAL_NEUTRAL;
        
        if(isBullishTrend && rsi15m[0] <= 50) return SIGNAL_NEUTRAL; // Reject buy if RSI not > 50
        if(isBearishTrend && rsi15m[0] >= 50) return SIGNAL_NEUTRAL; // Reject sell if RSI not < 50
    }

    // 4. 10 EMA Bounce Trigger Logic
    // Buy: Trend is Up + Previous candle low touched/went below 10 EMA + Current close above 10 EMA
    if(isBullishTrend && ratesM1[1].low <= ema10[0] && ratesM1[1].close > ema10[0])
        return SIGNAL_BUY;

    // Sell: Trend is Down + Previous candle high touched/went above 10 EMA + Current close below 10 EMA
    if(isBearishTrend && ratesM1[1].high >= ema10[0] && ratesM1[1].close < ema10[0])
        return SIGNAL_SELL;

    return SIGNAL_NEUTRAL;
}

//+------------------------------------------------------------------+
//| Trade Execution Helper with Stop Loss/Lot Logic                  |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_TRADE_SIGNAL signal, string comment)
{
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    
    // Get ATR value for dynamic SL
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(handleATR, 0, 0, 1, atrBuffer) < 1) return;
    
    double currentATR = atrBuffer[0]; 
    double slDistance = currentATR * ATR_Multiplier; 

    if(signal == SIGNAL_BUY && AssetSpikesUp())
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        
        // Calculate SL based on ATR distance
        double slPrice = NormalizeDouble(MathRound((ask - slDistance) / tickSize) * tickSize, digits); 
        
        // Calculate TP (keeping existing logic or 3:1 ratio)
        long usedTPPoints = (TakeProfit < defaultStopLossLevel && TakeProfit > 0) ? (defaultStopLossLevel + (PointsOffset*3)) : TakeProfit;
        double tpPrice = (TakeProfit > 0) ? NormalizeDouble(MathRound((ask + usedTPPoints * _Point) / tickSize) * tickSize, digits) : 0;

        // Ensure SL is below entry
        if(slPrice >= ask) slPrice = NormalizeDouble(ask - (defaultStopLossLevel + 100) * _Point, digits);
        
        trade.Buy(allowedLotSize, _Symbol, ask, slPrice, tpPrice, comment);
    }
    else if(signal == SIGNAL_SELL && AssetSpikesDown())
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        
        // Calculate SL based on ATR distance
        double slPrice = NormalizeDouble(MathRound((bid + slDistance) / tickSize) * tickSize, digits);
        
        // Calculate TP
        long usedTPPoints = (TakeProfit < defaultStopLossLevel && TakeProfit > 0) ? (defaultStopLossLevel + (PointsOffset*3)) : TakeProfit;
        double tpPrice = (TakeProfit > 0) ? NormalizeDouble(MathRound((bid - usedTPPoints * _Point) / tickSize) * tickSize, digits) : 0;
         
         double minStopDistance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         
         PrintFormat("Bid: %.5f | Ask: %.5f | Calculated SL: %.5f | Min Distance Needed: %.5f", 
         bid, SymbolInfoDouble(_Symbol, SYMBOL_ASK), slPrice, minStopDistance);         
         
        // Ensure SL is above entry
        //if(slPrice <= bid) slPrice = NormalizeDouble(bid + (defaultStopLossLevel + 100) * _Point, digits);
        
        // Ensure SL is above entry for a SELL (use Ask to account for spread)
         double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         if(slPrice <= bid + minStopLevel) 
         {
             slPrice = NormalizeDouble(ask + (defaultStopLossLevel * _Point) + minStopLevel, digits);
         }
        
        trade.Sell(allowedLotSize, _Symbol, bid, slPrice, tpPrice, comment);
    }
}

//+------------------------------------------------------------------+
//| Check Whether All Current Positions Are In Profit                |
//+------------------------------------------------------------------+
bool AreAllCurrentPositionsInProfit()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            // Filter by Magic Number and Symbol 
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetSymbol(i) == _Symbol)
            {
                count++;
                // If any single position has negative profit, return false immediately
                if(PositionGetDouble(POSITION_PROFIT) < 0) 
                    return false; 
            }
        }
    }
    // Return true only if we actually have positions and they are all in profit
    return (count > 0);
}

//+------------------------------------------------------------------+
//| DailyRisk Limit Reached              |
//+------------------------------------------------------------------+
bool IsDailyRiskLimitReached()
{
    // If the limit is disabled via input, always return false to allow trading
    if(!EnableDailyRiskLimit) return false;

    double dailyPnL = 0;
    datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);

    // 1. Calculate Realized Profit/Loss for Today
    if(HistorySelect(todayStart, TimeCurrent()))
    {
        for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber)
            {
                dailyPnL += HistoryDealGetDouble(ticket, DEAL_PROFIT);
                dailyPnL += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
                dailyPnL += HistoryDealGetDouble(ticket, DEAL_SWAP);
            }
        }
    }

    // 2. Add Unrealized Profit/Loss (Floating)
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                dailyPnL += PositionGetDouble(POSITION_PROFIT);
            }
        }
    }

    // 3. Compare against Daily Balance
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double maxLossAmount = -(accountBalance * (MaxDailyRiskPercent / 100.0));

    if(dailyPnL <= maxLossAmount)
    {
        PrintFormat("Daily Risk Limit Reached! PnL: %.2f, Limit: %.2f", dailyPnL, maxLossAmount);
        
        // Emergency closure of positions automated "circuit breaker," 
        // hard-closing trades to prevent a minor breach from becoming a total account failure
        if(ClosePositionsOnMaxRisk && PositionsTotal() > 0)
        {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                ulong ticket = PositionGetTicket(i);
                if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
                    trade.PositionClose(ticket);
            }
        }
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Invalidate lot size              |
//+------------------------------------------------------------------+
double CalculateValidLot()
{
    // Fetch asset constraints
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    // 1. Adjust the lot size to the nearest allowed step
    double normalizedLot = MathFloor(LotSize / lotStep) * lotStep;

    // 2. Ensure the lot is within the broker's min/max bounds
    if(normalizedLot < minLot) normalizedLot = minLot;
    if(normalizedLot > maxLot) normalizedLot = maxLot;

    return normalizedLot;
}

//+------------------------------------------------------------------+
//| Verify Boom/Gain              |
//+------------------------------------------------------------------+
bool AssetSpikesUp() 
{
   printf(_Symbol);
   
   return (StringFind(_Symbol, "Boom") >= 0) ||
         (StringFind(_Symbol, "Gain") >= 0);
}

//+------------------------------------------------------------------+
//| Verify Crash/Pain              |
//+------------------------------------------------------------------+
bool AssetSpikesDown() 
{
   printf(_Symbol);
   
   return (StringFind(_Symbol, "Crash") >= 0) ||
         (StringFind(_Symbol, "Pain") >= 0); 
}

//+------------------------------------------------------------------+
//| CountCurrent Open Positions             |
//+------------------------------------------------------------------+
int CountCurrentPositions(ENUM_POSITION_TYPE type)
{
    int count = 0;
    // Iterate through all open positions
    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            // Filter by Magic Number, Symbol, and the specific Trade Type
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
               PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_TYPE) == type)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| IsDailyProfitTargetReached                                       |
//+------------------------------------------------------------------+
bool IsDailyProfitTargetReached()
{
    if(!EnableDailyProfitTarget) return false;

    double dailyPnL = 0;
    datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);

    // 1. Calculate Realized Profit/Loss for Today
    if(HistorySelect(todayStart, TimeCurrent()))
    {
        for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber)
            {
                dailyPnL += HistoryDealGetDouble(ticket, DEAL_PROFIT);
                dailyPnL += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
                dailyPnL += HistoryDealGetDouble(ticket, DEAL_SWAP);
            }
        }
    }

    // 2. Add Unrealized Profit/Loss (Floating)
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                dailyPnL += PositionGetDouble(POSITION_PROFIT);
            }
        }
    }

    // 3. Compare against Daily Balance
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double targetAmount = accountBalance * (DailyProfitTargetPercent / 100.0);

    if(dailyPnL >= targetAmount)
    {
        static bool targetNotified = false;
        if(!targetNotified) {
            PrintFormat("Daily Profit Target Reached! PnL: %.2f, Target: %.2f", dailyPnL, targetAmount);
            targetNotified = true;
        }
        return true;
    }

    return false;
}