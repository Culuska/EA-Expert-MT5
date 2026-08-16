//+------------------------------------------------------------------+
//|                                                      BREG_EA.mq5 |
//|                         Break -> Retest -> Engulfing Expert      |
//|                                                                    |
//| A professional, multi-timeframe price-action Expert Advisor that  |
//| trades the BREG sequence (BREAK -> RETEST -> ENGULFING -> ENTRY)  |
//| independently on any combination of M1, M5, M15, M30, H1, H4.     |
//|                                                                    |
//| Non-repainting: all structural decisions (swings, breaks, retests,|
//| engulfing patterns) are evaluated only on fully closed bars.       |
//| Optional intrabar-aggressive entry mode is the sole exception and |
//| is opt-in.                                                         |
//+------------------------------------------------------------------+
#property copyright "BREG EA"
#property version   "1.21"
#property description "Break-Retest-Engulfing multi-timeframe price action EA"

#include <Trade\Trade.mqh>

//======================================================================
// ENUMERATIONS
//======================================================================
enum ENUM_ENTRY_MODE
{
   ENTRY_CLOSED_CANDLE,       // Wait for engulfing candle close, enter at next open
   ENTRY_INTRABAR_AGGRESSIVE  // Enter as soon as engulfing forms intrabar (unconfirmed)
};

enum ENUM_SL_METHOD
{
   SL_STRUCTURE,        // Broken structure level (swing/break level)
   SL_ENGULFING_WICK,   // Wick of the engulfing candle
   SL_RETEST_SWING,     // Extreme reached during the retest
   SL_ATR               // ATR multiple from entry
};

enum ENUM_HTF_FILTER_MODE
{
   HTF_MODE_STRICT,      // Reject setups that conflict with HTF bias
   HTF_MODE_PREFERENCE   // Reduce score only, never hard-reject
};

enum ENUM_TP_METHOD
{
   TP_NEXT_STRUCTURE,   // Nearest opposing swing/liquidity level beyond entry (falls back to fixed R:R)
   TP_FIXED_RR          // Always entry + SL-distance * RiskReward
};

enum ENUM_PRIMARY_TF
{
   PRIMARY_AUTO,  // Scan every timeframe enabled below
   PRIMARY_M1,
   PRIMARY_M5,
   PRIMARY_M15,
   PRIMARY_M30,
   PRIMARY_H1,
   PRIMARY_H4
};

enum ENUM_BREG_STATE
{
   STATE_IDLE,
   STATE_BREAK_DETECTED,
   STATE_WAITING_FOR_RETEST,
   STATE_RETEST_DETECTED,
   STATE_WAITING_FOR_ENGULFING,
   STATE_ENTRY_READY,
   STATE_TRADE_EXECUTED,
   STATE_SETUP_INVALIDATED
};

enum ENUM_SETUP_DIR
{
   DIR_NONE    = 0,
   DIR_BULLISH = 1,
   DIR_BEARISH = -1
};

//======================================================================
// INPUTS
//======================================================================
input group "Timeframe Configuration"
input bool  Enable_M1                = true;
input bool  Enable_M5                = true;
input bool  Enable_M15               = true;
input bool  Enable_M30               = true;
input bool  Enable_H1                = true;
input bool  Enable_H4                = true;
input ENUM_PRIMARY_TF Primary_Timeframe = PRIMARY_AUTO;   // AUTO = scan all Enable_* timeframes
input bool  Use_HTF_Filter           = false;             // Optional directional filter only
input ENUM_TIMEFRAMES HTF_Timeframe  = PERIOD_H1;
input ENUM_HTF_FILTER_MODE HTF_Filter_Mode = HTF_MODE_PREFERENCE;
input int   HTF_MA_Period            = 50;
input ENUM_MA_METHOD HTF_MA_Method   = MODE_EMA;

input group "Swing & Structure Detection"
input int    Swing_Left_Bars         = 3;
input int    Swing_Right_Bars        = 3;
input double Minimum_Swing_Distance  = 100;    // points of prominence required (XAUUSD @ 2-digit: ~$1.00)
input double Minimum_Break_Distance  = 20;     // points close must clear the level by (~$0.20)
input int    Swing_Lookback_Bars     = 100;    // how far back to search for a valid swing

input group "Retest Parameters"
input int    Retest_Max_Bars                  = 5;    // "a few bars" - keep tight, not a lingering setup
input double Retest_Tolerance_Points           = 80;   // ~$0.80 on XAUUSD @ 2-digit
input double Retest_Min_Depth                  = 0;
input double Retest_Max_Depth                  = 400;  // ~$4.00 on XAUUSD @ 2-digit
input double Retest_Invalidation_Buffer_Points = 150;  // ~$1.50 on XAUUSD @ 2-digit

input group "Engulfing Confirmation"
input bool   Use_Strict_Engulfing            = true;   // full-body engulf AND a decisive/strong candle - not just "technically bigger"
input double Engulfing_Min_Body_Ratio        = 1.0;    // engulfing body vs previous candle's body
input double Engulfing_Min_Avg_Body_Ratio    = 1.2;    // engulfing body vs recent average body - filters out "weak" engulfing
input int    Engulfing_Max_Bars_After_Retest = 3;

input group "Entry Settings"
input ENUM_ENTRY_MODE Entry_Mode     = ENTRY_CLOSED_CANDLE;
input int    InpSlippagePoints       = 50;     // ~$0.50 on XAUUSD @ 2-digit

input group "Setup Scoring"
input double Minimum_Setup_Score     = 60;     // 0-110; ~60/80 with liquidity/HTF/displacement bonuses left off by default

input group "Liquidity Filter (Optional)"
input bool   Use_Liquidity_Filter              = false;
input int    Liquidity_Lookback_Bars           = 20;
input double Liquidity_Equal_Tolerance_Points  = 50;   // ~$0.50 on XAUUSD @ 2-digit

input group "Displacement Filter (Optional)"
input bool   Use_Displacement_Filter    = false;
input double Minimum_Displacement_Ratio = 1.5;
input int    Displacement_Lookback_Bars = 10;

input group "Stop Loss & Take Profit"
input ENUM_SL_METHOD SL_Method       = SL_ENGULFING_WICK;  // beyond the engulfing candle's wick
input double SL_Buffer_Points        = 100;    // ~$1.00 on XAUUSD @ 2-digit
input int    ATR_Period              = 14;
input double ATR_Multiplier          = 1.5;
input ENUM_TP_METHOD TP_Method       = TP_NEXT_STRUCTURE;  // target the next swing/liquidity level, not a fixed multiple
input double TP_Min_Structure_RR     = 1.0;    // a structure target must clear at least this R:R, else fall back to fixed R:R
input int    TP_Structure_Lookback_Bars = 150; // how far back to search for the next opposing swing/liquidity level
input double RiskReward              = 3.0;    // used as the fallback target, and always when TP_Method = TP_FIXED_RR

input group "Risk Management"
input double Risk_Per_Trade          = 1.0;    // % of equity
input bool   Use_Dynamic_Lot         = true;
input double Fixed_Lot               = 0.01;
input int    Max_Trades_Per_Day      = 3;
input int    Max_Open_Trades         = 1;
input int    Max_Consecutive_Losses  = 3;
input ulong  InpMagicNumber          = 20260816;

input group "Multi-Timeframe Trade Control"
input bool   One_Trade_Total         = true;
input bool   One_Trade_Per_Timeframe = false;

input group "Session Filter (Optional)"
input bool   Use_Session_Filter      = false;
input bool   Trade_London            = true;
input bool   Trade_NewYork           = true;
input bool   Trade_Asian             = false;
input int    Session_London_Start    = 7;
input int    Session_London_End      = 16;
input int    Session_NewYork_Start   = 12;
input int    Session_NewYork_End     = 21;
input int    Session_Asian_Start     = 0;
input int    Session_Asian_End       = 9;

input group "Spread Filter"
input bool   Use_Spread_Filter       = true;
input int    Max_Spread_Points       = 300;    // ~$3.00 on XAUUSD @ 2-digit - check your broker's typical live spread and tune

input group "News Filter (Optional / Manual)"
input bool   Use_News_Filter          = false;
input int    News_Block_Before_Minutes = 15;
input int    News_Block_After_Minutes  = 15;
input string News_Event_Times          = "";  // comma separated "YYYY.MM.DD HH:MM"

