//+------------------------------------------------------------------+
//|                                    02_BREG_Visual_Detector.mq5   |
//|                                                                    |
//| STAGE 2 of the BREG build order:                                  |
//|   1. BREG definition (docs/01_STRATEGY_DEFINITION.md)             |
//|   2. Visual BREG detector                    <- this file         |
//|   3. Backtestable BREG engine                                     |
//|   4-7. Trade execution / risk / multi-TF / advanced filters        |
//|   8. Optimization  9. Demo  10. Live                              |
//|                                                                    |
//| This EA places NO orders and has NO trading logic whatsoever. Its |
//| only job is to detect the BREG sequence (Break -> Retest ->       |
//| Engulfing) exactly as defined in Stage 1 and draw it on the chart |
//| so it can be visually confirmed against your own chart reading    |
//| before any money-related logic is trusted or built on top of it. |
//|                                                                    |
//| Rules implemented here are the mechanical ones from Stage 1        |
//| (Break/Retest/Engulfing/Invalidation). SL/TP, scoring, liquidity,  |
//| HTF filtering, and risk management are later stages and are        |
//| intentionally absent from this file.                              |
//+------------------------------------------------------------------+
#property copyright "BREG EA - Stage 2"
#property version   "2.00"
#property description "BREG visual detector - detection & drawing only, no trading"

//======================================================================
// ENUMERATIONS
//======================================================================
enum ENUM_PRIMARY_TF
{
   PRIMARY_AUTO,
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

input group "Swing & Structure Detection"
input int    Swing_Left_Bars         = 3;
input int    Swing_Right_Bars        = 3;
input double Minimum_Swing_Distance  = 100;    // points of prominence required (XAUUSD @ 2-digit: ~$1.00)
input double Minimum_Break_Distance  = 20;     // points close must clear the level by (~$0.20)
input int    Swing_Lookback_Bars     = 100;

input group "Retest Parameters"
input int    Retest_Max_Bars                  = 5;    // "a few bars"
input double Retest_Tolerance_Points           = 80;   // ~$0.80 on XAUUSD @ 2-digit
input double Retest_Min_Depth                  = 0;
input double Retest_Max_Depth                  = 400;  // ~$4.00 on XAUUSD @ 2-digit
input double Retest_Invalidation_Buffer_Points = 150;  // ~$1.50 on XAUUSD @ 2-digit

input group "Engulfing Confirmation"
input bool   Use_Strict_Engulfing            = true;   // full-body engulf AND a decisive/strong candle
input double Engulfing_Min_Body_Ratio        = 1.0;    // engulfing body vs previous candle's body
input double Engulfing_Min_Avg_Body_Ratio    = 1.2;    // engulfing body vs recent average body ("decisive", not weak)
input int    Engulfing_Avg_Lookback_Bars     = 10;     // averaging window for the decisive-candle check
input int    Engulfing_Max_Bars_After_Retest = 3;

input group "Visual Interface"
input bool   Show_Chart_Objects        = true;
input bool   Show_Dashboard            = true;
input int    Dashboard_Refresh_Seconds = 1;
input bool   Keep_Invalidated_Drawings = false;
input bool   Enable_Alerts             = false;

input group "Debug"
input bool   Debug_Mode               = true;

//======================================================================
// DATA
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
   datetime         createdTime;
};

#define MAX_TF 6
ENUM_TIMEFRAMES g_tfArr[MAX_TF]   = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4};
string          g_tfNames[MAX_TF] = {"M1","M5","M15","M30","H1","H4"};

BregSetup       g_setups[MAX_TF];
datetime        g_lastBarTime[MAX_TF];
int             g_activeTfList[MAX_TF];
int             g_tfCount = 0;
int             g_signalsToday = 0;
int             g_currentDay = -1;
uint            g_lastDashboardUpdateMs = 0;

//======================================================================
// LIFECYCLE
//======================================================================
int OnInit()
{
   BuildActiveTFList();
   for(int i = 0; i < MAX_TF; i++)
   {
      ResetSetupStruct(g_setups[i], g_tfArr[i], i);
      g_lastBarTime[i] = 0;
   }

   if(g_tfCount == 0)
   {
      Print("[BREG] ERROR: no timeframes are enabled.");
      return INIT_FAILED;
   }

   if(Debug_Mode)
   {
      string list = "";
      for(int k = 0; k < g_tfCount; k++) list += g_tfNames[g_activeTfList[k]] + " ";
      PrintFormat("[BREG][Stage 2: Visual Detector] Initialized on %s. Active timeframes: %s. No orders will be placed.", _Symbol, list);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "BREG_");
}

