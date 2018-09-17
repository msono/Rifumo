//+-----------------------------------------------------------------------------+
//|                                                          RifumoEA.mq4       |
//|                                                    Copyright © 2017, Migsta |
//+-----------------------------------------------------------------------------+
#include <stdlib.mqh> 

#property copyright "Copyright 2017, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#define SIGNAL_CLOSEBUY       5
#define SIGNAL_CLOSESELL      6

#define  HIGH_IMPACT_NEWS     3
#define  NEWS_CAL_IND         "FFC"
#define  NEWS_CAL_IND_TST     "FFC_Mock"

#define  DEFAULT_SLIPPAGE     5
#define  MAX_RETRIES          3

string OrderManagementSettings         = "========================= Order Management =============================";
extern bool    MoneyManagement         = true;
extern double  LotSize                 = 0.01;
extern int     DistanceFromPrice       =  30;                  // Initial distance from price for the 2 pending orders and/or support & resistance
extern int     StopLossInPips          =  30;                  // Initial stop loss. 
extern int     TakeProfitInPips        =  90;                  // Initial stop loss. 
extern int     TrailPips               =  10;                  // Trail for HighImpact
extern bool    IsMiniAccount           = true;
extern bool    UseBreakEven            = true;
extern bool    UseTrailingStop         = true;
extern bool    UseStealthMode          = true;
extern string  NewsSettings            =  "=============== News Settings =============== ";
extern int     SecondsBeforeNews       =  300;
extern string  SignalSettings          =  "=============== Signalling Settings =============== ";


int  RETRY_INTERVAL=2000;

//"=============== ChannelSurfer Settings  =============== ";
int     AllBars                     =  240;
int     BarsForFract                =  0;

//"================= AFI_Stochastic Settings =============== ";
int     length                      =  7;
double  Filter                      =  0;
int     OverBoughtLine              =  80;
int     OverSoldLine                =  20;
int     KPeriod                     =  5;
int     DPeriod                     =  3;
int     slowing                     =  3;

//"=============== Zig Zag =============== ";
double  ExtDepth                    =  17;
double  ExtDeviation                =  7;
double  ExtBackstep                 =  5;

double  ExtDepth_D1                 =  12;
double  ExtDeviation_D1             =  5;
double  ExtBackstep_D1              =  3;

/*
use zigzag 17,7,5 in all time frame, H1,M30,M15, M1
use zigzag 12,5,3 in D1,
*/

//Internals
string comment=" RifumoEA",EAName="RifumoEA v1.00";
double mCurrentOpen,mCurrentHigh,mCurrentLow,mCurrentClose;
datetime mTime;
int barOffset=1;
string module="";

int ARROW_DOWN=234;
int ARROW_UP=233;

datetime signalTimes[1000];
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
enum tradingStrategy
  {
   News,
   DayTrading,
   SessionBreak,
   WeeklyBasket,
   DayTrading_TradeLocator
  };
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
struct rifumoOrder
  {
   int               ticketNumber;
   double            orderPrice;
   double            stopLoss;
   double            takeProfit;
   double            breakEven;
  };
rifumoOrder highImpactOrders[];
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
struct tickData
  {
   double            open;
   double            high;
   double            low;
   double            close;
   double            time;
   int               trend;
  };