input group "Visual Interface"
input bool   Show_Chart_Objects        = true;
input bool   Show_Dashboard            = true;
input int    Dashboard_Refresh_Seconds = 1;      // throttle redraws on fast tick streams (M1/backtest)
input bool   Keep_Invalidated_Drawings = false;
input bool   Enable_Alerts             = false;
input bool   Enable_Push_Notifications = false;

input group "Debug"
input bool   Debug_Mode               = true;

//======================================================================
// DATA STRUCTURES
//======================================================================
struct BregSetup
{
   string           id;
   ENUM_TIMEFRAMES  tf;
   int              tfIndex;
   ENUM_BREG_STATE  state;
   ENUM_SETUP_DIR   dir;
   double           breakLevel;
   datetime         breakTime;
   datetime         retestTime;
   double           retestExtreme;
   double           retestDepthPts;
   datetime         engulfTime;
   double           engulfOpen;
   double           engulfClose;
   double           engulfHigh;
   double           engulfLow;
   double           engulfBodyRatio;
   double           score;
   bool             liquiditySwept;
   bool             displacementOk;
   bool             htfAligned;
   bool             traded;
   double           entryPrice;
   double           slPrice;
   double           tpPrice;
   datetime         createdTime;
};

//======================================================================
// GLOBALS
//======================================================================
#define MAX_TF 6
ENUM_TIMEFRAMES g_tfArr[MAX_TF]   = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4};
string          g_tfNames[MAX_TF] = {"M1","M5","M15","M30","H1","H4"};

BregSetup       g_setups[MAX_TF];
datetime        g_lastBarTime[MAX_TF];
int             g_atrHandle[MAX_TF];
int             g_activeTfList[MAX_TF];
int             g_tfCount = 0;

int             g_maHandleHTF = INVALID_HANDLE;
CTrade          trade;

int             g_consecutiveLosses = 0;
int             g_dailyTradeCount   = 0;
int             g_currentDay        = -1;

datetime        g_newsTimes[];
uint            g_lastDashboardUpdateMs = 0;

//======================================================================
// LIFECYCLE
//======================================================================
int OnInit()
{
   if(!InitializeEA())
      return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_maHandleHTF != INVALID_HANDLE) IndicatorRelease(g_maHandleHTF);
   for(int i = 0; i < MAX_TF; i++)
      if(g_atrHandle[i] != INVALID_HANDLE) IndicatorRelease(g_atrHandle[i]);

   ObjectsDeleteAll(0, "BREG_");
}

void OnTick()
{
   UpdateDailyCounters();

   for(int k = 0; k < g_tfCount; k++)
   {
      int idx = g_activeTfList[k];
      ENUM_TIMEFRAMES tf = g_tfArr[idx];

      datetime barTime = iTime(_Symbol, tf, 0);
      if(barTime > 0 && barTime != g_lastBarTime[idx])
      {
         g_lastBarTime[idx] = barTime;
         ProcessTimeframe(idx);
      }

      if(Entry_Mode == ENTRY_INTRABAR_AGGRESSIVE && g_setups[idx].state == STATE_WAITING_FOR_ENGULFING)
         CheckIntrabarEngulfing(idx);

      if(Entry_Mode == ENTRY_CLOSED_CANDLE && g_setups[idx].state == STATE_ENTRY_READY)
      {
         BregSetup s = g_setups[idx];
         ExecuteTrade(idx, s);
         g_setups[idx] = s;
      }
   }

   ManageTrade();

   if(Show_Dashboard)
   {
      uint now = GetTickCount();
      if(now - g_lastDashboardUpdateMs >= (uint)MathMax(Dashboard_Refresh_Seconds, 0) * 1000)
      {
         g_lastDashboardUpdateMs = now;
         DrawDashboard();
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic < (long)InpMagicNumber || magic >= (long)InpMagicNumber + MAX_TF) return;

   long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY)
   {
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                     + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                     + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      if(profit < 0)
      {
         g_consecutiveLosses++;
         if(Debug_Mode) PrintFormat("[BREG] Losing trade closed. Consecutive losses = %d", g_consecutiveLosses);
      }
      else if(profit > 0)
      {
         g_consecutiveLosses = 0;
         if(Debug_Mode) Print("[BREG] Winning trade closed. Consecutive losses reset to 0");
      }
   }
}

//======================================================================
// InitializeEA
//======================================================================
bool InitializeEA()
{
   BuildActiveTFList();

   for(int i = 0; i < MAX_TF; i++)
   {
      ResetSetupStruct(g_setups[i], g_tfArr[i], i);
      g_lastBarTime[i] = 0;
      g_atrHandle[i]   = INVALID_HANDLE;
   }

   if(SL_Method == SL_ATR)
   {
      for(int k = 0; k < g_tfCount; k++)
      {
         int idx = g_activeTfList[k];
         g_atrHandle[idx] = iATR(_Symbol, g_tfArr[idx], ATR_Period);
         if(g_atrHandle[idx] == INVALID_HANDLE)
            Print("[BREG] Warning: failed to create ATR handle for ", g_tfNames[idx]);
      }
   }

   if(Use_HTF_Filter)
   {
      g_maHandleHTF = iMA(_Symbol, HTF_Timeframe, HTF_MA_Period, 0, HTF_MA_Method, PRICE_CLOSE);
      if(g_maHandleHTF == INVALID_HANDLE)
         Print("[BREG] Warning: failed to create HTF MA handle");
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   ParseNewsTimes();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay      = dt.day_of_year;
   g_dailyTradeCount = 0;
   g_consecutiveLosses = 0;

   if(g_tfCount == 0)
   {
      Print("[BREG] ERROR: no timeframes are enabled. Enable at least one Enable_* input or choose a Primary_Timeframe.");
      return false;
   }

   if(One_Trade_Total && One_Trade_Per_Timeframe && Debug_Mode)
      Print("[BREG] Note: both One_Trade_Total and One_Trade_Per_Timeframe are true; One_Trade_Total takes precedence.");

   if(Debug_Mode)
   {
      string list = "";
      for(int k = 0; k < g_tfCount; k++) list += g_tfNames[g_activeTfList[k]] + " ";
      PrintFormat("[BREG] EA initialized on %s. Active timeframes: %s", _Symbol, list);
      LogPointConversions();
   }

   return true;
}

//======================================================================
// LogPointConversions - every "points" input, converted to real price
// terms for whatever symbol/digit convention is actually attached. Point
// size is not standardized across brokers for instruments like gold
// (2-digit vs 3-digit quoting), so this makes the effective SL/TP/spread
// distances self-evident on startup instead of silently assumed.
//======================================================================
void LogPointConversions()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   PrintFormat("[BREG] %s: Digits=%d Point=%s", _Symbol, digits, DoubleToString(point, digits));
   PrintFormat("[BREG]   Minimum_Swing_Distance      = %.0f pts (~%s)", Minimum_Swing_Distance, DoubleToString(Minimum_Swing_Distance * point, digits));
   PrintFormat("[BREG]   Minimum_Break_Distance       = %.0f pts (~%s)", Minimum_Break_Distance, DoubleToString(Minimum_Break_Distance * point, digits));
   PrintFormat("[BREG]   Retest_Tolerance_Points      = %.0f pts (~%s)", Retest_Tolerance_Points, DoubleToString(Retest_Tolerance_Points * point, digits));
   PrintFormat("[BREG]   Retest_Max_Depth             = %.0f pts (~%s)", Retest_Max_Depth, DoubleToString(Retest_Max_Depth * point, digits));
   PrintFormat("[BREG]   Retest_Invalidation_Buffer   = %.0f pts (~%s)", Retest_Invalidation_Buffer_Points, DoubleToString(Retest_Invalidation_Buffer_Points * point, digits));
   PrintFormat("[BREG]   SL_Buffer_Points             = %.0f pts (~%s)", SL_Buffer_Points, DoubleToString(SL_Buffer_Points * point, digits));
   PrintFormat("[BREG]   Max_Spread_Points            = %.0f pts (~%s)", Max_Spread_Points, DoubleToString(Max_Spread_Points * point, digits));
   PrintFormat("[BREG]   InpSlippagePoints            = %.0f pts (~%s)", InpSlippagePoints, DoubleToString(InpSlippagePoints * point, digits));
   PrintFormat("[BREG]   Current live spread          = %d pts (~%s)", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
               DoubleToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point, digits));
   Print("[BREG] If any of the above look wrong for how you actually see this instrument quoted, adjust the corresponding input - do not assume these defaults are correct for every broker.");
}