void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_currentDay || g_currentDay < 0)
   {
      g_currentDay = dt.day_of_year;
      g_signalsToday = 0;
   }

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
   }

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

//======================================================================
// Setup / timeframe list helpers
//======================================================================
void BuildActiveTFList()
{
   bool enabledFlags[MAX_TF];
   enabledFlags[0] = Enable_M1; enabledFlags[1] = Enable_M5; enabledFlags[2] = Enable_M15;
   enabledFlags[3] = Enable_M30; enabledFlags[4] = Enable_H1; enabledFlags[5] = Enable_H4;

   g_tfCount = 0;
   if(Primary_Timeframe == PRIMARY_AUTO)
   {
      for(int i = 0; i < MAX_TF; i++)
         if(enabledFlags[i]) g_activeTfList[g_tfCount++] = i;
   }
   else
   {
      g_activeTfList[0] = PrimaryEnumToIndex(Primary_Timeframe);
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
   s.id = ""; s.tf = tf; s.tfIndex = idx;
   s.state = STATE_IDLE; s.dir = DIR_NONE;
   s.breakLevel = 0; s.breakTime = 0;
   s.retestTime = 0; s.retestExtreme = 0; s.retestDepthPts = 0;
   s.engulfTime = 0; s.engulfOpen = 0; s.engulfClose = 0; s.engulfHigh = 0; s.engulfLow = 0; s.engulfBodyRatio = 0;
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
      case STATE_IDLE:                  DetectBreak(idx, setup);     break;
      case STATE_WAITING_FOR_RETEST:    DetectRetest(idx, setup);    break;
      case STATE_WAITING_FOR_ENGULFING: DetectEngulfing(idx, setup); break;
      default: break;
   }

   g_setups[idx] = setup;
}

//======================================================================
// Swing structure
//======================================================================
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

double DetectSwingStructure(string sym, ENUM_TIMEFRAMES tf, ENUM_SETUP_DIR dir, int startShift, datetime &swingTimeOut)
{
   int bars = iBars(sym, tf);
   int limit = startShift + Swing_Lookback_Bars;
   if(limit > bars - Swing_Left_Bars - 2) limit = bars - Swing_Left_Bars - 2;

   for(int s = startShift; s < limit; s++)
   {
      if(dir == DIR_BULLISH)
      {
         if(IsValidSwingHigh(sym, tf, s, Swing_Left_Bars, Swing_Right_Bars, Minimum_Swing_Distance))
         {
            swingTimeOut = iTime(sym, tf, s);
            return iHigh(sym, tf, s);
         }
      }
      else
      {
         if(IsValidSwingLow(sym, tf, s, Swing_Left_Bars, Swing_Right_Bars, Minimum_Swing_Distance))
         {
            swingTimeOut = iTime(sym, tf, s);
            return iLow(sym, tf, s);
         }
      }
   }
   return 0.0;
}

//======================================================================
// Break
//======================================================================
bool ValidateBreak(string sym, ENUM_TIMEFRAMES tf, ENUM_SETUP_DIR dir, double level)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double closeBar = iClose(sym, tf, 1);
   bool directionOk = (dir == DIR_BULLISH) ? (closeBar > level) : (closeBar < level);
   if(!directionOk) return false;
   double breakDist = (dir == DIR_BULLISH) ? (closeBar - level) / point : (level - closeBar) / point;
   return breakDist >= Minimum_Break_Distance;
}

void DetectBreak(int idx, BregSetup &setup)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;
   datetime swingTime = 0;

   double swingHigh = DetectSwingStructure(sym, tf, DIR_BULLISH, 2, swingTime);
   if(swingHigh > 0 && ValidateBreak(sym, tf, DIR_BULLISH, swingHigh))
   {
      CreateSetupFromBreak(idx, setup, DIR_BULLISH, swingHigh);
      return;
   }

   double swingLow = DetectSwingStructure(sym, tf, DIR_BEARISH, 2, swingTime);
   if(swingLow > 0 && ValidateBreak(sym, tf, DIR_BEARISH, swingLow))
   {
      CreateSetupFromBreak(idx, setup, DIR_BEARISH, swingLow);
      return;
   }
}

