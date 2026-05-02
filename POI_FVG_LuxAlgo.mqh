//+------------------------------------------------------------------+
//| POI_FVG_LuxAlgo.mqh - FVG context ported from V2000               |
//| Active FVG buffer only; no visual objects.                        |
//+------------------------------------------------------------------+
#ifndef POI_FVG_LUXALGO_MQH
#define POI_FVG_LUXALGO_MQH

#include "POI_Config.mqh"
#include "POI_ContextSMC.mqh"

#define LUX_FVG_MAX 500
#define LUX_FVG_NOT_FOUND_BARS 9999

struct LuxAlgoFVGEntry
{
   long     id;
   double   top;
   double   bottom;
   int      bias;
   datetime leftTime;
   datetime rightTime;
   double   mid;
};

LuxAlgoFVGEntry g_luxFvgBuf[LUX_FVG_MAX];
int             g_luxFvgCount = 0;
long            g_luxFvgNextId = 1;

void POI_LuxFVGReset()
{
   g_luxFvgCount = 0;
   g_luxFvgNextId = 1;
}

datetime LuxFVG_HtfBarOpen(const string sym, const ENUM_TIMEFRAMES tf, const datetime t)
{
   int sh = iBarShift(sym, tf, t, false);
   if(sh < 0) return 0;
   return iTime(sym, tf, sh);
}

bool LuxFVG_NewHtfPeriodAtContextBar(const int c, const int barsCount, const ENUM_TIMEFRAMES htf,
                                     const datetime &chartTimes[])
{
   if(c < 0 || c + 1 >= barsCount) return false;
   datetime a = LuxFVG_HtfBarOpen(_Symbol, htf, chartTimes[c]);
   datetime b = LuxFVG_HtfBarOpen(_Symbol, htf, chartTimes[c + 1]);
   return (a != b && a != 0 && b != 0);
}

void LuxFVG_RemoveAt(const int idx)
{
   if(idx < 0 || idx >= g_luxFvgCount) return;
   for(int j = idx; j < g_luxFvgCount - 1; j++)
      g_luxFvgBuf[j] = g_luxFvgBuf[j + 1];
   g_luxFvgCount--;
}

void LuxFVG_DeleteMitigated(const double chartLow, const double chartHigh)
{
   for(int i = g_luxFvgCount - 1; i >= 0; i--)
   {
      bool kill = false;
      if(g_luxFvgBuf[i].bias == POI_BULLISH && chartLow < g_luxFvgBuf[i].bottom)
         kill = true;
      else if(g_luxFvgBuf[i].bias == POI_BEARISH && chartHigh > g_luxFvgBuf[i].top)
         kill = true;

      if(kill)
         LuxFVG_RemoveAt(i);
   }
}

void LuxFVG_Unshift(const LuxAlgoFVGEntry &ng)
{
   if(g_luxFvgCount > 0)
   {
      int lim = MathMin(g_luxFvgCount, LUX_FVG_MAX - 1);
      for(int u = lim; u > 0; u--)
         g_luxFvgBuf[u] = g_luxFvgBuf[u - 1];
   }

   g_luxFvgBuf[0] = ng;
   if(g_luxFvgCount < LUX_FVG_MAX)
      g_luxFvgCount++;
   else
      g_luxFvgCount = LUX_FVG_MAX;
}

double LuxFVG_Size(const LuxAlgoFVGEntry &g)
{
   return MathAbs(g.top - g.bottom);
}