void BuildActiveTFList()
{
   bool enabledFlags[MAX_TF];
   enabledFlags[0] = Enable_M1;
   enabledFlags[1] = Enable_M5;
   enabledFlags[2] = Enable_M15;
   enabledFlags[3] = Enable_M30;
   enabledFlags[4] = Enable_H1;
   enabledFlags[5] = Enable_H4;

   g_tfCount = 0;

   if(Primary_Timeframe == PRIMARY_AUTO)
   {
      for(int i = 0; i < MAX_TF; i++)
         if(enabledFlags[i])
            g_activeTfList[g_tfCount++] = i;
   }
   else
   {
      int idx = PrimaryEnumToIndex(Primary_Timeframe);
      g_activeTfList[0] = idx;
      g_tfCount = 1;
   }
}

int PrimaryEnumToIndex(ENUM_PRIMARY_TF p)
{
   switch(p)
   {
      case PRIMARY_M1:  return 0;
      case PRIMARY_M5:  return 1;
      case PRIMARY_M15: return 2;
      case PRIMARY_M30: return 3;
      case PRIMARY_H1:  return 4;
      case PRIMARY_H4:  return 5;
      default:          return 1;
   }
}

void ResetSetupStruct(BregSetup &s, ENUM_TIMEFRAMES tf, int idx)
{
   s.id = "";
   s.tf = tf;
   s.tfIndex = idx;
   s.state = STATE_IDLE;
   s.dir = DIR_NONE;
   s.breakLevel = 0; s.breakTime = 0;
   s.retestTime = 0; s.retestExtreme = 0; s.retestDepthPts = 0;
   s.engulfTime = 0; s.engulfOpen = 0; s.engulfClose = 0; s.engulfHigh = 0; s.engulfLow = 0; s.engulfBodyRatio = 0;
   s.score = 0;
   s.liquiditySwept = false; s.displacementOk = false; s.htfAligned = false;
   s.traded = false;
   s.entryPrice = 0; s.slPrice = 0; s.tpPrice = 0;
   s.createdTime = 0;
}

//======================================================================
// ProcessTimeframe - the per-bar state machine driver (closed bars only)
//======================================================================
void ProcessTimeframe(int idx)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];

   int minBars = Swing_Lookback_Bars + Swing_Left_Bars + Swing_Right_Bars + 5;
   if(minBars < 60) minBars = 60;
   if(iBars(_Symbol, tf) < minBars) return;

   BregSetup setup = g_setups[idx];

   switch(setup.state)
   {
      case STATE_IDLE:
         DetectBreak(idx, setup);
         break;

      case STATE_WAITING_FOR_RETEST:
         DetectRetest(idx, setup);
         break;

      case STATE_WAITING_FOR_ENGULFING:
         DetectEngulfing(idx, setup);
         break;

      default:
         break; // ENTRY_READY / TRADE_EXECUTED / SETUP_INVALIDATED handled elsewhere
   }

   g_setups[idx] = setup;
}

//======================================================================
// DetectSwingStructure / ValidateBreak / DetectBreak
//======================================================================
double DetectSwingStructure(string sym, ENUM_TIMEFRAMES tf, ENUM_SETUP_DIR dir, int startShift, datetime &swingTimeOut)
{
   if(dir == DIR_BULLISH)
      return FindSwingHigh(sym, tf, startShift, Swing_Lookback_Bars, Swing_Left_Bars, Swing_Right_Bars, Minimum_Swing_Distance, swingTimeOut);
   else
      return FindSwingLow(sym, tf, startShift, Swing_Lookback_Bars, Swing_Left_Bars, Swing_Right_Bars, Minimum_Swing_Distance, swingTimeOut);
}

bool IsValidSwingHigh(string sym, ENUM_TIMEFRAMES tf, int s, int leftBars, int rightBars, double minDistPoints)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(s - rightBars < 1) return false;

   double candidate = iHigh(sym, tf, s);
   if(candidate <= 0) return false;

   for(int L = 1; L <= leftBars; L++)
   {
      double h = iHigh(sym, tf, s + L);
      if(h >= candidate || (candidate - h) < minDistPoints * point) return false;
   }
   for(int R = 1; R <= rightBars; R++)
   {
      double h = iHigh(sym, tf, s - R);
      if(h >= candidate || (candidate - h) < minDistPoints * point) return false;
   }
   return true;
}

bool IsValidSwingLow(string sym, ENUM_TIMEFRAMES tf, int s, int leftBars, int rightBars, double minDistPoints)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(s - rightBars < 1) return false;

   double candidate = iLow(sym, tf, s);
   if(candidate <= 0) return false;

   for(int L = 1; L <= leftBars; L++)
   {
      double l = iLow(sym, tf, s + L);
      if(l <= candidate || (l - candidate) < minDistPoints * point) return false;
   }
   for(int R = 1; R <= rightBars; R++)
   {
      double l = iLow(sym, tf, s - R);
      if(l <= candidate || (l - candidate) < minDistPoints * point) return false;
   }
   return true;
}

double FindSwingHigh(string sym, ENUM_TIMEFRAMES tf, int startShift, int maxLookback,
                      int leftBars, int rightBars, double minDistPoints, datetime &swingTimeOut)
{
   int bars = iBars(sym, tf);
   int limit = startShift + maxLookback;
   if(limit > bars - leftBars - 2) limit = bars - leftBars - 2;

   for(int s = startShift; s < limit; s++)
   {
      if(IsValidSwingHigh(sym, tf, s, leftBars, rightBars, minDistPoints))
      {
         swingTimeOut = iTime(sym, tf, s);
         return iHigh(sym, tf, s);
      }
   }
   return 0.0;
}

double FindSwingLow(string sym, ENUM_TIMEFRAMES tf, int startShift, int maxLookback,
                     int leftBars, int rightBars, double minDistPoints, datetime &swingTimeOut)
{
   int bars = iBars(sym, tf);
   int limit = startShift + maxLookback;
   if(limit > bars - leftBars - 2) limit = bars - leftBars - 2;

   for(int s = startShift; s < limit; s++)
   {
      if(IsValidSwingLow(sym, tf, s, leftBars, rightBars, minDistPoints))
      {
         swingTimeOut = iTime(sym, tf, s);
         return iLow(sym, tf, s);
      }
   }
   return 0.0;
}

//======================================================================
// FindNextTPTarget - nearest opposing swing high/low or PDH/PDL beyond
// the entry price, used for TP_Method = TP_NEXT_STRUCTURE. Only ever
// looks at already-closed historical bars, so it stays non-repainting -
// it is picking a pre-existing level to aim at, not predicting one.
//======================================================================
double FindNextTPTarget(string sym, ENUM_TIMEFRAMES tf, ENUM_SETUP_DIR dir, double refPrice)
{
   double best = 0.0;
   int bars = iBars(sym, tf);
   int limit = TP_Structure_Lookback_Bars;
   if(limit > bars - Swing_Left_Bars - 2) limit = bars - Swing_Left_Bars - 2;

   for(int s = 1; s < limit; s++)
   {
      if(dir == DIR_BULLISH)
      {
         if(!IsValidSwingHigh(sym, tf, s, Swing_Left_Bars, Swing_Right_Bars, Minimum_Swing_Distance)) continue;
         double lvl = iHigh(sym, tf, s);
         if(lvl > refPrice && (best == 0.0 || lvl < best)) best = lvl;
      }
      else
      {
         if(!IsValidSwingLow(sym, tf, s, Swing_Left_Bars, Swing_Right_Bars, Minimum_Swing_Distance)) continue;
         double lvl = iLow(sym, tf, s);
         if(lvl < refPrice && (best == 0.0 || lvl > best)) best = lvl;
      }
   }

   if(iBars(sym, PERIOD_D1) >= 2)
   {
      if(dir == DIR_BULLISH)
      {
         double pdh = iHigh(sym, PERIOD_D1, 1);
         if(pdh > refPrice && (best == 0.0 || pdh < best)) best = pdh;
      }
      else
      {
         double pdl = iLow(sym, PERIOD_D1, 1);
         if(pdl < refPrice && (best == 0.0 || pdl > best)) best = pdl;
      }
   }

   return best;
}