void CreateSetupFromBreak(int idx, BregSetup &setup, ENUM_SETUP_DIR dir, double level)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;

   ResetSetupStruct(setup, tf, idx);
   setup.state = STATE_BREAK_DETECTED;
   setup.dir = dir;
   setup.breakLevel = level;
   setup.breakTime = iTime(sym, tf, 1);
   setup.createdTime = TimeCurrent();
   setup.id = StringFormat("%s_%s_%s_%d", sym, g_tfNames[idx], dir == DIR_BULLISH ? "BULL" : "BEAR", (int)setup.breakTime);

   if(Debug_Mode)
   {
      PrintFormat("[BREG][%s] State: IDLE -> BREAK_DETECTED", g_tfNames[idx]);
      PrintFormat("[BREG][%s] %s BOS detected @ %.5f (close=%.5f)", g_tfNames[idx],
                  dir == DIR_BULLISH ? "Bullish" : "Bearish", level, iClose(sym, tf, 1));
   }
   DrawSetup(setup, "BOS");

   if(Debug_Mode) PrintFormat("[BREG][%s] State: BREAK_DETECTED -> WAITING_FOR_RETEST", g_tfNames[idx]);
   setup.state = STATE_WAITING_FOR_RETEST;
}

//======================================================================
// Retest
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

int BarsBetween(string sym, ENUM_TIMEFRAMES tf, datetime fromTime)
{
   if(fromTime <= 0) return 0;
   int shift = iBarShift(sym, tf, fromTime, false);
   if(shift < 0) return 0;
   int elapsed = shift - 1;
   if(elapsed < 0) elapsed = 0;
   return elapsed;
}

bool StrongCloseThrough(ENUM_SETUP_DIR dir, double breakLevel, double close1)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double invLevel = (dir == DIR_BULLISH)
      ? breakLevel - (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point
      : breakLevel + (Retest_Tolerance_Points + Retest_Invalidation_Buffer_Points) * point;
   return (dir == DIR_BULLISH) ? (close1 < invLevel) : (close1 > invLevel);
}

void DetectRetest(int idx, BregSetup &setup)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;

   int barsSinceBreak = BarsBetween(sym, tf, setup.breakTime);
   if(barsSinceBreak > Retest_Max_Bars)
   {
      InvalidateSetup(idx, setup, "Retest window exceeded");
      return;
   }

   double low1 = iLow(sym, tf, 1), high1 = iHigh(sym, tf, 1), close1 = iClose(sym, tf, 1);

   if(StrongCloseThrough(setup.dir, setup.breakLevel, close1))
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
// Engulfing
//======================================================================
double GetAvgBodyRatio(string sym, ENUM_TIMEFRAMES tf, int shift)
{
   double body = MathAbs(iClose(sym, tf, shift) - iOpen(sym, tf, shift));
   double sum = 0; int n = 0;
   for(int i = shift + 1; i <= shift + Engulfing_Avg_Lookback_Bars; i++)
   {
      sum += MathAbs(iClose(sym, tf, i) - iOpen(sym, tf, i));
      n++;
   }
   if(n == 0) return 0;
   double avg = sum / n;
   if(avg <= 0) return 0;
   return body / avg;
}

bool EvaluateEngulfing(string sym, ENUM_TIMEFRAMES tf, int shift, ENUM_SETUP_DIR dir, BregSetup &setup)
{
   double open1 = iOpen(sym, tf, shift),  close1 = iClose(sym, tf, shift);
   double high1 = iHigh(sym, tf, shift),  low1   = iLow(sym, tf, shift);
   double open2 = iOpen(sym, tf, shift + 1), close2 = iClose(sym, tf, shift + 1);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

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

   double avgRatio = GetAvgBodyRatio(sym, tf, shift);
   if(Use_Strict_Engulfing && avgRatio < Engulfing_Min_Avg_Body_Ratio) return false; // weak engulf - not recognized yet

   setup.engulfOpen = open1; setup.engulfClose = close1;
   setup.engulfHigh = high1; setup.engulfLow = low1;
   setup.engulfBodyRatio = ratio;
   return true;
}