void POI_LuxFVGContextRun(const bool fairValueGapsAutoThreshold,
                          const ENUM_TIMEFRAMES fairValueGapsTFIn,
                          const int fairValueGapsExtend)
{
   POI_LuxFVGReset();
   if(!POIContextBuildFVG || !POI_ContextHasState())
      return;

   const int extBars = MathMax(0, fairValueGapsExtend);
   const ENUM_TIMEFRAMES baseTf = POI_ContextBaseTimeframe();
   const ENUM_TIMEFRAMES htf = (fairValueGapsTFIn == PERIOD_CURRENT) ? baseTf : fairValueGapsTFIn;

   int barsCount = poi_ctxBarsCount;
   if(barsCount < 5) return;

   double cumAbs = 0.0;
   int lastFvgChartIndex = -1;
   const bool useCurrentTfFastPath = (htf == baseTf);

   for(int c = barsCount - 1; c >= 0; c--)
   {
      LuxFVG_DeleteMitigated(poi_ctxRawLows[c], poi_ctxRawHighs[c]);

      double lastClose = 0.0;
      double lastOpen = 0.0;
      datetime lastTime = 0;
      double currentHigh = 0.0;
      double currentLow = 0.0;
      datetime currentTime = 0;
      double last2High = 0.0;
      double last2Low = 0.0;
      bool newTf = false;

      if(useCurrentTfFastPath && (c + 2) < barsCount)
      {
         lastClose = poi_ctxRawCloses[c + 1];
         lastOpen = poi_ctxRawOpens[c + 1];
         lastTime = poi_ctxTimeArr[c + 1];
         currentHigh = poi_ctxRawHighs[c];
         currentLow = poi_ctxRawLows[c];
         currentTime = poi_ctxTimeArr[c];
         last2High = poi_ctxRawHighs[c + 2];
         last2Low = poi_ctxRawLows[c + 2];
         newTf = (c + 1 < barsCount);
      }
      else
      {
         datetime tc = poi_ctxTimeArr[c];
         int s = iBarShift(_Symbol, htf, tc, false);
         if(s < 2) continue;

         lastClose    = iClose(_Symbol, htf, s + 1);
         lastOpen     = iOpen(_Symbol, htf, s + 1);
         lastTime     = iTime(_Symbol, htf, s + 1);
         currentHigh  = iHigh(_Symbol, htf, s);
         currentLow   = iLow(_Symbol, htf, s);
         currentTime  = iTime(_Symbol, htf, s);
         last2High    = iHigh(_Symbol, htf, s + 2);
         last2Low     = iLow(_Symbol, htf, s + 2);
         newTf = (c + 1 < barsCount) &&
                 LuxFVG_NewHtfPeriodAtContextBar(c, barsCount, htf, poi_ctxTimeArr);
      }

      if(lastOpen == 0.0)
         continue;

      double barDeltaPercent = (lastClose - lastOpen) / (lastOpen * 100.0);
      if(newTf)
         cumAbs += MathAbs(barDeltaPercent);

      int pineBarIndex = barsCount - 1 - c;
      double threshold = 0.0;
      if(fairValueGapsAutoThreshold && pineBarIndex > 0)
         threshold = (cumAbs / (double)pineBarIndex) * 2.0;

      bool bullishFVG = (currentLow > last2High && lastClose > last2High &&
                         barDeltaPercent > threshold && newTf);
      bool bearishFVG = (currentHigh < last2Low && lastClose < last2Low &&
                         (-barDeltaPercent) > threshold && newTf);

      datetime extendDt = currentTime;
      if(c + 1 < barsCount)
         extendDt = currentTime + (datetime)(extBars * (long)(poi_ctxTimeArr[c] - poi_ctxTimeArr[c + 1]));
      else
         extendDt = currentTime + (datetime)(extBars * (long)PeriodSeconds(baseTf));

      if(bullishFVG)
      {
         LuxAlgoFVGEntry ng;
         ng.id        = g_luxFvgNextId++;
         ng.top       = currentLow;
         ng.bottom    = last2High;
         ng.bias      = POI_BULLISH;
         ng.leftTime  = lastTime;
         ng.rightTime = extendDt;
         ng.mid       = (ng.top + ng.bottom) / 2.0;

         bool consecutiveToLast = (lastFvgChartIndex >= 0 && lastFvgChartIndex == c + 1);
         if(consecutiveToLast && g_luxFvgCount > 0)
         {
            if(LuxFVG_Size(ng) > LuxFVG_Size(g_luxFvgBuf[0]))
               g_luxFvgBuf[0] = ng;
         }
         else
            LuxFVG_Unshift(ng);

         lastFvgChartIndex = c;
      }
      else if(bearishFVG)
      {
         LuxAlgoFVGEntry ng;
         ng.id        = g_luxFvgNextId++;
         ng.top       = currentHigh;
         ng.bottom    = last2Low;
         ng.bias      = POI_BEARISH;
         ng.leftTime  = lastTime;
         ng.rightTime = extendDt;
         ng.mid       = (ng.top + ng.bottom) / 2.0;

         bool consecutiveToLast = (lastFvgChartIndex >= 0 && lastFvgChartIndex == c + 1);
         if(consecutiveToLast && g_luxFvgCount > 0)
         {
            if(LuxFVG_Size(ng) > LuxFVG_Size(g_luxFvgBuf[0]))
               g_luxFvgBuf[0] = ng;
         }
         else
            LuxFVG_Unshift(ng);

         lastFvgChartIndex = c;
      }
   }
}

#endif
