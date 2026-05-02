//+------------------------------------------------------------------+
//| POI_FeaturesML.mqh - helpers de contexto para dataset POI         |
//| Adaptado do V2000 para o EA POI standalone.                       |
//+------------------------------------------------------------------+
#ifndef POI_FEATURESML_MQH
#define POI_FEATURESML_MQH

#include "POI_Config.mqh"
#include "POI_LuxAlgo.mqh"
#include "POI_ContextSMC.mqh"

#define POI_CSV_FLUSH_EVERY 50

struct POI_MLBarContextCache
{
   datetime chartBarTime;
   bool     valid;
   double   atr20Val;
   double   highest;
   double   lowest;
   double   rangeN;
   double   lastBOS;
   bool     hasLuxPD;
   double   rangeTop;
   double   rangeBottom;
   double   eqTop;
   double   eqBottom;
   double   eqPrice;
   double   velocity;
};

POI_MLBarContextCache poi_mlBarContextCache;

double POI_SafeDivide(const double numerator, const double denominator)
{
   if(MathAbs(denominator) <= 1e-12) return 0.0;
   return numerator / denominator;
}

int POI_MinutesBetween(const datetime newerTime, const datetime olderTime)
{
   if(newerTime <= 0 || olderTime <= 0 || newerTime <= olderTime) return 0;
   return (int)((newerTime - olderTime) / 60);
}

int POI_BarsBetweenM1(const datetime newerTime, const datetime olderTime)
{
   if(newerTime <= 0 || olderTime <= 0 || newerTime <= olderTime) return 0;
   return (int)((newerTime - olderTime) / PeriodSeconds(PERIOD_M1));
}

datetime POI_GetCurrentFeatureBarTime()
{
   if(POI_ContextHasState() && poi_ctxTimeArr[0] > 0)
      return poi_ctxTimeArr[0];
   return (luxBarsCount > 0 && timeArr[0] > 0) ? timeArr[0] : TimeCurrent();
}

double POI_GetCurrentATRPeriod(const int period)
{
   if(POI_ContextHasState())
   {
      int ctxCount = MathMax(1, period);
      if(ctxCount > poi_ctxBarsCount - 1)
         ctxCount = poi_ctxBarsCount - 1;
      if(ctxCount <= 0) return 0.0;

      double sum = 0.0;
      for(int i = 0; i < ctxCount; i++)
      {
         double prevClose = (i + 1 < poi_ctxBarsCount) ? poi_ctxRawCloses[i + 1] : poi_ctxRawCloses[i];
         double tr = poi_ctxRawHighs[i] - poi_ctxRawLows[i];
         double a = MathAbs(poi_ctxRawHighs[i] - prevClose);
         double b = MathAbs(poi_ctxRawLows[i] - prevClose);
         if(a > tr) tr = a;
         if(b > tr) tr = b;
         sum += tr;
      }

      return sum / (double)ctxCount;
   }

   int count = MathMax(1, period);
   if(count > luxBarsCount - 1)
      count = luxBarsCount - 1;
   if(count <= 0) return 0.0;

   double sum = 0.0;
   for(int i = 0; i < count; i++)
   {
      double prevClose = (i + 1 < luxBarsCount) ? rawCloses[i + 1] : rawCloses[i];
      double tr = rawHighs[i] - rawLows[i];
      double a = MathAbs(rawHighs[i] - prevClose);
      double b = MathAbs(rawLows[i] - prevClose);
      if(a > tr) tr = a;
      if(b > tr) tr = b;
      sum += tr;
   }

   return sum / (double)count;
}

double POI_GetCurrentATR()
{
   if(POI_ContextHasState() && poi_ctxVolatilityArr[0] > 0.0)
      return poi_ctxVolatilityArr[0];
   return POI_GetCurrentATRPeriod(14);
}

double POI_GetCurrentATR20()
{
   return POI_GetCurrentATRPeriod(20);
}

double POI_GetCurrentATR5()
{
   return POI_GetCurrentATRPeriod(5);
}

void POI_ResetMLFeatureCaches()
{
   poi_mlBarContextCache.valid = false;
   poi_mlBarContextCache.chartBarTime = 0;
}