void DetectEngulfing(int idx, BregSetup &setup)
{
   ENUM_TIMEFRAMES tf = g_tfArr[idx];
   string sym = _Symbol;

   double close1 = iClose(sym, tf, 1);
   if(StrongCloseThrough(setup.dir, setup.breakLevel, close1))
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

   if(!EvaluateEngulfing(sym, tf, 1, setup.dir, setup)) return; // not yet - keep waiting, up to the window above

   setup.engulfTime = iTime(sym, tf, 1);
   if(Debug_Mode)
   {
      PrintFormat("[BREG][%s] %s engulfing detected (body ratio=%.2f)", g_tfNames[idx], setup.dir == DIR_BULLISH ? "Bullish" : "Bearish", setup.engulfBodyRatio);
      PrintFormat("[BREG][%s] State: WAITING_FOR_ENGULFING -> ENTRY_READY", g_tfNames[idx]);
   }
   setup.state = STATE_ENTRY_READY;
   DrawSetup(setup, "ENGULFING");
   DrawSetup(setup, "SIGNAL");

   g_signalsToday++;
   string msg = StringFormat("[BREG] %s %s %s SIGNAL CONFIRMED @ %.5f (break %.5f, retest %.5f)",
                              sym, g_tfNames[idx], setup.dir == DIR_BULLISH ? "BULLISH" : "BEARISH",
                              setup.engulfClose, setup.breakLevel, setup.retestExtreme);
   if(Debug_Mode) Print(msg);
   if(Enable_Alerts) Alert(msg);

   ResetSetup(idx, setup); // confirmed and logged - go back to hunting for the next one
}

//======================================================================
// Reset / invalidate
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

string StateToString(ENUM_BREG_STATE s)
{
   switch(s)
   {
      case STATE_IDLE:                  return "IDLE";
      case STATE_BREAK_DETECTED:        return "BREAK_DETECTED";
      case STATE_WAITING_FOR_RETEST:    return "WAITING_FOR_RETEST";
      case STATE_RETEST_DETECTED:       return "RETEST_DETECTED";
      case STATE_WAITING_FOR_ENGULFING: return "WAITING_FOR_ENGULFING";
      case STATE_ENTRY_READY:           return "ENTRY_READY (signal only - no order placed)";
      case STATE_SETUP_INVALIDATED:     return "SETUP_INVALIDATED";
      default:                          return "UNKNOWN";
   }
}

//======================================================================
// Drawing
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
      ObjectCreate(0, nm, OBJ_TEXT, 0, setup.engulfTime, p);
      ObjectSetString(0, nm, OBJPROP_TEXT, "ENGULFING");
      ObjectSetInteger(0, nm, OBJPROP_COLOR, clrAqua);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, setup.dir == DIR_BULLISH ? ANCHOR_TOP : ANCHOR_BOTTOM);
   }
   else if(tag == "SIGNAL")
   {
      string nm = prefix + "SIGNAL";
      ObjectCreate(0, nm, OBJ_ARROW, 0, setup.engulfTime, setup.engulfClose);
      ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, setup.dir == DIR_BULLISH ? 233 : 234);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, setup.dir == DIR_BULLISH ? clrLime : clrRed);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 3);
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
   SetLabel("BREG_DASH_TITLE", "BREG EA - Stage 2: Visual Detector (no trading)", 10, y, clrWhite, 12); y += 18;
   SetLabel("BREG_DASH_SYMBOL", "Symbol: " + _Symbol + "   Signals today: " + IntegerToString(g_signalsToday), 10, y, clrSilver, 9); y += 14;

   for(int k = 0; k < g_tfCount; k++)
   {
      int idx = g_activeTfList[k];
      BregSetup s = g_setups[idx];
      string dirStr = (s.dir == DIR_BULLISH) ? "Bull" : (s.dir == DIR_BEARISH ? "Bear" : "-");
      string line = StringFormat("%-4s | %-40s | %-4s", g_tfNames[idx], StateToString(s.state), dirStr);
      color c = (s.state == STATE_WAITING_FOR_ENGULFING || s.state == STATE_WAITING_FOR_RETEST) ? clrAqua : clrSilver;
      SetLabel("BREG_DASH_TF" + IntegerToString(idx), line, 10, y, c, 9);
      y += 14;
   }
   ChartRedraw(0);
}