bool ValidateBreak(string sym, ENUM_TIMEFRAMES tf, ENUM_SETUP_DIR dir, double level, double &dispRatioOut)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double closeBar = iClose(sym, tf, 1);

   bool directionOk = (dir == DIR_BULLISH) ? (closeBar > level) : (closeBar < level);
   if(!directionOk) return false;

   double breakDist = (dir == DIR_BULLISH) ? (closeBar - level) / point : (level - closeBar) / point;
   if(breakDist < Minimum_Break_Distance) return false;

   dispRatioOut = GetDisplacementRatio(sym, tf, 1);
   if(Use_Displacement_Filter && dispRatioOut < Minimum_Displacement_Ratio) return false;

   return true;
}

void DetectBreak(int idx, BregSetup &setup)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;
   datetime swingTime = 0;

   double swingHigh = DetectSwingStructure(sym, tf, DIR_BULLISH, 2, swingTime);
   if(swingHigh > 0)
   {
      double dispRatio = 0;
      if(ValidateBreak(sym, tf, DIR_BULLISH, swingHigh, dispRatio))
      {
         CreateSetupFromBreak(idx, setup, DIR_BULLISH, swingHigh, dispRatio);
         return;
      }
   }

   double swingLow = DetectSwingStructure(sym, tf, DIR_BEARISH, 2, swingTime);
   if(swingLow > 0)
   {
      double dispRatio = 0;
      if(ValidateBreak(sym, tf, DIR_BEARISH, swingLow, dispRatio))
      {
         CreateSetupFromBreak(idx, setup, DIR_BEARISH, swingLow, dispRatio);
         return;
      }
   }
}

void CreateSetupFromBreak(int idx, BregSetup &setup, ENUM_SETUP_DIR dir, double level, double dispRatio)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;

   if(Debug_Mode)
   {
      PrintFormat("[BREG][%s] %s detected", g_tfNames[idx], dir == DIR_BULLISH ? "Swing High" : "Swing Low");
      PrintFormat("[BREG][%s] State: IDLE -> BREAK_DETECTED", g_tfNames[idx]);
   }

   ResetSetupStruct(setup, tf, idx);
   setup.state = STATE_BREAK_DETECTED;
   setup.dir = dir;
   setup.breakLevel = level;
   setup.breakTime = iTime(sym, tf, 1);
   setup.createdTime = TimeCurrent();
   setup.displacementOk = (dispRatio >= Minimum_Displacement_Ratio);
   setup.liquiditySwept = Use_Liquidity_Filter ? CheckLiquidity(sym, tf, 1, dir, level) : false;
   setup.id = StringFormat("%s_%s_%s_%d", sym, g_tfNames[idx], dir == DIR_BULLISH ? "BULL" : "BEAR", (int)setup.breakTime);

   if(Debug_Mode)
      PrintFormat("[BREG][%s] %s BOS detected @ %.5f (close=%.5f)", g_tfNames[idx],
                  dir == DIR_BULLISH ? "Bullish" : "Bearish", level, iClose(sym, tf, 1));

   DrawSetup(setup, "BOS");
   SendAlert(StringFormat("[BREG] %s %s %s Break of Structure @ %.5f", sym, g_tfNames[idx],
                           dir == DIR_BULLISH ? "Bullish" : "Bearish", level));

   if(Debug_Mode) PrintFormat("[BREG][%s] State: BREAK_DETECTED -> WAITING_FOR_RETEST", g_tfNames[idx]);
   setup.state = STATE_WAITING_FOR_RETEST;
}

//======================================================================
// DetectRetest / ValidateRetest
//======================================================================
bool ValidateRetest(ENUM_SETUP_DIR dir, double breakLevel, double barHigh, double barLow, double &depthPtsOut)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(dir == DIR_BULLISH)
   {
      double dist = (breakLevel - barLow) / point;
      depthPtsOut = dist;
      bool touched = (barLow <= breakLevel + Retest_Tolerance_Points * point);
      return touched && dist <= Retest_Max_Depth && dist >= Retest_Min_Depth;
   }
   else
   {
      double dist = (barHigh - breakLevel) / point;
      depthPtsOut = dist;
      bool touched = (barHigh >= breakLevel - Retest_Tolerance_Points * point);
      return touched && dist <= Retest_Max_Depth && dist >= Retest_Min_Depth;
   }
}