void POI_EnsureMLBarContextCache(const double atrVal)
{
   datetime currentBarTime = POI_GetCurrentFeatureBarTime();
   if(poi_mlBarContextCache.valid && poi_mlBarContextCache.chartBarTime == currentBarTime)
      return;

   int n = MathMax(2, POIDatasetLookbackN);
   int barsAvailable = POI_ContextHasState() ? poi_ctxBarsCount : luxBarsCount;
   if(n > barsAvailable)
      n = barsAvailable;

   double highest = 0.0;
   double lowest = 0.0;
   if(n > 0)
   {
      highest = POI_ContextHasState() ? poi_ctxRawHighs[0] : rawHighs[0];
      lowest  = POI_ContextHasState() ? poi_ctxRawLows[0]  : rawLows[0];
      for(int i = 1; i < n; i++)
      {
         double hi = POI_ContextHasState() ? poi_ctxRawHighs[i] : rawHighs[i];
         double lo = POI_ContextHasState() ? poi_ctxRawLows[i]  : rawLows[i];
         if(hi > highest) highest = hi;
         if(lo < lowest) lowest = lo;
      }
   }

   double lastBOS = 0.0;
   if(POI_ContextHasState())
   {
      for(int i = poi_ctxEventCount - 1; i >= 0; i--)
      {
         if(poi_ctxEvents[i].breakTime <= TimeCurrent())
         {
            lastBOS = poi_ctxEvents[i].level;
            break;
         }
      }
   }
   else
   {
      for(int i = luxEventCount - 1; i >= 0; i--)
      {
         if(luxEvents[i].breakTime <= TimeCurrent())
         {
            lastBOS = luxEvents[i].level;
            break;
         }
      }
   }

   double atr20Val = POI_GetCurrentATR20();
   if(atr20Val <= 0.0) atr20Val = atrVal;

   double velocity = 0.0;
   int velocityShift = MathMax(1, POIDatasetVelocityN);
   if(velocityShift < barsAvailable && atrVal > 0.0)
   {
      double close0 = POI_ContextHasState() ? poi_ctxRawCloses[0] : rawCloses[0];
      double closeN = POI_ContextHasState() ? poi_ctxRawCloses[velocityShift] : rawCloses[velocityShift];
      velocity = (close0 - closeN) / ((double)velocityShift * atrVal);
   }

   double rangeTop = highest;
   double rangeBottom = lowest;
   double eqPrice = (rangeTop + rangeBottom) * 0.5;
   double width = rangeTop - rangeBottom;
   double eqBand = width * 0.05;

   poi_mlBarContextCache.chartBarTime = currentBarTime;
   poi_mlBarContextCache.valid = true;
   poi_mlBarContextCache.atr20Val = atr20Val;
   poi_mlBarContextCache.highest = highest;
   poi_mlBarContextCache.lowest = lowest;
   poi_mlBarContextCache.rangeN = width;
   poi_mlBarContextCache.lastBOS = lastBOS;
   poi_mlBarContextCache.hasLuxPD = (width > 0.0);
   poi_mlBarContextCache.rangeTop = rangeTop;
   poi_mlBarContextCache.rangeBottom = rangeBottom;
   poi_mlBarContextCache.eqTop = eqPrice + eqBand;
   poi_mlBarContextCache.eqBottom = eqPrice - eqBand;
   poi_mlBarContextCache.eqPrice = eqPrice;
   poi_mlBarContextCache.velocity = velocity;
}

int POI_ClassifyPDZoneCached(const double price)
{
   if(!poi_mlBarContextCache.valid || !poi_mlBarContextCache.hasLuxPD)
      return 0;
   if(price > poi_mlBarContextCache.eqTop) return 1;
   if(price < poi_mlBarContextCache.eqBottom) return -1;
   return 0;
}

double POI_LuxRangePositionCached(const double price)
{
   if(!poi_mlBarContextCache.valid || !poi_mlBarContextCache.hasLuxPD)
      return 0.0;

   double width = poi_mlBarContextCache.rangeTop - poi_mlBarContextCache.rangeBottom;
   if(width <= 0.0) return 0.0;
   return (price - poi_mlBarContextCache.rangeBottom) / width;
}

#endif