tickData currentTickData;
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasHighImpactTrades()
  {
   return ArraySize(highImpactOrders)>0;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
static datetime mLastBarTime;
int mCurrentBar=0;
datetime lastOnTimerExecution;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {

   module="OnInit()";   //Print(module);
   if(Period()!=60)
     {
      Alert("Only Use H1.");
      return(INIT_FAILED);
     }

   Print("MODE_LOTSIZE = ",MarketInfo(Symbol(),MODE_LOTSIZE),", Symbol = ",Symbol());
   Print("MODE_MINLOT = ",MarketInfo(Symbol(),MODE_MINLOT),", Symbol = ",Symbol());
   Print("MODE_LOTSTEP = ",MarketInfo(Symbol(),MODE_LOTSTEP),", Symbol = ",Symbol());
   Print("MODE_MAXLOT = ",MarketInfo(Symbol(),MODE_MAXLOT),", Symbol = ",Symbol());

//--- create timer
   EventSetTimer(60);

   if(IsTesting())
     {
      OnTimer();
      lastOnTimerExecution=TimeCurrent();
     }

   mLastBarTime=0;

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {

   module="OnDeinit()"; //Print(module);
   EventKillTimer();

  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//module="OnTick()";   Print(module);
   mCurrentBar++;

   if(!IsNewBar()) return;

   SetTickData();

   TradeManagement();

   PrepareChannelSurfer();

   VerifiedTradeOpportunities();
  }
//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   module="OnTimer()"; //Print(module);
   HandleHighImpactOrders();

   if(NewsTime() || SessionOpen())
     {
      SetTradeLevels();

      StraddleTrades();
     }

  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBar=Time[0];
   if(mLastBarTime!=currentBar)
     {
      mLastBarTime=currentBar;
      return (true);
     }

   else
     {
      return(false);
     }
  }
//*******************************************************************
// Trade Management functions
//*******************************************************************
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool StraddleTrades(string symbol="",int slippage=0,tradingStrategy strategy=News)
  {

   module="StraddleTrades";   //Print(module);
/*
   OrderSend(NULL,OP_BUYSTOP,lotku,(Ask+jarak1),Slippage,(Ask-SL),(Ask+TP1),"News",MagicNumber,(TimeCurrent()+900),Blue);
   OrderSend(NULL,OP_BUYSTOP,lotku,(Ask+jarak2),Slippage,(Ask-SL),(Ask+TP1),"News",MagicNumber,(TimeCurrent()+900),Blue);
   OrderSend(NULL,OP_BUYSTOP,lotku,(Ask+jarak3),Slippage,(Ask-SL),(Ask+TP1),"News",MagicNumber,(TimeCurrent()+900),Blue);
   
   OrderSend(NULL,OP_SELLSTOP,lotku,(Bid-jarak1),Slippage,(Bid+SL),(Bid-TP1),"News",MagicNumber2,(TimeCurrent()+900),Blue);
   OrderSend(NULL,OP_SELLSTOP,lotku,(Bid-jarak2),Slippage,(Bid+SL),(Bid-TP1),"News",MagicNumber2,(TimeCurrent()+900),Blue);
   OrderSend(NULL,OP_SELLSTOP,lotku,(Bid-jarak3),Slippage,(Bid+SL),(Bid-TP1),"News",MagicNumber2,(TimeCurrent()+900),Blue);  
  */

   datetime orderExpiryTime=GetOrderExpiryTime();
   double lotSize=LotsOptimized();

   if(StopLossInPips==0) { StopLossInPips=999; }
   if(TakeProfitInPips==0) { TakeProfitInPips=999; }

   double shortEntryPrice=NormalizeDouble(Bid-(DistanceFromPrice*Point),Digits),
   shortEntryPriceSL=NormalizeDouble(shortEntryPrice+(StopLossInPips*Point),Digits),
   shortEntryPriceTP=NormalizeDouble(shortEntryPrice-(TakeProfitInPips*Point),Digits);

   double longEntryPrice=NormalizeDouble(Ask+(DistanceFromPrice*Point),Digits),
   longEntryPriceSL=NormalizeDouble(longEntryPrice-(StopLossInPips*Point),Digits),
   longEntryPriceTP=NormalizeDouble(longEntryPrice+(TakeProfitInPips*Point),Digits);

   int retryCount=0;

   if(symbol=="") { symbol=Symbol(); }
   if(slippage==0) { slippage=GetSlippage(); }

   string orderComment=GetOrderComment(strategy);

   while((retryCount<MAX_RETRIES) && !IsTradeAllowed()) { retryCount++; Sleep(RETRY_INTERVAL); }
   RefreshRates();
   if(!PlaceOrder(symbol,OP_SELLSTOP,lotSize,shortEntryPrice,slippage,shortEntryPriceSL,shortEntryPriceTP,orderComment,GetMagicNumber(Symbol(),Period()),orderExpiryTime,0,true))
     {
      Print("Error opening SellStop  ",ErrorDescription(GetLastError()),"  Ask=",Ask,"   Bid=",Bid,"   Entry @ ",shortEntryPrice,"   SL=",shortEntryPriceSL,"    TP=",shortEntryPriceTP);
     }
   retryCount=0;
   while((retryCount<MAX_RETRIES) && !IsTradeAllowed()) {retryCount++; Sleep(RETRY_INTERVAL); }
   RefreshRates();
   if(!PlaceOrder(symbol,OP_BUYSTOP,lotSize,longEntryPrice,slippage,longEntryPriceSL,longEntryPriceTP,orderComment,GetMagicNumber(Symbol(),Period()),orderExpiryTime,0,true))
     {
      Print("Error opening BuyStop  ",ErrorDescription(GetLastError()),"  Ask=",Ask,"   Bid=",Bid,"   Entry @ ",longEntryPrice,"   SL=",longEntryPriceSL,"    TP=",longEntryPriceTP);
     }

   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetSlippage(string symbol=EMPTY_VALUE)
  {
   if(IsTesting()) return (DEFAULT_SLIPPAGE*10);
   return 0;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double LotsOptimized()
  {
   module="LotsOptimized"; //Print(module);
                           //TODO: Add LotSize Calculation based on Account size/type e.tc.
   return LotSize;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandleHighImpactOrders()
  {
   module="HandleHighImpactOrders"; //Print(module);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TradeManagement(int signal=EMPTY_VALUE)
  {
   module="TradeManagement";  //Print(module);
   int lastKnownGood=0;
   double entryPrice=EMPTY_VALUE;
   if(HasTradeSignal(entryPrice,signal)) CloseIfNotInProfit(entryPrice);

// Hidden stop loss
   if(UseStealthMode) HiddenStopLoss();
   lastKnownGood++;

// Hidden take profit
   if(UseStealthMode) HiddenTakeProfit();
   lastKnownGood++;

// Breakeven
   if(UseBreakEven) BreakEvenStopLoss();
   lastKnownGood++;

//TrailingStop
   if(UseTrailingStop) TrailingStopLoss();

  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool PlaceOrder(string symbol,int orderType,double lotSize,double orderPrice,int slippage,double stopLoss,double takeProfit,string orderComment,int magicNumber,datetime expiryDate,double breakEvenAt=0,bool isHighImpactTrade=false)
  {
   module="PlaceOrder()";  //Print(module);
   Print("Place Order Gets {"+symbol+","+orderType+","+lotSize+","+orderPrice+","+slippage+","+stopLoss+","+takeProfit+","+orderComment+","+magicNumber+","+expiryDate+"}");

   int ticketNumber=OrderSend(symbol,orderType,lotSize,orderPrice,slippage,stopLoss,takeProfit,orderComment,magicNumber,expiryDate,GetOrderColor(orderType));
   if(ticketNumber>0)
     {
      //TODO: Change SL & TP
      if(UseStealthMode)
        {
        }
      else
        {
        }
     }
   return ticketNumber>0;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TrailingStopLoss()
  {
   module="TrailingStopLoss()";  //Print(module);
                                 //TODO: TrailingStopLoss
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BreakEvenStopLoss()
  {
   module="BreakEvenStopLoss()"; //Print(module);
                                 //TODO: BreakEvenStopLoss
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HiddenTakeProfit()
  {
   module="HiddenTakeProfit()";  //Print(module);
                                 //TODO: HiddenTakeProfit
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HiddenStopLoss()
  {
   module="HiddenStopLoss()"; //Print(module);
                              //TODO: HiddenStopLoss
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CloseIfNotInProfit(double &signalPrice,string symbol="")
  {
   module="CloseIfNotInProfit()";
   int trades=OrdersTotal();
   int trade,barCount=0;

   for(trade=0;trade<trades;trade++)
      //+------------------------------------------------------------------+
      //|                                                                  |
      //+------------------------------------------------------------------+
     {
      if(OrderSelect(trade,SELECT_BY_POS,MODE_TRADES))
        {
         string orderComment=OrderComment();
         bool matchedOrder=(symbol!="" ?(OrderSymbol()==symbol && IsOrderPlacedByEA(orderComment)) :  IsOrderPlacedByEA(orderComment));
         if(matchedOrder)
           {
            //TODO: Close Order
           }
        }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ModifyStopLoss(int ticketNumber,double newStopLoss,bool stealthMode=false)
  {
   module="ModifyStopLoss";   //Print(module);
   bool modifyOrderResult;
   if(!stealthMode)
     {
      modifyOrderResult=OrderModify(ticketNumber,OrderOpenPrice(),newStopLoss,OrderTakeProfit(),0,CLR_NONE);
     }
   else
     {
      //TODO: set virtual SL
     }
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ModifyTakeProfit(int ticketNumber,double newTakeProfit,bool stealthMode=false)
  {
   module="ModifyTakeProfit"; //Print(module);
   bool modifyOrderResult;
   if(!stealthMode)
     {
      modifyOrderResult=OrderModify(ticketNumber,OrderOpenPrice(),OrderStopLoss(),newTakeProfit,0,CLR_NONE);
     }
   else
     {
      //TODO: set virtual TP
     }
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ModifyOrderExpiryDate(int ticketNumber,datetime orderExpiryTime)
  {
   module="ModifyOrderExpiryDate";  //Print(module);
   bool modifyOrderResult=OrderModify(ticketNumber,OrderOpenPrice(),OrderStopLoss(),OrderTakeProfit(),orderExpiryTime,CLR_NONE);
   return modifyOrderResult;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CloseOrder(int ticketNumber)
  {
   module="CloseOrder"; //Print(module);
   int lastError;
   bool result,isPending;
   if(!TryGetIsPendingOrder(ticketNumber,isPending))
     {
      lastError=GetLastError();
      Print("LastError = ",lastError);
      return false;
     }

   if(isPending)
     {
      result=OrderDelete(ticketNumber,CLR_NONE);
     }
   else
     {
      result=OrderClose(ticketNumber,OrderLots(),OrderOpenPrice(),0,CLR_NONE);
     }

   if(result!=true)
     {
      lastError=GetLastError();
      Print("LastError = ",lastError);
     }
   else
     {
      lastError=0;
     }

   if(lastError==135) RefreshRates();

   return result;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetTradeLevels()
  {
//TODO: Set Broker's specs (MIN_SL, MIN_TP, LotSize e.t.c)
   module="SetTradeLevels";   //Print(module);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool TryGetIsPendingOrder(int ticketNumber,bool &result)
  {
   module="TryGetIsPendingOrder";   //Print(module);
   ResetLastError();
   if(OrderSelect(ticketNumber,SELECT_BY_TICKET))
     {
      return (OrderType()==OP_BUYLIMIT ||
              OrderType() == OP_BUYSTOP ||
              OrderType() == OP_SELLLIMIT ||
              OrderType() == OP_SELLSTOP);
     }
   Print(StringConcatenate(module," = ",ErrorDescription(GetLastError())));
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime GetOrderExpiryTime()
  {
   datetime expiryDate=(Time[0]+SecondsBeforeNews);
   if(expiryDate>Time[0]) return expiryDate;
   return 0;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetMagicNumber(string currencyPair="",int currencyPeriod=0)
  {
//TODO: Use Symbol_OrderComment_Strategy as first part of MagicNumber

   if(currencyPair=="") currencyPair=Symbol();
   if(currencyPeriod==0) currencyPeriod=Period();

   return (1000+currencyPeriod);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetStopLoss(int orderType)
  {
   module="GetStopLoss";
   RefreshRates();

   double calcStopLoss;
   if(StopLossInPips==0) { StopLossInPips=999; }
   if(orderType==OP_SELL)
     {
      calcStopLoss=NormalizeDouble(Bid+(StopLossInPips*Point),Digits);
     }
   else
     {
      calcStopLoss=NormalizeDouble(Ask-(StopLossInPips*Point),Digits);
     }
   return calcStopLoss;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetTakeProfit(int orderType)
  {
   module="GetTakeProfit";
   RefreshRates();

   double calcTakeProfit;
   if(TakeProfitInPips==0) { TakeProfitInPips=999; }

   if(orderType==OP_SELL)
     {
      calcTakeProfit=NormalizeDouble(Bid-(TakeProfitInPips*Point),Digits);
     }
   else
     {
      calcTakeProfit=NormalizeDouble(Ask+(TakeProfitInPips*Point),Digits);
     }
   return calcTakeProfit;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int defaultSlippage=5;
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetSpread(string symbol=EMPTY_VALUE)
  {
   module="GetSpread";
   ResetLastError();
   if(symbol!=EMPTY_VALUE)
     {
      if(symbol!=Symbol())
        {
         return MarketInfo(symbol,MODE_SPREAD);
        }
      else
        {
         return ((Ask-Bid)/Point);
        }
     }

   return 0;
  }
//*******************************************************************
// END:// Trade Management functions
//*******************************************************************

//*******************************************************************
// Signalling functions
//*******************************************************************
bool IsValidOrder(int inputSignal)
  {
   return (inputSignal==OP_BUY || inputSignal==OP_SELL);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int VerifiedTradeOpportunities()
  {
   module="VerifiedTradeOpportunities"; //Print(module);
   int newTradeSignal=EMPTY_VALUE;
   double entryPrice=EMPTY_VALUE;

//Get trend using Slope of Channel surfer
   int slope=GetCurrentTrend();

   if(HasTradeSignal(entryPrice,newTradeSignal))
     {
     
     if (IsSpecialCase()) PrintFormat("Got signal {%s} @ {%d}",SignalTextFromId(newTradeSignal),entryPrice);
     
      //TODO: Continuation: slope and signal agree

      double stopLoss=GetStopLoss(newTradeSignal),
      takeProfit=GetTakeProfit(newTradeSignal),
      lotSize=LotsOptimized();

      if(HasValue(entryPrice))
        {
         if(!PlaceOrder(Symbol(),OP_SELLSTOP,lotSize,entryPrice,GetSlippage(),stopLoss,takeProfit,GetOrderComment(DayTrading),GetMagicNumber(Symbol(),Period()),0,0,false))
           {
            Print("Error opening SellStop  ",ErrorDescription(GetLastError()),"  Ask=",Ask,"   Bid=",Bid," , EntryPrice={",entryPrice,"}, SL={",stopLoss,"}  TP={",takeProfit,"}");
           }
        }
     }

   return newTradeSignal;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool NewsTime()
  {
   module="NewsTime"; Print(module);
//   string indicatorName=GetFFNewsIndicator();;
//   int eventMinute = (int)iCustom(NULL,0,indicatorName,0,0);
//   int eventImpact = (int)iCustom(NULL,0,indicatorName,1,0);
//
////Print("IsNewsTime = eventMinute {"+eventMinute+"}; eventImpact {"+eventImpact+"}");
//
//   if((eventMinute==SecondsBeforeNews) && (eventImpact==HIGH_IMPACT_NEWS))
//     {
//      return true;
//     }

   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string GetFFNewsIndicator()
  {
   if(IsTesting()) return NEWS_CAL_IND_TST;
   return NEWS_CAL_IND;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SessionOpen()
  {
   module="SessionOpen";
/*
// Beginning of the session, determination of the flat boundaries by n preceding bars
   if (Hour()==h_beg)
   {
      max=MathMax(High[1], High[2]);
      min=MathMin(Low[1],Low[2]);
      Buy_count=0;
      Sell_count=0;
   }

// End of session, closing of all positions opened during session by "OrderComment_SessionTrade"
   if ((Hour()>=h_end)&&(Hour()<h_beg))
   {
      Buy_count=1;
      Sell_count=1;
      max=0;
      min=0;
      if (TotalDeals!=0)
         CloseOrder();
   } 

// Checking for position opening       
      if ((Bid>max)&&(max!=0)&&(pos==0)&&(Sell_count==0))      
            pos=-1;                  

      if ((Ask<min)&&(min!=0)&&(pos==0)&&(Buy_count==0))             
            pos=1;   
  */

   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
#define FFZigZagPos     2
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasTradeSignal(double &entryPrice,int &inferredSignal,bool usePendingOrders=false)
  {

/*
// Checking for position opening
   module="HasTradeSignal";
   string arrowName=StringConcatenate("Arrow_",mCurrentBar);
   int zzFractalSignal=EMPTY_VALUE,
   zzSignal=EMPTY_VALUE,
   afiStochSignal=EMPTY_VALUE,
   stochSignal=EMPTY_VALUE;

   if(HasEntrySignal(zzFractalSignal))
     {
      bool afiStochVerified=VerifiedAFIStochastic(afiStochSignal),
      stochasticVerified=VerifiedStochastic(stochSignal),
      zigZagVerified=VerifiedZigZag(zzSignal,FFZigZagPos);

      if(TimeToStr(Time[0])=="2017.07.27 21:00" || TimeToStr(Time[0])=="2017.07.28 23:00") PrintFormat(module,"... Entry @: '%d', zzFractalSignal{%d=>%s}, stochSignal{%d=>%s}, afiStochSignal{%d=>%s}. InferredEntry={%d}",zzFractalSignal,EntryPriceFromOrder(zzFractalSignal),
                  stochSignal,SignalTextFromId(stochSignal),afiStochSignal,SignalTextFromId(afiStochSignal),EntryPriceFromOrder(zzSignal));

      if(IsValidOrder(stochSignal))
        {
         if(zzSignal==zzFractalSignal && zzSignal==stochSignal && zzSignal==afiStochSignal)
           {

            if(usePendingOrders)
              {
               entryPrice=(zzSignal==OP_SELL ? NormalizeDouble(Bid-((DistanceFromPrice/2)*Point),Digits): NormalizeDouble(Ask+((DistanceFromPrice/2)*Point),Digits));
              }

            if(TimeToStr(Time[0])=="2017.07.27 21:00" || TimeToStr(Time[0])=="2017.07.28 23:00") Print("EntryPrice = ",entryPrice);

            return true;
           }
        }
     } */
     
     for(int i=0;i<5;i++)
       {
            PrintFormat("Open: '%d' => '%d', High: '%d' => '%d', Low: '%d' => '%d', Close: '%d' => '%d'",Open[i],iOpen(NULL,0,i),High[i],iHigh(NULL,0,i),Low[i],iLow(NULL,0,i),Close[i],iClose(NULL,0,i));  
       }
  
   return EMPTY_VALUE;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string SignalTextFromId(int inputId)
  {
   if(inputId==OP_BUY || inputId==OP_SELL) return (inputId==OP_BUY?"Buy":"Sell");
   return "No Signal";
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double EntryPriceFromOrder(int inputId)
  {
   RefreshRates();
   if(inputId==OP_BUY) return Ask;
   if(inputId==OP_SELL) return Bid;
   return EMPTY_VALUE;
  }
//+------------------------------------------------------------------+
//|  Use for continuation & exits                                    |
//+------------------------------------------------------------------+
bool HasEntrySignal(int &inferredSignal,int shift=0)
  {
   module="HasEntrySignal";
   
   double fractalValue=EMPTY_VALUE;
   
   for(int i=0;i<5;i++)
     {
         fractalValue=iCustom(NULL, 0, "FractalZigZagNoRepaint",true,12,5,0,shift+1);
         
         if (IsSpecialCase()) PrintFormat("%s: %s.. %d. FractalValue = '%d', High = '%d', Low = '%d'",module,TimeToStr(Time[i]),i,fractalValue,High[0],Low[0]);      
     }

   if(HasValue(fractalValue))
     {
      if(fractalValue>=Low[shift]) inferredSignal=OP_BUY;
      if(fractalValue<=High[shift]) inferredSignal=OP_SELL;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool VerifiedZigZag(int &inferredSignal,int shift=1)
  {
   module="VerifiedZigZag";
   double zz=iCustom(NULL,0,"ZigZagNonRepaint",ExtDepth,ExtDeviation,ExtBackstep,0,shift);

   //Print("Shift = {",shift,"}... ",zz,", Highs: ",High[shift],"-2",High[shift+2]," Lows: ",Low[shift],Low[shift+2]);

   if(HasValue(zz))
     {
      if(zz<High[shift])
        {
         inferredSignal=OP_SELL;
         return true;
        }

      if(zz>Low[shift])
        {
         inferredSignal=OP_BUY;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool VerifiedAFIStochastic(int &inferredSignal,int shift=0)
  {
   module="VerifiedAFIStochastic"; //Print(module);
   double signalValue=iCustom(NULL,0,"AFI Stochastic",length,Filter,0,shift);
   double buyValue=iCustom(NULL,0,"AFI Stochastic",length,Filter,1,shift);
   double sellValue=iCustom(NULL,0,"AFI Stochastic",length,Filter,2,shift);
   
   //Print(module,":: signalValue = {",signalValue, "}, buyValue {",buyValue,"}, sellValue {",sellValue,"}");
   
//TODO: Wait for change of colour

   if(!HasValue(signalValue) && !HasValue(buyValue) && !HasValue(sellValue) ) return false;
   
   if(signalValue<OverSoldLine)
     {
     
//Print(module,"... BUY = ",signalValue, " vs OverSoldLine {",OverSoldLine,"}, OverBoughtLine {",OverBoughtLine,"}");
     
      inferredSignal=OP_BUY;
      return true;
     }

   if(signalValue>OverBoughtLine)
     {
     
//Print(module,"... SELL = ",signalValue, " vs OverSoldLine {",OverSoldLine,"}, OverBoughtLine {",OverBoughtLine,"}");     
     
      inferredSignal=OP_SELL;
      return true;
     }

   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int VerifiedStochastic(int &inferredSignal,int shift=0)
  {
   module="VerifiedStochastic";
   int numberBasForCompare=3;
   bool crossedUp,crossedDown;
   double mainLine[3],signalLine[3];

   ArrayInitialize(mainLine,0.0); ArrayInitialize(signalLine,0.0);

   for(int i=shift;i<3;i++)
     {
      mainLine[i]=iStochastic(NULL,0,8,3,3,MODE_SMA,0,MODE_MAIN,i);
      signalLine[i]=iStochastic(NULL,0,8,3,3,MODE_SMA,0,MODE_SIGNAL,i);
     }
   if((mainLine[1]<signalLine[1]) && (mainLine[2]>signalLine[2])) crossedDown=true;
   else if((mainLine[1]>signalLine[1]) && (mainLine[2]<signalLine[2])) crossedUp=true;
   else return EMPTY_VALUE;

   if(crossedUp && (mainLine[1]<OverSoldLine))
     {
      inferredSignal=OP_BUY;
      return true;
     }
   if(crossedDown && (mainLine[1]>OverBoughtLine))
     {
      inferredSignal=OP_SELL;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double mSupport,mResistance,mMargin;
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PrepareChannelSurfer()
  {
   mSupport=EMPTY_VALUE;mResistance=EMPTY_VALUE;
   UpdateChannelSurfer(mCurrentBar);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void  UpdateChannelSurfer(int shift=1)
  {
   module="UpdateChannelSurfer"; //Print(module);
   double channelSurfer=iCustom(NULL,0,"Channel Surfer",AllBars,BarsForFract,0,shift);

   string resistanceObjName="TL1",middleObjName="MIDL",supportMiddleName="TL2";

   double resistance=ObjectGetValueByShift(resistanceObjName,0);
   double margin=ObjectGetValueByShift(middleObjName,0);
   double support=ObjectGetValueByShift(supportMiddleName,0);

   mResistance=MathMax(resistance,support);
   mSupport=MathMin(resistance,support);
   mMargin=margin;

  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetCurrentTrend()
  {
//--Channel size = <XXX> Slope = <YYY>
   module="GetCurrentTrend"; //Print(mCurrentBar+"."+module);

   string channelSlope;
   string inferredComment=ChartGetString(0,CHART_COMMENT,channelSlope);

//Print("InferredComment={",inferredComment,"} channelSlope = {",channelSlope,"}");

   string comments[];
   ushort sepCode; sepCode=StringGetCharacter("=",0);

   int index=StringFind(inferredComment,"slope",0);
//Print("index={"+index+"}");

   if(index>0)
     {

      Print("We have a trend");

      int len=StringLen(inferredComment)-index;
      string inferredSlope=StringSubstr(inferredComment,index,15);

      Print("len=",len,", inferredSlope=",inferredSlope);

      if(inferredSlope!="")
        {
         int slope=StringToInteger(inferredSlope);
         if(slope>0) { return OP_SELL; } else { return OP_BUY; };
        }
     }

   return EMPTY_VALUE;
  }
//*******************************************************************
// END: Signalling
//*******************************************************************

//*******************************************************************
// Helpers
//*******************************************************************
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string GetOrderComment(tradingStrategy strategy)
  {
   return StringConcatenate(comment,"_",EnumToString(strategy));
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsOrderPlacedByEA(string orderComment)
  {
//TODO: perhaps use magicNumber
   module="IsOrderPlacedByEA";   //Print(module);
   string separator="_";
   ushort sepCode; sepCode=StringGetCharacter(separator,0);
   string result[];
   string magicNumberAsString="";

   int count=StringSplit(magicNumberAsString,sepCode,result);
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
   if(count>0)
     {
      return(result[0]==comment);
     }
   return false;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
color GetOrderColor(int inputOrderType)
  {
   if(inputOrderType==OP_SELL)
     {
      return Red;
     }
   return Lime;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double minLotSize,maxLotSize;
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetTradeParameters(string symbol="")
  {
   if(symbol=="") symbol=Symbol();

   minLotSize=MarketInfo(symbol, MODE_MINLOT);
   maxLotSize=MarketInfo(symbol, MODE_MAXLOT);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawArrow(string arrowName,double linePrice,color lineColor,int arrowType)
  {
//if you draw more often on the same bar i would recommend to check first if the arrow already is 
//existing on the chart and delete existing or set new values only...
   int arrow=ARROW_UP;
   if(arrowType==OP_SELL) arrow=ARROW_DOWN;

   ObjectCreate(arrowName,OBJ_ARROW,0,GetCurrentTime(),(arrowType==OP_BUY?Ask:Bid));
   ObjectSet(arrowName,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSet(arrowName,OBJPROP_ARROWCODE,arrow);
   ObjectSet(arrowName,OBJPROP_COLOR,lineColor);
   ObjectSet(arrowName,OBJPROP_FONTSIZE,70);

  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime GetCurrentTime()
  {
   return mTime;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetTickData()
  {
   mTime=Time[barOffset];

   currentTickData.open=Open[0];
   currentTickData.high=High[0];
   currentTickData.low=Low[0];
   currentTickData.close=Close[0];
   currentTickData.trend=GetCurrentTrend();


  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasValue(double inputNumber)
  {
   if(inputNumber==EMPTY_VALUE) return false;
   if(inputNumber==0.0) return false;

   return true;
  }

bool IsSpecialCase()
{
   /*
   if(TimeToStr(Time[0])=="2017.07.27 21:00"  || TimeToStr(Time[0])=="2017.07.28 23:00")
         return true;
         
   return false;
   */
   
   return true;
}
//*******************************************************************
// END:// Helpets
//*******************************************************************

//+------------------------------------------------------------------+