void DetectRetest(int idx, BregSetup &setup)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   int barsSinceBreak = BarsBetween(sym, tf, setup.breakTime);
   if(barsSinceBreak > Retest_Max_Bars)
   {
      InvalidateSetup(idx, setup, "Retest window exceeded");
      return;
   }

   double low1  = iLow(sym, tf, 1);
   double high1 = iHigh(sym, tf, 1);
   double close1 = iClose(sym, tf, 1);

   double invLevel = (setup.dir == DIR_BULLISH)
      ? setup.breakLevel - (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point
      : setup.breakLevel + (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point;

   bool invalidated = (setup.dir == DIR_BULLISH) ? (close1 < invLevel) : (close1 > invLevel);
   if(invalidated)
   {
      InvalidateSetup(idx, setup, setup.dir == DIR_BULLISH ?
                       "Strong close back below broken structure" : "Strong close back above broken structure");
      return;
   }

   double depth = 0;
   if(ValidateRetest(setup.dir, setup.breakLevel, high1, low1, depth))
   {
      if(Debug_Mode) PrintFormat("[BREG][%s] State: WAITING_FOR_RETEST -> RETEST_DETECTED", g_tfNames[idx]);
      setup.state = STATE_RETEST_DETECTED;
      setup.retestTime = iTime(sym, tf, 1);
      setup.retestExtreme = (setup.dir == DIR_BULLISH) ? low1 : high1;
      setup.retestDepthPts = depth;

      if(Debug_Mode) PrintFormat("[BREG][%s] Retest detected @ %.5f (depth=%.1f pts)", g_tfNames[idx], setup.retestExtreme, depth);
      DrawSetup(setup, "RETEST");

      if(Debug_Mode) PrintFormat("[BREG][%s] State: RETEST_DETECTED -> WAITING_FOR_ENGULFING", g_tfNames[idx]);
      setup.state = STATE_WAITING_FOR_ENGULFING;
   }
}

//======================================================================
// DetectEngulfing / EvaluateEngulfing / CheckIntrabarEngulfing
//======================================================================
bool EvaluateEngulfing(string sym, ENUM_TIMEFRAMES tf, int shift, ENUM_SETUP_DIR dir, BregSetup &setup)
{
   double open1  = iOpen(sym, tf, shift),  close1 = iClose(sym, tf, shift);
   double high1  = iHigh(sym, tf, shift),  low1   = iLow(sym, tf, shift);
   double open2  = iOpen(sym, tf, shift + 1), close2 = iClose(sym, tf, shift + 1);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double body1 = MathAbs(close1 - open1);
   double body2 = MathAbs(close2 - open2);
   if(body2 < point) body2 = point;

   bool patternOk;
   if(dir == DIR_BULLISH)
      patternOk = (close2 < open2) && (close1 > open1) && (open1 <= close2) && (close1 >= open2);
   else
      patternOk = (close2 > open2) && (close1 < open1) && (open1 >= close2) && (close1 <= open2);

   if(!patternOk) return false;

   double ratio = body1 / body2;
   if(Use_Strict_Engulfing && ratio < Engulfing_Min_Body_Ratio) return false;

   // "Strong, decisive candle" check: technically engulfing a tiny previous
   // candle is not enough - the engulfing candle must also stand out against
   // recent average candle size, or it is a weak engulf and does not qualify.
   double avgBodyRatio = GetDisplacementRatio(sym, tf, shift);
   if(Use_Strict_Engulfing && avgBodyRatio < Engulfing_Min_Avg_Body_Ratio) return false;

   setup.engulfOpen = open1; setup.engulfClose = close1;
   setup.engulfHigh = high1; setup.engulfLow = low1;
   setup.engulfBodyRatio = ratio;
   return true;
}

void DetectEngulfing(int idx, BregSetup &setup)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   double close1 = iClose(sym, tf, 1);
   double invLevel = (setup.dir == DIR_BULLISH)
      ? setup.breakLevel - (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point
      : setup.breakLevel + (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point;
   bool invalidated = (setup.dir == DIR_BULLISH) ? (close1 < invLevel) : (close1 > invLevel);
   if(invalidated)
   {
      InvalidateSetup(idx, setup, "Strong close back through structure before engulfing");
      return;
   }

   int barsSinceRetest = BarsBetween(sym, tf, setup.retestTime);
   if(barsSinceRetest > Engulfing_Max_Bars_After_Retest)
   {
      InvalidateSetup(idx, setup, "Engulfing window exceeded");
      return;
   }

   if(!EvaluateEngulfing(sym, tf, 1, setup.dir, setup)) return;

   if(Debug_Mode) PrintFormat("[BREG][%s] %s engulfing detected", g_tfNames[idx], setup.dir == DIR_BULLISH ? "Bullish" : "Bearish");
   DrawSetup(setup, "ENGULFING");

   bool aligned = false;
   bool htfPass = CheckHTFContext(setup.dir, aligned);
   setup.htfAligned = aligned;
   if(!htfPass)
   {
      InvalidateSetup(idx, setup, "HTF filter (STRICT) rejected setup");
      return;
   }

   double score = CalculateSetupScore(idx, setup);
   setup.score = score;
   if(Debug_Mode) PrintFormat("[BREG][%s] Setup score = %.0f", g_tfNames[idx], score);

   if(score < Minimum_Setup_Score)
   {
      InvalidateSetup(idx, setup, StringFormat("Score %.0f below minimum %.0f", score, Minimum_Setup_Score));
      return;
   }

   setup.engulfTime = iTime(sym, tf, 1);
   if(Debug_Mode) PrintFormat("[BREG][%s] State: WAITING_FOR_ENGULFING -> ENTRY_READY", g_tfNames[idx]);
   setup.state = STATE_ENTRY_READY;
   DrawSetup(setup, "ENTRY_READY");
}

void CheckIntrabarEngulfing(int idx)
{
   BregSetup s = g_setups[idx];
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   // Structural invalidation still uses the last CLOSED bar only (non-repaint safe)
   double close1 = iClose(sym, tf, 1);
   double invLevel = (s.dir == DIR_BULLISH)
      ? s.breakLevel - (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point
      : s.breakLevel + (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point;
   if((s.dir == DIR_BULLISH && close1 < invLevel) || (s.dir == DIR_BEARISH && close1 > invLevel)) return; // let next bar close invalidate formally

   if(!EvaluateEngulfing(sym, tf, 0, s.dir, s)) return; // shift0 = forming bar vs shift1 = last closed

   bool aligned = false;
   bool htfPass = CheckHTFContext(s.dir, aligned);
   s.htfAligned = aligned;
   if(!htfPass) return;

   double score = CalculateSetupScore(idx, s);
   s.score = score;
   if(score < Minimum_Setup_Score) return;

   if(Debug_Mode) PrintFormat("[BREG][%s] Intrabar aggressive %s engulfing detected (unconfirmed candle)", g_tfNames[idx], s.dir == DIR_BULLISH ? "bullish" : "bearish");

   s.engulfTime = iTime(sym, tf, 0);
   s.state = STATE_ENTRY_READY;
   DrawSetup(s, "ENGULFING");
   ExecuteTrade(idx, s);
   g_setups[idx] = s;
}

//======================================================================
// CalculateSetupScore
//======================================================================
double CalculateSetupScore(int idx, const BregSetup &setup)
{
   double score = 0;

   score += 30; // BREG Break (only reached once a valid break exists)

   double depthRatio = (Retest_Max_Depth > 0) ? (setup.retestDepthPts / Retest_Max_Depth) : 0;
   if(depthRatio < 0) depthRatio = 0;
   if(depthRatio <= 0.5)      score += 25; // Clean retest
   else if(depthRatio <= 1.0) score += 15;
   else                       score += 5;

   if(setup.engulfBodyRatio >= Engulfing_Min_Body_Ratio * 1.5)      score += 25; // Valid engulfing
   else if(setup.engulfBodyRatio >= Engulfing_Min_Body_Ratio)       score += 20;
   else                                                              score += 12;

   if(setup.htfAligned)                              score += 10; // HTF Alignment
   if(Use_Liquidity_Filter && setup.liquiditySwept)  score += 10; // Liquidity Sweep
   if(Use_Displacement_Filter && setup.displacementOk) score += 10; // Strong Displacement

   return score;
}

//======================================================================
// CheckHTFContext
//======================================================================
ENUM_SETUP_DIR GetHTFBiasDirection()
{
   if(!Use_HTF_Filter || g_maHandleHTF == INVALID_HANDLE) return DIR_NONE;

   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   if(CopyBuffer(g_maHandleHTF, 0, 1, 3, maBuf) < 3) return DIR_NONE;

   double closeHTF1 = iClose(_Symbol, HTF_Timeframe, 1);
   if(closeHTF1 > maBuf[0] && maBuf[0] > maBuf[1]) return DIR_BULLISH;
   if(closeHTF1 < maBuf[0] && maBuf[0] < maBuf[1]) return DIR_BEARISH;
   return DIR_NONE;
}

bool CheckHTFContext(ENUM_SETUP_DIR setupDir, bool &aligned)
{
   aligned = false;
   if(!Use_HTF_Filter) return true; // optional filter disabled: never restrict, never bonus

   ENUM_SETUP_DIR bias = GetHTFBiasDirection();
   if(bias == setupDir) aligned = true;

   if(bias != DIR_NONE && bias != setupDir && HTF_Filter_Mode == HTF_MODE_STRICT)
      return false; // hard reject only in STRICT mode

   return true; // PREFERENCE mode never hard-rejects, only withholds the score bonus
}

//======================================================================
// CheckLiquidity (optional, bonus-only)
//======================================================================
bool CheckLiquidity(string sym, ENUM_TIMEFRAMES tf, int breakShift, ENUM_SETUP_DIR dir, double level)
{
   if(iBars(sym, PERIOD_D1) < 2) return false;

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tol = Liquidity_Equal_Tolerance_Points * point;

   double pdh = iHigh(sym, PERIOD_D1, 1);
   double pdl = iLow(sym, PERIOD_D1, 1);

   if(dir == DIR_BULLISH)
   {
      if(MathAbs(level - pdh) <= tol) return true;
      if(DetectWickSweep(sym, tf, breakShift, true, pdh, tol)) return true;
      if(DetectEqualHighsSwept(sym, tf, breakShift, tol)) return true;
   }
   else
   {
      if(MathAbs(level - pdl) <= tol) return true;
      if(DetectWickSweep(sym, tf, breakShift, false, pdl, tol)) return true;
      if(DetectEqualLowsSwept(sym, tf, breakShift, tol)) return true;
   }
   return false;
}

bool DetectWickSweep(string sym, ENUM_TIMEFRAMES tf, int startShift, bool aboveLevel, double level, double tol)
{
   if(level <= 0) return false;
   for(int i = startShift; i < startShift + Liquidity_Lookback_Bars; i++)
   {
      if(aboveLevel)
      {
         if(iHigh(sym, tf, i) > level && iClose(sym, tf, i) < level) return true;
      }
      else
      {
         if(iLow(sym, tf, i) < level && iClose(sym, tf, i) > level) return true;
      }
   }
   return false;
}

bool DetectEqualHighsSwept(string sym, ENUM_TIMEFRAMES tf, int startShift, double tol)
{
   for(int i = startShift; i < startShift + Liquidity_Lookback_Bars - 1; i++)
   {
      double h1 = iHigh(sym, tf, i), h2 = iHigh(sym, tf, i + 1);
      if(h1 > 0 && h2 > 0 && MathAbs(h1 - h2) <= tol) return true;
   }
   return false;
}

bool DetectEqualLowsSwept(string sym, ENUM_TIMEFRAMES tf, int startShift, double tol)
{
   for(int i = startShift; i < startShift + Liquidity_Lookback_Bars - 1; i++)
   {
      double l1 = iLow(sym, tf, i), l2 = iLow(sym, tf, i + 1);
      if(l1 > 0 && l2 > 0 && MathAbs(l1 - l2) <= tol) return true;
   }
   return false;
}

//======================================================================
// Displacement helper
//======================================================================
double GetDisplacementRatio(string sym, ENUM_TIMEFRAMES tf, int shift)
{
   double body = MathAbs(iClose(sym, tf, shift) - iOpen(sym, tf, shift));
   double sum = 0; int n = 0;
   for(int i = shift + 1; i <= shift + Displacement_Lookback_Bars; i++)
   {
      sum += MathAbs(iClose(sym, tf, i) - iOpen(sym, tf, i));
      n++;
   }
   if(n == 0) return 0;
   double avg = sum / n;
   if(avg <= 0) return 0;
   return body / avg;
}

//======================================================================
// CalculateStopLoss / CalculateTakeProfit / CalculateLotSize
//======================================================================
double GetATRValue(int idx)
{
   if(g_atrHandle[idx] == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle[idx], 0, 1, 1, buf) < 1) return 0;
   return buf[0];
}

double CalculateStopLoss(int idx, const BregSetup &setup, double entryPrice)
{
   string sym = _Symbol;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double buffer = SL_Buffer_Points * point;
   double sl = 0;

   switch(SL_Method)
   {
      case SL_ENGULFING_WICK:
         sl = (setup.dir == DIR_BULLISH) ? setup.engulfLow - buffer : setup.engulfHigh + buffer;
         break;

      case SL_RETEST_SWING:
         sl = (setup.dir == DIR_BULLISH) ? setup.retestExtreme - buffer : setup.retestExtreme + buffer;
         break;

      case SL_ATR:
      {
         double atrVal = GetATRValue(idx);
         if(atrVal <= 0) atrVal = 20 * point;
         sl = (setup.dir == DIR_BULLISH) ? entryPrice - atrVal * ATR_Multiplier : entryPrice + atrVal * ATR_Multiplier;
         break;
      }

      case SL_STRUCTURE:
      default:
         if(setup.dir == DIR_BULLISH)
            sl = MathMin(setup.retestExtreme, setup.breakLevel) - buffer;
         else
            sl = MathMax(setup.retestExtreme, setup.breakLevel) + buffer;
         break;
   }

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return NormalizeDouble(sl, digits);
}

double CalculateTakeProfit(int idx, ENUM_SETUP_DIR dir, double entry, double sl)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double dist = MathAbs(entry - sl);
   double fixedRR_TP = (dir == DIR_BULLISH) ? entry + dist * RiskReward : entry - dist * RiskReward;

   if(TP_Method == TP_FIXED_RR || dist <= 0)
      return NormalizeDouble(fixedRR_TP, digits);

   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   double target = FindNextTPTarget(_Symbol, tf, dir, entry);

   if(target > 0)
   {
      double resultDist = MathAbs(target - entry);
      double rr = resultDist / dist;
      if(rr >= TP_Min_Structure_RR)
      {
         if(Debug_Mode) PrintFormat("[BREG][%s] TP set to next structure/liquidity level @ %.5f (R:R=%.2f)", g_tfNames[idx], target, rr);
         return NormalizeDouble(target, digits);
      }
      if(Debug_Mode) PrintFormat("[BREG][%s] Nearest structure target @ %.5f only offers R:R=%.2f (< %.2f) - using fixed R:R instead",
                                  g_tfNames[idx], target, rr, TP_Min_Structure_RR);
   }
   else if(Debug_Mode)
      PrintFormat("[BREG][%s] No qualifying structure/liquidity target found - using fixed R:R", g_tfNames[idx]);

   return NormalizeDouble(fixedRR_TP, digits);
}

double NormalizeVolume(double lot)
{
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0) volStep = 0.01;

   lot = MathFloor(lot / volStep) * volStep;
   if(lot < volMin) lot = volMin;
   if(lot > volMax) lot = volMax;

   int decimals = 0;
   double step = volStep;
   while(MathAbs(step - MathRound(step)) > 0.0000001 && decimals < 8) { step *= 10; decimals++; }
   return NormalizeDouble(lot, decimals);
}

double CalculateLotSize(double entry, double sl)
{
   if(!Use_Dynamic_Lot) return NormalizeVolume(Fixed_Lot);

   double slDistance = MathAbs(entry - sl);
   if(slDistance <= 0) return NormalizeVolume(Fixed_Lot);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return NormalizeVolume(Fixed_Lot);

   double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * Risk_Per_Trade / 100.0;
   double valuePerLot = (slDistance / tickSize) * tickValue;
   if(valuePerLot <= 0) return NormalizeVolume(Fixed_Lot);

   double lot = riskAmount / valuePerLot;
   return NormalizeVolume(lot);
}

//======================================================================
// Risk / trade-control gating
//======================================================================
int CountOpenPositions(int tfIndex)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic < (long)InpMagicNumber || magic >= (long)InpMagicNumber + MAX_TF) continue;
      if(tfIndex >= 0 && magic != (long)InpMagicNumber + tfIndex) continue;

      count++;
   }
   return count;
}

bool CheckRiskLimits()
{
   if(g_consecutiveLosses >= Max_Consecutive_Losses)
   {
      if(Debug_Mode) Print("[BREG] Blocked: max consecutive losses reached");
      return false;
   }
   if(g_dailyTradeCount >= Max_Trades_Per_Day)
   {
      if(Debug_Mode) Print("[BREG] Blocked: max trades per day reached");
      return false;
   }
   if(CountOpenPositions(-1) >= Max_Open_Trades)
   {
      if(Debug_Mode) Print("[BREG] Blocked: max open trades reached");
      return false;
   }
   return true;
}

bool CanOpenNewTrade(int idx)
{
   if(!CheckRiskLimits()) return false;

   if(One_Trade_Total)
   {
      if(CountOpenPositions(-1) >= 1) return false;
   }
   else if(One_Trade_Per_Timeframe)
   {
      if(CountOpenPositions(idx) >= 1) return false;
   }
   return true;
}

//======================================================================
// CheckSpread / CheckSession / News
//======================================================================
bool CheckSpread()
{
   if(!Use_Spread_Filter) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > Max_Spread_Points)
   {
      if(Debug_Mode) PrintFormat("[BREG] Spread filter blocked entry: spread=%d > max=%d", (int)spread, Max_Spread_Points);
      return false;
   }
   return true;
}

bool InSessionRange(int hour, int startH, int endH)
{
   if(startH == endH) return true;
   if(startH < endH) return hour >= startH && hour < endH;
   return (hour >= startH || hour < endH);
}

bool CheckSession()
{
   if(!Use_Session_Filter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;

   bool inLondon = Trade_London && InSessionRange(hour, Session_London_Start, Session_London_End);
   bool inNY     = Trade_NewYork && InSessionRange(hour, Session_NewYork_Start, Session_NewYork_End);
   bool inAsian  = Trade_Asian && InSessionRange(hour, Session_Asian_Start, Session_Asian_End);

   return (inLondon || inNY || inAsian);
}

void ParseNewsTimes()
{
   ArrayResize(g_newsTimes, 0);
   if(StringLen(News_Event_Times) == 0) return;

   string parts[];
   int n = StringSplit(News_Event_Times, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0) continue;

      datetime t = StringToTime(s);
      if(t > 0)
      {
         int sz = ArraySize(g_newsTimes);
         ArrayResize(g_newsTimes, sz + 1);
         g_newsTimes[sz] = t;
      }
   }
   if(Debug_Mode) PrintFormat("[BREG] Parsed %d manual news blackout times", ArraySize(g_newsTimes));
}

bool IsNewsBlackout()
{
   if(!Use_News_Filter) return false;

   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
   {
      datetime evt = g_newsTimes[i];
      datetime blockStart = evt - News_Block_Before_Minutes * 60;
      datetime blockEnd   = evt + News_Block_After_Minutes * 60;
      if(now >= blockStart && now <= blockEnd) return true;
   }
   return false;
}

//======================================================================
// ExecuteTrade
//======================================================================
void ExecuteTrade(int idx, BregSetup &setup)
{
   if(setup.traded) return;

   if(!CanOpenNewTrade(idx))
   {
      if(Debug_Mode) PrintFormat("[BREG][%s] Trade blocked by risk/trade-control limits", g_tfNames[idx]);
      InvalidateSetup(idx, setup, "Blocked by risk limits / trade control");
      return;
   }

   if(!CheckSpread()) return;      // retried on subsequent ticks while still ENTRY_READY
   if(IsNewsBlackout())
   {
      if(Debug_Mode) PrintFormat("[BREG][%s] News blackout active - trade delayed", g_tfNames[idx]);
      return;                      // retried on subsequent ticks
   }
   if(!CheckSession())
   {
      if(Debug_Mode) PrintFormat("[BREG][%s] Outside allowed session - trade skipped", g_tfNames[idx]);
      InvalidateSetup(idx, setup, "Outside allowed trading session");
      return;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      if(Debug_Mode) Print("[BREG] Trading not allowed (terminal/account/EA permissions)");
      return;
   }

   bool isBuy = (setup.dir == DIR_BULLISH);

   if(!CheckSymbolTradeMode(isBuy))
   {
      InvalidateSetup(idx, setup, "Symbol trade mode does not permit this direction right now");
      return;
   }

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = CalculateStopLoss(idx, setup, price);
   double tp = CalculateTakeProfit(idx, setup.dir, price, sl);

   long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = stopLevelPts * point;
   if(minDist > 0)
   {
      if(isBuy)
      {
         if(price - sl < minDist) sl = price - minDist;
         if(tp - price < minDist) tp = price + minDist;
      }
      else
      {
         if(sl - price < minDist) sl = price + minDist;
         if(price - tp < minDist) tp = price - minDist;
      }
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lot = CalculateLotSize(price, sl);
   if(lot <= 0)
   {
      if(Debug_Mode) Print("[BREG] Invalid lot size computed, aborting trade");
      InvalidateSetup(idx, setup, "Invalid lot size");
      return;
   }

   lot = ClampLotToFreeMargin(isBuy, price, lot);
   if(lot <= 0)
   {
      if(Debug_Mode) Print("[BREG] Insufficient free margin for even the minimum lot, aborting trade");
      InvalidateSetup(idx, setup, "Insufficient free margin");
      return;
   }

   trade.SetExpertMagicNumber(InpMagicNumber + idx);

   string cmt = StringSubstr(setup.id, 0, MathMin(StringLen(setup.id), 31));
   bool ok = SendOrderWithRecovery(isBuy, lot, price, sl, tp, cmt, digits);

   if(ok)
   {
      setup.entryPrice = price; setup.slPrice = sl; setup.tpPrice = tp; setup.traded = true;
      if(Debug_Mode)
         PrintFormat("[BREG][%s] State: ENTRY_READY -> TRADE_EXECUTED | %s executed @ %.5f SL=%.5f TP=%.5f lot=%.2f",
                     g_tfNames[idx], isBuy ? "BUY" : "SELL", price, sl, tp, lot);

      setup.state = STATE_TRADE_EXECUTED;
      DrawSetup(setup, isBuy ? "BUY" : "SELL");
      SendAlert(StringFormat("[BREG] %s %s %s executed @ %.5f SL=%.5f TP=%.5f", _Symbol, g_tfNames[idx],
                              isBuy ? "BUY" : "SELL", price, sl, tp));

      g_dailyTradeCount++;
      ResetSetup(idx, setup);
   }
   else
   {
      uint retcode = trade.ResultRetcode();
      if(Debug_Mode) PrintFormat("[BREG][%s] Order failed. Retcode=%d %s", g_tfNames[idx], retcode, trade.ResultRetcodeDescription());

      if(retcode == TRADE_RETCODE_NO_MONEY)
         InvalidateSetup(idx, setup, "Broker rejected order: insufficient margin");
      // Any other failure (requote, invalid stops, connection hiccup, etc.) is left as
      // ENTRY_READY and simply retried on the next tick by the OnTick loop, up to the
      // normal spread/news/session gates above.
   }
}

//======================================================================
// CheckSymbolTradeMode - respects broker-side long-only/short-only/close-only states
//======================================================================
bool CheckSymbolTradeMode(bool isBuy)
{
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   switch(mode)
   {
      case SYMBOL_TRADE_MODE_DISABLED:
      case SYMBOL_TRADE_MODE_CLOSEONLY:
         if(Debug_Mode) Print("[BREG] Symbol trading disabled or close-only right now");
         return false;
      case SYMBOL_TRADE_MODE_LONGONLY:
         if(!isBuy && Debug_Mode) Print("[BREG] Symbol is long-only right now - SELL setup skipped");
         return isBuy;
      case SYMBOL_TRADE_MODE_SHORTONLY:
         if(isBuy && Debug_Mode) Print("[BREG] Symbol is short-only right now - BUY setup skipped");
         return !isBuy;
      default:
         return true; // SYMBOL_TRADE_MODE_FULL
   }
}

//======================================================================
// ClampLotToFreeMargin - risk-based lot size must still be affordable
//======================================================================
double ClampLotToFreeMargin(bool isBuy, double price, double lot)
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginRequired = 0;
   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(orderType, _Symbol, lot, price, marginRequired))
      return lot; // couldn't compute (rare) - let the broker be the final judge on send

   if(marginRequired <= freeMargin) return lot;

   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double minMargin = 0;
   if(!OrderCalcMargin(orderType, _Symbol, volMin, price, minMargin) || minMargin > freeMargin)
      return 0; // can't even afford the minimum lot

   // Scale down proportionally, then re-normalize to a valid step
   double scaled = lot * (freeMargin / marginRequired) * 0.98; // small safety buffer
   double reduced = NormalizeVolume(scaled);
   if(reduced < volMin) reduced = volMin;

   if(Debug_Mode) PrintFormat("[BREG] Lot reduced from %.2f to %.2f - insufficient free margin for full risk-sized lot", lot, reduced);
   return reduced;
}

//======================================================================
// SendOrderWithRecovery - one bounded retry for transient/fixable failures
//======================================================================
bool SendOrderWithRecovery(bool isBuy, double lot, double price, double sl, double tp, string cmt, int digits)
{
   bool ok = isBuy ? trade.Buy(lot, _Symbol, price, sl, tp, cmt)
                    : trade.Sell(lot, _Symbol, price, sl, tp, cmt);
   if(ok) return true;

   uint retcode = trade.ResultRetcode();

   if(retcode == TRADE_RETCODE_REQUOTE || retcode == TRADE_RETCODE_PRICE_CHANGED)
   {
      // Re-price against the current market and try exactly once more.
      double freshPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double shift = freshPrice - price;
      double newSl = NormalizeDouble(sl + shift, digits);
      double newTp = NormalizeDouble(tp + shift, digits);
      if(Debug_Mode) Print("[BREG] Requote/price-changed - retrying once at fresh market price");
      return isBuy ? trade.Buy(lot, _Symbol, freshPrice, newSl, newTp, cmt)
                   : trade.Sell(lot, _Symbol, freshPrice, newSl, newTp, cmt);
   }

   if(retcode == TRADE_RETCODE_INVALID_STOPS)
   {
      // Widen SL/TP by one extra stop-level increment and try exactly once more.
      long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double extra = MathMax((double)stopLevelPts, 10.0) * point;
      double newSl = isBuy ? sl - extra : sl + extra;
      double newTp = isBuy ? tp + extra : tp - extra;
      newSl = NormalizeDouble(newSl, digits);
      newTp = NormalizeDouble(newTp, digits);
      if(Debug_Mode) Print("[BREG] Invalid stops - widening SL/TP and retrying once");
      return isBuy ? trade.Buy(lot, _Symbol, price, newSl, newTp, cmt)
                   : trade.Sell(lot, _Symbol, price, newSl, newTp, cmt);
   }

   return false; // any other failure is left to the caller (no further retry here)
}

//======================================================================
// ManageTrade
//======================================================================
void ManageTrade()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic < (long)InpMagicNumber || magic >= (long)InpMagicNumber + MAX_TF) continue;

      double sl = PositionGetDouble(POSITION_SL);
      if(sl == 0 && Debug_Mode) PrintFormat("[BREG] Warning: open position #%I64u has no SL set", ticket);
   }
}

void UpdateDailyCounters()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_currentDay || g_currentDay < 0)
   {
      g_currentDay = dt.day_of_year;
      g_dailyTradeCount = 0;
      if(Debug_Mode) Print("[BREG] New trading day - daily counters reset");
   }
}

//======================================================================
// ResetSetup / InvalidateSetup
//======================================================================
void ResetSetup(int idx, BregSetup &setup)
{
   if(Debug_Mode) PrintFormat("[BREG][%s] State: %s -> IDLE", g_tfNames[idx], StateToString(setup.state));

   bool wasInvalidated = (setup.state == STATE_SETUP_INVALIDATED);
   if(wasInvalidated && !Keep_Invalidated_Drawings) DeleteSetupDrawings(setup);

   ResetSetupStruct(setup, g_tfArr[idx], idx);
}

void InvalidateSetup(int idx, BregSetup &setup, string reason)
{
   if(Debug_Mode) PrintFormat("[BREG][%s] State: %s -> SETUP_INVALIDATED (%s)", g_tfNames[idx], StateToString(setup.state), reason);
   setup.state = STATE_SETUP_INVALIDATED;
   ResetSetup(idx, setup);
}

//======================================================================
// Utility: BarsBetween / StateToString
//======================================================================
int BarsBetween(string sym, ENUM_TIMEFRAMES tf, datetime fromTime)
{
   if(fromTime <= 0) return 0;
   int shift = iBarShift(sym, tf, fromTime, false);
   if(shift < 0) return 0;
   int elapsed = shift - 1;
   if(elapsed < 0) elapsed = 0;
   return elapsed;
}

string StateToString(ENUM_BREG_STATE s)
{
   switch(s)
   {
      case STATE_IDLE:                   return "IDLE";
      case STATE_BREAK_DETECTED:         return "BREAK_DETECTED";
      case STATE_WAITING_FOR_RETEST:     return "WAITING_FOR_RETEST";
      case STATE_RETEST_DETECTED:        return "RETEST_DETECTED";
      case STATE_WAITING_FOR_ENGULFING:  return "WAITING_FOR_ENGULFING";
      case STATE_ENTRY_READY:            return "ENTRY_READY";
      case STATE_TRADE_EXECUTED:         return "TRADE_EXECUTED";
      case STATE_SETUP_INVALIDATED:      return "SETUP_INVALIDATED";
      default:                           return "UNKNOWN";
   }
}

//======================================================================
// DrawSetup / DeleteSetupDrawings / DrawDashboard / SendAlert
//======================================================================
void DrawSetup(const BregSetup &setup, string tag)
{
   if(!Show_Chart_Objects) return;

   string prefix = "BREG_" + setup.id + "_";
   color dirColor = (setup.dir == DIR_BULLISH) ? clrDodgerBlue : clrOrangeRed;

   if(tag == "BOS")
   {
      string lname = prefix + "BOS";
      if(ObjectFind(0, lname) < 0)
         ObjectCreate(0, lname, OBJ_TREND, 0, setup.breakTime, setup.breakLevel,
                      TimeCurrent() + PeriodSeconds(setup.tf) * 20, setup.breakLevel);
      ObjectSetInteger(0, lname, OBJPROP_COLOR, dirColor);
      ObjectSetInteger(0, lname, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, lname, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, lname, OBJPROP_WIDTH, 1);

      string arrowName = prefix + "BREAK_ARROW";
      ObjectCreate(0, arrowName, OBJ_ARROW, 0, setup.breakTime, setup.breakLevel);
      ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, setup.dir == DIR_BULLISH ? 233 : 234);
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR, dirColor);

      string lbl = prefix + "BREAK_LBL";
      ObjectCreate(0, lbl, OBJ_TEXT, 0, setup.breakTime, setup.breakLevel);
      ObjectSetString(0, lbl, OBJPROP_TEXT, "BOS");
      ObjectSetInteger(0, lbl, OBJPROP_COLOR, dirColor);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, setup.dir == DIR_BULLISH ? ANCHOR_BOTTOM : ANCHOR_TOP);
   }
   else if(tag == "RETEST")
   {
      string nm = prefix + "RETEST";
      ObjectCreate(0, nm, OBJ_TEXT, 0, setup.retestTime, setup.retestExtreme);
      ObjectSetString(0, nm, OBJPROP_TEXT, "RETEST");
      ObjectSetInteger(0, nm, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, setup.dir == DIR_BULLISH ? ANCHOR_TOP : ANCHOR_BOTTOM);
   }
   else if(tag == "ENGULFING")
   {
      string nm = prefix + "ENGULF";
      double p = (setup.dir == DIR_BULLISH) ? setup.engulfLow : setup.engulfHigh;
      datetime t = (setup.engulfTime > 0) ? setup.engulfTime : iTime(_Symbol, setup.tf, 1);
      ObjectCreate(0, nm, OBJ_TEXT, 0, t, p);
      ObjectSetString(0, nm, OBJPROP_TEXT, "ENGULFING");
      ObjectSetInteger(0, nm, OBJPROP_COLOR, clrAqua);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, setup.dir == DIR_BULLISH ? ANCHOR_TOP : ANCHOR_BOTTOM);
   }
   else if(tag == "ENTRY_READY")
   {
      // No separate drawing; the BUY/SELL arrow is drawn on execution.
   }
   else if(tag == "BUY" || tag == "SELL")
   {
      string nm = prefix + tag;
      ObjectCreate(0, nm, OBJ_ARROW, 0, TimeCurrent(), setup.entryPrice);
      ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, tag == "BUY" ? 233 : 234);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, tag == "BUY" ? clrLime : clrRed);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 3);

      string slName = prefix + "SL";
      ObjectCreate(0, slName, OBJ_HLINE, 0, 0, setup.slPrice);
      ObjectSetInteger(0, slName, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, slName, OBJPROP_STYLE, STYLE_DOT);

      string tpName = prefix + "TP";
      ObjectCreate(0, tpName, OBJ_HLINE, 0, 0, setup.tpPrice);
      ObjectSetInteger(0, tpName, OBJPROP_COLOR, clrGreen);
      ObjectSetInteger(0, tpName, OBJPROP_STYLE, STYLE_DOT);
   }

   ChartRedraw(0);
}

void DeleteSetupDrawings(const BregSetup &setup)
{
   if(StringLen(setup.id) == 0) return;
   string prefix = "BREG_" + setup.id + "_";
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i, 0, -1);
      if(StringFind(nm, prefix) == 0) ObjectDelete(0, nm);
   }
}

void SetLabel(string name, string text, int x, int y, color c, int fontSize)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   }
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void DrawDashboard()
{
   int y = 20;
   SetLabel("BREG_DASH_TITLE", "BREG EA", 10, y, clrWhite, 12); y += 18;
   SetLabel("BREG_DASH_SYMBOL", "Symbol: " + _Symbol, 10, y, clrSilver, 9); y += 14;

   for(int k = 0; k < g_tfCount; k++)
   {
      int idx = g_activeTfList[k];
      BregSetup s = g_setups[idx];
      string dirStr = (s.dir == DIR_BULLISH) ? "Bull" : (s.dir == DIR_BEARISH ? "Bear" : "-");
      string line = StringFormat("%-4s | %-22s | %-4s | Score:%3.0f", g_tfNames[idx], StateToString(s.state), dirStr, s.score);

      color c = clrSilver;
      if(s.state == STATE_TRADE_EXECUTED)      c = clrLime;
      else if(s.state == STATE_ENTRY_READY)    c = clrYellow;
      else if(s.state == STATE_WAITING_FOR_ENGULFING || s.state == STATE_WAITING_FOR_RETEST) c = clrAqua;

      SetLabel("BREG_DASH_TF" + IntegerToString(idx), line, 10, y, c, 9);
      y += 14;
   }

   SetLabel("BREG_DASH_RISK",
            StringFormat("Risk:%.1f%%  RR:1:%.1f  Trades:%d/%d  Losses:%d/%d",
                         Risk_Per_Trade, RiskReward, g_dailyTradeCount, Max_Trades_Per_Day,
                         g_consecutiveLosses, Max_Consecutive_Losses),
            10, y, clrSilver, 9);
   y += 14;
   SetLabel("BREG_DASH_SPREAD",
            StringFormat("Spread:%d pts  Open:%d/%d",
                         (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), CountOpenPositions(-1), Max_Open_Trades),
            10, y, clrSilver, 9);

   ChartRedraw(0);
}

void SendAlert(string msg)
{
   if(Debug_Mode) Print(msg);
   if(Enable_Alerts) Alert(msg);
   if(Enable_Push_Notifications) SendNotification(msg);
}
//+------------------------------------------------------------------+
