//+------------------------------------------------------------------+

//| RoboSMC_FeaturesML.mqh â€” ML feature vector + CSV (Original v200) |

//+------------------------------------------------------------------+

#ifndef ROBOSMC_V2000_FEATURESML_MQH

#define ROBOSMC_V2000_FEATURESML_MQH

#include "ROBOSMC_V2000_POI_only_SMC.mqh"
#include "ROBOSMC_V2000_POI_only_FVG_LuxAlgo.mqh"

TradeSample samples[MAX_SAMPLES];

int         sampleCount  = 0;

long        nextSampleId = 1;

datetime sampledOBTimes[MAX_SAMPLED];

int      sampledOBBias[MAX_SAMPLED];

int      sampledOBType[MAX_SAMPLED];

int      sampledOBCount = 0;

bool csvHeaderWritten = false;

string csvBuffer      = "";

int    csvBufferCount = 0;

#define MAX_FVG_OB_CACHE 256
#define MAX_ML_OB_CONTEXT_CACHE 256

struct CachedOBFVGStats
{
   datetime obTime;
   int      obBias;
   datetime chartBarTime;
   bool     valid;
   int      sameCount;
   int      oppositeCount;
   int      sameActiveAtTouch;
   int      oppositeActiveAtTouch;
   int      firstSameBars;
   double   firstSameSizeRaw;
   int      sameWithinCount;
   double   sameWithinTotalSizeRaw;
   int      oppositeWithinCount;
};

CachedOBFVGStats g_cachedObFvgStats[MAX_FVG_OB_CACHE];
int              g_cachedObFvgStatsCount = 0;
datetime         g_cachedObFvgStatsBarTime = 0;

struct MLBarContextCache
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

struct MLOBContextCache
{
   datetime chartBarTime;
   datetime obTime;
   int      obBias;
   bool     isInternal;
   bool     valid;
   int      obBarIndex;
   int      barsSinceOB;
   double   approachCleanliness;
   double   liqSweepDepthATR;
   double   liqSweepRejectionStrength;
   int      liqSweepBarsToOB;
   int      liqSweepBeforeOB;
   double   creatorBOSLevel;
};

MLBarContextCache g_mlBarContextCache;
MLOBContextCache  g_mlObContextCache[MAX_ML_OB_CONTEXT_CACHE];
int               g_mlObContextCacheCount = 0;
datetime          g_mlObContextCacheBarTime = 0;

#define CSV_FLUSH_EVERY 50

static const int CSV_META_MIN_OB_POINTS = 50;
static const int LIQ_SWEEP_MAX_BARS_TO_OB = 5;
static const double LIQ_SWEEP_MIN_REJECTION_ATR = 0.5;

datetime GetCurrentFeatureBarTime()
{
   return timeArr[0];
}

void ResetMLFeatureCaches()
{
   g_mlBarContextCache.valid = false;
   g_mlBarContextCache.chartBarTime = 0;
   g_mlObContextCacheCount = 0;
   g_mlObContextCacheBarTime = 0;
   ResetCachedOBFVGStats();
}

void ResetCachedOBFVGStats()
{
   g_cachedObFvgStatsCount = 0;
   g_cachedObFvgStatsBarTime = timeArr[0];
}

bool GetCachedOBFVGStats(const datetime obTime,
                         const int obBias,
                         int &sameCount,
                         int &oppositeCount,
                         int &sameActiveAtTouch,
                         int &oppositeActiveAtTouch,
                         int &firstSameBars,
                         double &firstSameSizeRaw,
                         int &sameWithinCount,
                         double &sameWithinTotalSizeRaw,
                         int &oppositeWithinCount)
{
   datetime currentBarTime = timeArr[0];
   if(currentBarTime != g_cachedObFvgStatsBarTime)
      ResetCachedOBFVGStats();

   for(int i = 0; i < g_cachedObFvgStatsCount; i++)
   {
      if(!g_cachedObFvgStats[i].valid) continue;
      if(g_cachedObFvgStats[i].obTime != obTime) continue;
      if(g_cachedObFvgStats[i].obBias != obBias) continue;
      if(g_cachedObFvgStats[i].chartBarTime != currentBarTime) continue;

      sameCount = g_cachedObFvgStats[i].sameCount;
      oppositeCount = g_cachedObFvgStats[i].oppositeCount;
      sameActiveAtTouch = g_cachedObFvgStats[i].sameActiveAtTouch;
      oppositeActiveAtTouch = g_cachedObFvgStats[i].oppositeActiveAtTouch;
      firstSameBars = g_cachedObFvgStats[i].firstSameBars;
      firstSameSizeRaw = g_cachedObFvgStats[i].firstSameSizeRaw;
      sameWithinCount = g_cachedObFvgStats[i].sameWithinCount;
      sameWithinTotalSizeRaw = g_cachedObFvgStats[i].sameWithinTotalSizeRaw;
      oppositeWithinCount = g_cachedObFvgStats[i].oppositeWithinCount;
      return true;
   }

   return false;
}

void CacheOBFVGStats(const datetime obTime,
                     const int obBias,
                     const int sameCount,
                     const int oppositeCount,
                     const int sameActiveAtTouch,
                     const int oppositeActiveAtTouch,
                     const int firstSameBars,
                     const double firstSameSizeRaw,
                     const int sameWithinCount,
                     const double sameWithinTotalSizeRaw,
                     const int oppositeWithinCount)
{
   if(g_cachedObFvgStatsCount >= MAX_FVG_OB_CACHE) return;

   datetime currentBarTime = timeArr[0];
   int cacheIndex = g_cachedObFvgStatsCount++;
   g_cachedObFvgStats[cacheIndex].obTime = obTime;
   g_cachedObFvgStats[cacheIndex].obBias = obBias;
   g_cachedObFvgStats[cacheIndex].chartBarTime = currentBarTime;
   g_cachedObFvgStats[cacheIndex].valid = true;
   g_cachedObFvgStats[cacheIndex].sameCount = sameCount;
   g_cachedObFvgStats[cacheIndex].oppositeCount = oppositeCount;
   g_cachedObFvgStats[cacheIndex].sameActiveAtTouch = sameActiveAtTouch;
   g_cachedObFvgStats[cacheIndex].oppositeActiveAtTouch = oppositeActiveAtTouch;
   g_cachedObFvgStats[cacheIndex].firstSameBars = firstSameBars;
   g_cachedObFvgStats[cacheIndex].firstSameSizeRaw = firstSameSizeRaw;
   g_cachedObFvgStats[cacheIndex].sameWithinCount = sameWithinCount;
   g_cachedObFvgStats[cacheIndex].sameWithinTotalSizeRaw = sameWithinTotalSizeRaw;
   g_cachedObFvgStats[cacheIndex].oppositeWithinCount = oppositeWithinCount;
}

void EnsureMLBarContextCache(const double atrVal)
{
   datetime currentBarTime = GetCurrentFeatureBarTime();
   if(g_mlBarContextCache.valid && g_mlBarContextCache.chartBarTime == currentBarTime)
      return;

   int N = MathMax(2, LookbackN);
   double highest = rawHighs[0], lowest = rawLows[0];
   for(int i = 1; i < N && i < MAX_BARS; i++)
   {
      if(rawHighs[i] > highest) highest = rawHighs[i];
      if(rawLows[i]  < lowest)  lowest  = rawLows[i];
   }

   double lastBOS = 0.0;
   for(int i = eventCount - 1; i >= 0; i--)
   {
      if(events[i].breakTime <= TimeCurrent())
      {
         lastBOS = events[i].level;
         break;
      }
   }

   double rangeTop = 0.0, rangeBottom = 0.0, eqTop = 0.0, eqBottom = 0.0, eqPrice = 0.0;
   bool hasLuxPD = GetLuxPremiumDiscountRange(rangeTop, rangeBottom, eqTop, eqBottom, eqPrice);

   double atr20Val = GetCurrentATR20();
   if(atr20Val <= 0.0) atr20Val = atrVal;

   double velocity = 0.0;
   int velocityShift = MathMax(1, VelocityN);
   if(velocityShift < MAX_BARS && atrVal > 0.0)
      velocity = (rawCloses[0] - rawCloses[velocityShift]) / ((double)velocityShift * atrVal);

   g_mlBarContextCache.chartBarTime = currentBarTime;
   g_mlBarContextCache.valid = true;
   g_mlBarContextCache.atr20Val = atr20Val;
   g_mlBarContextCache.highest = highest;
   g_mlBarContextCache.lowest = lowest;
   g_mlBarContextCache.rangeN = highest - lowest;
   g_mlBarContextCache.lastBOS = lastBOS;
   g_mlBarContextCache.hasLuxPD = hasLuxPD;
   g_mlBarContextCache.rangeTop = rangeTop;
   g_mlBarContextCache.rangeBottom = rangeBottom;
   g_mlBarContextCache.eqTop = eqTop;
   g_mlBarContextCache.eqBottom = eqBottom;
   g_mlBarContextCache.eqPrice = eqPrice;
   g_mlBarContextCache.velocity = velocity;
}

int ClassifyLuxPDZoneCached(const double price)
{
   if(!g_mlBarContextCache.valid || !g_mlBarContextCache.hasLuxPD)
      return 0;
   if(price > g_mlBarContextCache.eqTop) return 1;
   if(price < g_mlBarContextCache.eqBottom) return -1;
   return 0;
}

double LuxRangePositionCached(const double price)
{
   if(!g_mlBarContextCache.valid || !g_mlBarContextCache.hasLuxPD)
      return 0.0;

   double width = g_mlBarContextCache.rangeTop - g_mlBarContextCache.rangeBottom;
   if(width <= 0.0) return 0.0;

   return MathMax(0.0, MathMin(1.0, (price - g_mlBarContextCache.rangeBottom) / width));
}

bool GetCachedMLOBContext(const OrderBlock &ob,
                          const bool isInternal,
                          const double atrVal,
                          int &obBarIndex,
                          int &barsSinceOB,
                          double &approachCleanliness,
                          double &liqSweepDepthATR,
                          double &liqSweepRejectionStrength,
                          int &liqSweepBarsToOB,
                          int &liqSweepBeforeOB,
                          double &creatorBOSLevel)
{
   datetime currentBarTime = GetCurrentFeatureBarTime();
   if(currentBarTime != g_mlObContextCacheBarTime)
   {
      g_mlObContextCacheBarTime = currentBarTime;
      g_mlObContextCacheCount = 0;
   }

   for(int i = 0; i < g_mlObContextCacheCount; i++)
   {
      if(!g_mlObContextCache[i].valid) continue;
      if(g_mlObContextCache[i].chartBarTime != currentBarTime) continue;
      if(g_mlObContextCache[i].obTime != ob.time) continue;
      if(g_mlObContextCache[i].obBias != ob.bias) continue;
      if(g_mlObContextCache[i].isInternal != isInternal) continue;

      obBarIndex = g_mlObContextCache[i].obBarIndex;
      barsSinceOB = g_mlObContextCache[i].barsSinceOB;
      approachCleanliness = g_mlObContextCache[i].approachCleanliness;
      liqSweepDepthATR = g_mlObContextCache[i].liqSweepDepthATR;
      liqSweepRejectionStrength = g_mlObContextCache[i].liqSweepRejectionStrength;
      liqSweepBarsToOB = g_mlObContextCache[i].liqSweepBarsToOB;
      liqSweepBeforeOB = g_mlObContextCache[i].liqSweepBeforeOB;
      creatorBOSLevel = g_mlObContextCache[i].creatorBOSLevel;
      return true;
   }

   obBarIndex = GetOBBarIndex(ob.time);
   barsSinceOB = (obBarIndex >= 0) ? MathMax(0, obBarIndex) : BarsSinceOBCreated(ob.time);
   approachCleanliness = ComputeApproachCleanliness(obBarIndex);
   liqSweepDepthATR = 0.0;
   liqSweepRejectionStrength = 0.0;
   liqSweepBarsToOB = -1;
   liqSweepBeforeOB = 0;
   ComputeLiquiditySweepBeforeOB(ob, obBarIndex, atrVal,
                                 liqSweepDepthATR, liqSweepRejectionStrength,
                                 liqSweepBarsToOB, liqSweepBeforeOB);
   creatorBOSLevel = FindCreatorBOSLevel(ob.time, ob.bias, isInternal);

   if(g_mlObContextCacheCount < MAX_ML_OB_CONTEXT_CACHE)
   {
      int cacheIndex = g_mlObContextCacheCount++;
      g_mlObContextCache[cacheIndex].chartBarTime = currentBarTime;
      g_mlObContextCache[cacheIndex].obTime = ob.time;
      g_mlObContextCache[cacheIndex].obBias = ob.bias;
      g_mlObContextCache[cacheIndex].isInternal = isInternal;
      g_mlObContextCache[cacheIndex].valid = true;
      g_mlObContextCache[cacheIndex].obBarIndex = obBarIndex;
      g_mlObContextCache[cacheIndex].barsSinceOB = barsSinceOB;
      g_mlObContextCache[cacheIndex].approachCleanliness = approachCleanliness;
      g_mlObContextCache[cacheIndex].liqSweepDepthATR = liqSweepDepthATR;
      g_mlObContextCache[cacheIndex].liqSweepRejectionStrength = liqSweepRejectionStrength;
      g_mlObContextCache[cacheIndex].liqSweepBarsToOB = liqSweepBarsToOB;
      g_mlObContextCache[cacheIndex].liqSweepBeforeOB = liqSweepBeforeOB;
      g_mlObContextCache[cacheIndex].creatorBOSLevel = creatorBOSLevel;
   }

   return false;
}

bool GetLuxPremiumDiscountRange(double &rangeTop, double &rangeBottom, double &eqTop, double &eqBottom, double &eqPrice)

{

   if(trailing.top <= 0.0 || trailing.bottom <= 0.0 || trailing.top <= trailing.bottom || trailing.barTime == 0)

      return false;

   rangeTop    = trailing.top;

   rangeBottom = trailing.bottom;

   eqTop       = 0.525 * rangeTop + 0.475 * rangeBottom;

   eqBottom    = 0.525 * rangeBottom + 0.475 * rangeTop;

   eqPrice     = (rangeTop + rangeBottom) / 2.0;

   return true;

}

bool ComputeMLFeatures(const OrderBlock &ob, bool isInternal,
                       double entryPrice, double atrVal,
                       double &features[])
{
   return ComputeMLFeaturesCached(ob, isInternal, entryPrice, atrVal, features);
}

int ClassifyLuxPDZone(const double price)

{

   double rangeTop, rangeBottom, eqTop, eqBottom, eqPrice;

   if(!GetLuxPremiumDiscountRange(rangeTop, rangeBottom, eqTop, eqBottom, eqPrice))

      return 0;

   if(price > eqTop) return 1;

   if(price < eqBottom) return -1;

   return 0;

}

double LuxRangePosition(const double price)

{

   double rangeTop, rangeBottom, eqTop, eqBottom, eqPrice;

   if(!GetLuxPremiumDiscountRange(rangeTop, rangeBottom, eqTop, eqBottom, eqPrice))

      return 0.0;

   double width = rangeTop - rangeBottom;

   if(width <= 0.0) return 0.0;

   return MathMax(0.0, MathMin(1.0, (price - rangeBottom) / width));

}

int GetOBBarIndex(const datetime obTime)
{
   int idx = iBarShift(_Symbol, _Period, obTime, false);
   if(idx < 0 || idx >= MAX_BARS) return -1;
   return idx;
}

double ComputeEntryAggressiveness(const double entryPrice, const int obBias, const double atrVal)
{
   if(atrVal <= 0 || MAX_BARS < 2) return 0.0;
   double lastCloseBeforeTouch = rawCloses[1];
   double directionNormalized = (double)(-obBias);
   return ((entryPrice - lastCloseBeforeTouch) * directionNormalized) / atrVal;
}

double ComputeApproachCleanliness(const int obBarIndex)
{
   if(obBarIndex < 1 || obBarIndex >= MAX_BARS) return 0.0;

   double closeAtOBCreation = rawCloses[obBarIndex];
   double lastCloseBeforeTouch = rawCloses[1];
   double netMove = MathAbs(lastCloseBeforeTouch - closeAtOBCreation);

   double pathMove = 0.0;
   for(int i = 1; i < obBarIndex; i++)
      pathMove += MathAbs(rawCloses[i] - rawCloses[i + 1]);

   if(pathMove <= 0.0) return 0.0;
   return MathMax(0.0, MathMin(1.0, netMove / pathMove));
}

bool FindLatestConfirmedSwingPivotBeforeOB(const int obBarIndex, const int obBias, double &pivotLevel, int &pivotBarIndex)
{
   pivotLevel = 0.0;
   pivotBarIndex = -1;
   if(obBarIndex < 0 || obBarIndex >= MAX_BARS) return false;

   int barsCount = MathMin(Bars(_Symbol, _Period), MAX_BARS);
   if(barsCount < SwingLength + 3) return false;

   int localSwingLastLeg = -1;
   double lastSwingLowLevel = 0.0, lastSwingHighLevel = 0.0;
   int lastSwingLowIndex = -1, lastSwingHighIndex = -1;

   for(int index = barsCount - SwingLength - 2; index >= obBarIndex; index--)
   {
      int leg = LegAt(rawHighs, rawLows, barsCount, index, SwingLength);
      if(leg == -1) continue;

      int candidatePivotIndex = index + SwingLength;
      if(candidatePivotIndex < 0 || candidatePivotIndex >= barsCount) continue;

      if(leg != localSwingLastLeg)
      {
         if(leg == BULLISH_LEG)
         {
            lastSwingLowLevel = rawLows[candidatePivotIndex];
            lastSwingLowIndex = candidatePivotIndex;
         }
         else
         {
            lastSwingHighLevel = rawHighs[candidatePivotIndex];
            lastSwingHighIndex = candidatePivotIndex;
         }
      }

      localSwingLastLeg = leg;
   }

   if(obBias == BULLISH && lastSwingLowIndex >= 0)
   {
      pivotLevel = lastSwingLowLevel;
      pivotBarIndex = lastSwingLowIndex;
      return true;
   }

   if(obBias == BEARISH && lastSwingHighIndex >= 0)
   {
      pivotLevel = lastSwingHighLevel;
      pivotBarIndex = lastSwingHighIndex;
      return true;
   }

   return false;
}

void ComputeLiquiditySweepBeforeOB(const OrderBlock &ob, const int obBarIndex, const double atrVal,
                                   double &sweepDepthATR,
                                   double &rejectionStrengthATR,
                                   int &barsToOB,
                                   int &sweepBeforeOB)
{
   sweepDepthATR = 0.0;
   rejectionStrengthATR = 0.0;
   barsToOB = -1;
   sweepBeforeOB = 0;

   if(atrVal <= 0 || obBarIndex < 0 || obBarIndex >= MAX_BARS - 1) return;

   double pivotLevel = 0.0;
   int pivotBarIndex = -1;
   if(!FindLatestConfirmedSwingPivotBeforeOB(obBarIndex, ob.bias, pivotLevel, pivotBarIndex)) return;

   int lastIndex = MathMin(MAX_BARS - 1, obBarIndex + LIQ_SWEEP_MAX_BARS_TO_OB);
   for(int i = obBarIndex + 1; i <= lastIndex; i++)
   {
      if(ob.bias == BULLISH)
      {
         bool swept = (rawLows[i] < pivotLevel && rawCloses[i] > pivotLevel);
         if(!swept) continue;

         sweepDepthATR = MathMax(0.0, (pivotLevel - rawLows[i]) / atrVal);
         rejectionStrengthATR = MathMax(0.0, (rawCloses[i] - rawLows[i]) / atrVal);
         barsToOB = i - obBarIndex;
         sweepBeforeOB = (rejectionStrengthATR >= LIQ_SWEEP_MIN_REJECTION_ATR) ? 1 : 0;
         return;
      }
      else if(ob.bias == BEARISH)
      {
         bool swept = (rawHighs[i] > pivotLevel && rawCloses[i] < pivotLevel);
         if(!swept) continue;

         sweepDepthATR = MathMax(0.0, (rawHighs[i] - pivotLevel) / atrVal);
         rejectionStrengthATR = MathMax(0.0, (rawHighs[i] - rawCloses[i]) / atrVal);
         barsToOB = i - obBarIndex;
         sweepBeforeOB = (rejectionStrengthATR >= LIQ_SWEEP_MIN_REJECTION_ATR) ? 1 : 0;
         return;
      }
   }
}

double FindCreatorBOSLevel(const datetime obTime, const int obBias, const bool isInternal)
{
   for(int i = 0; i < eventCount; i++)
   {
      if(events[i].breakTime <= obTime) continue;
      if(events[i].internal != isInternal) continue;
      if(events[i].bullish != (obBias == BULLISH)) continue;
      return events[i].level;
   }
   return 0.0;
}

bool ComputeMLFeaturesCached(const OrderBlock &ob, bool isInternal,

                       double entryPrice, double atrVal,

                       double &features[])

{

   if(ArraySize(features) != ML_N_FEATURES)
      ArrayResize(features, ML_N_FEATURES);

   if(ML_N_FEATURES < 43) { Print("SMC2 ERROR: ML_N_FEATURES must be >= 43 for this version."); return false; }

   double obHigh = ob.high, obLow = ob.low, obSize = obHigh - obLow;

   if(obSize <= 0 || atrVal <= 0) return false;

   EnsureMLBarContextCache(atrVal);

   // feature[22] atr20_atr200_ratio: chamada direta igual ao treino (não usa cache de barra)
   double atr20Val = GetCurrentATR20();
   if(atr20Val <= 0.0) atr20Val = atrVal;
   int N = MathMax(2, LookbackN);
   double rangeN = g_mlBarContextCache.rangeN;
   double lastBOS = g_mlBarContextCache.lastBOS;

   double obMid = (obHigh + obLow) / 2.0;
   bool hasLuxPD = g_mlBarContextCache.hasLuxPD;
   int pdEntryZone = ClassifyLuxPDZoneCached(entryPrice);
   double pdEntryDistanceFromEq = hasLuxPD ? MathAbs(entryPrice - g_mlBarContextCache.eqPrice) / atrVal : 0.0;
   double pdObMidDistanceFromEq = hasLuxPD ? MathAbs(obMid - g_mlBarContextCache.eqPrice) / atrVal : 0.0;

   int pdIsFavorableForBias = ((ob.bias == BULLISH && pdEntryZone == -1) ||

                               (ob.bias == BEARISH && pdEntryZone == 1)) ? 1 : 0;
   int obBarIndex = -1;
   int bso = 0;
   double approachCleanliness = 0.0;
   double touchLatencyPerOBSize = 0.0;
   double liqSweepDepthATR = 0.0, liqSweepRejectionStrength = 0.0;
   int liqSweepBarsToOB = -1, liqSweepBeforeOB = 0;
   double creatorBOSLevel = 0.0;
   GetCachedMLOBContext(ob, isInternal, atrVal,
                        obBarIndex, bso, approachCleanliness,
                        liqSweepDepthATR, liqSweepRejectionStrength,
                        liqSweepBarsToOB, liqSweepBeforeOB,
                        creatorBOSLevel);
   touchLatencyPerOBSize = ((obSize / atrVal) > 0.0) ? (double)MathMax(0, bso) / (obSize / atrVal) : 0.0;
   int fvgSameCount = 0, fvgOppositeCount = 0, fvgSameActive = 0, fvgOppositeActive = 0;
   int firstSameFvgBars = LUX_FVG_NOT_FOUND_BARS, sameWithin5BarsCount = 0, oppositeWithin5BarsCount = 0;
   double firstSameFvgSizeRaw = 0.0, sameWithin5BarsTotalSizeRaw = 0.0;
   if(!GetCachedOBFVGStats(ob.time, ob.bias,
                           fvgSameCount, fvgOppositeCount, fvgSameActive, fvgOppositeActive,
                           firstSameFvgBars, firstSameFvgSizeRaw,
                           sameWithin5BarsCount, sameWithin5BarsTotalSizeRaw, oppositeWithin5BarsCount))
   {
      LuxFVG_GetCombinedStats(ob.time, TimeCurrent(), ob.bias, 5,
                              fvgSameCount, fvgOppositeCount, fvgSameActive, fvgOppositeActive,
                              firstSameFvgBars, firstSameFvgSizeRaw,
                              sameWithin5BarsCount, sameWithin5BarsTotalSizeRaw, oppositeWithin5BarsCount);
      CacheOBFVGStats(ob.time, ob.bias,
                      fvgSameCount, fvgOppositeCount, fvgSameActive, fvgOppositeActive,
                      firstSameFvgBars, firstSameFvgSizeRaw,
                      sameWithin5BarsCount, sameWithin5BarsTotalSizeRaw, oppositeWithin5BarsCount);
   }

   int k = 0;

   features[k++] = obSize / atrVal;

   features[k++] = (double)MathMax(0, bso);

   features[k++] = atrVal;

   features[k++] = (rangeN > 0) ? rangeN / atrVal : 0.0;

   features[k++] = (swingHigh.currentLevel > 0) ? MathAbs(entryPrice - swingHigh.currentLevel) / atrVal : 0.0;

   features[k++] = (swingLow.currentLevel  > 0) ? MathAbs(entryPrice - swingLow.currentLevel)  / atrVal : 0.0;

   features[k++] = (lastBOS > 0) ? MathAbs(entryPrice - lastBOS) / atrVal : 0.0;

    features[k++] = (double)ob.bias;

   features[k++] = (double)pdEntryZone;

   features[k++] = LuxRangePositionCached(obMid);

     features[k++] = g_mlBarContextCache.velocity;

   features[k++] = pdEntryDistanceFromEq;

   features[k++] = pdObMidDistanceFromEq;

    double bosL = creatorBOSLevel;

   features[k++] = (bosL>0)?MathAbs(bosL-(ob.bias==BULLISH?ob.low:ob.high))/atrVal:0.0;

   features[k++] = (double)swingTrend;

   features[k++] = (double)internalTrend;

   int nOBs=0; double crd=CrowdingATR*atrVal;

   for(int i=0; i<MathMin(internalOBSize,InternalOBCount); i++) if(MathAbs((internalOB[i].high+internalOB[i].low)/2.0-entryPrice)<crd) nOBs++;

   for(int i=0; i<MathMin(swingOBSize,SwingOBCount); i++) if(MathAbs((swingOB[i].high+swingOB[i].low)/2.0-entryPrice)<crd) nOBs++;

   features[k++] = (double)nOBs;

   features[k++] = (swingTrend!=0 && swingTrend==internalTrend)?1.0:0.0;

   features[k++] = ob.ob_volume_ratio;

   features[k++] = ob.impulse_volume_ratio;

   features[k++] = ob.volume_per_range_ob;

   features[k++] = ob.volume_per_range_impulse;

   features[k++] = (atrVal > 0) ? atr20Val / atrVal : 0.0;

   features[k++] = (double)pdIsFavorableForBias;

   features[k++] = approachCleanliness;

   features[k++] = liqSweepDepthATR;

   features[k++] = liqSweepRejectionStrength;

   features[k++] = (double)liqSweepBarsToOB;

   features[k++] = (double)liqSweepBeforeOB;

   features[k++] = (double)fvgSameCount;

   features[k++] = (double)fvgOppositeCount;

   features[k++] = (double)fvgSameActive;

   features[k++] = (double)fvgOppositeActive;

   features[k++] = (double)firstSameFvgBars;

   features[k++] = (atrVal > 0) ? firstSameFvgSizeRaw / atrVal : 0.0;

   features[k++] = (obSize > 0) ? firstSameFvgSizeRaw / obSize : 0.0;

   features[k++] = (double)sameWithin5BarsCount;

   features[k++] = (atrVal > 0) ? sameWithin5BarsTotalSizeRaw / atrVal : 0.0;

   features[k++] = (double)oppositeWithin5BarsCount;

   // --- Novas features v810b
   double atr5Now = GetCurrentATR5();
   double atr20Now2 = GetCurrentATR20();
   if(atr5Now <= 0) atr5Now = atrVal;
   if(atr20Now2 <= 0) atr20Now2 = atrVal;
   features[k++] = (atr20Now2 > 0) ? atr5Now / atr20Now2 : 1.0;

   MqlDateTime dtCached; TimeToStruct(TimeCurrent(), dtCached);
   features[k++] = (double)dtCached.day_of_week;

   double prevDayHighVal = 0.0, prevDayLowVal = 0.0;
   double d1Hi[2], d1Lo[2];
   if(CopyHigh(_Symbol, PERIOD_D1, 0, 2, d1Hi) == 2) prevDayHighVal = d1Hi[1];
   if(CopyLow(_Symbol, PERIOD_D1, 0, 2, d1Lo) == 2)  prevDayLowVal  = d1Lo[1];
   features[k++] = (atrVal > 0 && prevDayHighVal > 0) ? (prevDayHighVal - entryPrice) / atrVal : 0.0;
   features[k++] = (atrVal > 0 && prevDayLowVal  > 0) ? (entryPrice - prevDayLowVal)  / atrVal : 0.0;

   if(k != ML_N_FEATURES)
   {
      PrintFormat("SMC2 ERROR: vetor de features terminou com %d itens, esperado %d.", k, ML_N_FEATURES);
      return false;
   }

   return true;

}

//--- AFT: copia ML_N_FEATURES(43) → ML_AFT_N_FEATURES(43) diretamente (sem skip de feature)
//    Comentário antigo estava desatualizado: stop_distance_atr (indice 28) foi removido do dataset.
//    Hoje ML_N_FEATURES == ML_AFT_N_FEATURES == SMCAFT_N_FEATURES == 43. Cópia direta está correta.
bool BuildAFTFeaturesFrom(const double &full_features[], double &aft_features[])
{
   if(ArraySize(full_features) < ML_N_FEATURES) return false;
   if(ArraySize(aft_features) != ML_AFT_N_FEATURES)
      ArrayResize(aft_features, ML_AFT_N_FEATURES);
   for(int i = 0; i < ML_N_FEATURES; i++)
   {
      aft_features[i] = full_features[i];
   }
   return true;
}

double GetCurrentATR()

{

   // volatilityArr[0] ja foi populado por RunCalculation com o mesmo handle ATR

   // Funciona tanto em live quanto no strategy tester

   if(volatilityArr[0] > 0) return volatilityArr[0];

   // Fallback: tenta CopyBuffer diretamente

   double buf[1];

   if(CopyBuffer(atrHandle, 0, 0, 1, buf) > 0 && buf[0] > 0) return buf[0];

   return 0;

}

double GetCurrentATR20()

{

   double buf[1];

   if(CopyBuffer(atr20Handle, 0, 0, 1, buf) > 0 && buf[0] > 0) return buf[0];

   return 0;

}

double GetCurrentATR5()

{

   double buf[1];

   if(CopyBuffer(atr5Handle, 0, 0, 1, buf) > 0 && buf[0] > 0) return buf[0];

   return 0;

}

int BarsSinceOBCreated(datetime t) { int b=(int)Bars(_Symbol,_Period,t,TimeCurrent())-1; return MathMax(0,b); }

bool IsContainedByLargerCandidate(const OrderBlock &target, const OrderBlock &candidate)

{

   if(target.bias != candidate.bias) return false;

   bool sameOB = (target.time == candidate.time &&

                  target.high == candidate.high &&

                  target.low  == candidate.low);

   if(sameOB) return false;

   bool contained = (target.high <= candidate.high && target.low >= candidate.low);

   if(!contained) return false;

   double targetSize    = target.high - target.low;

   double candidateSize = candidate.high - candidate.low;

   return (candidateSize > targetSize ||

           candidate.high > target.high ||

           candidate.low  < target.low);

}

bool IsOBContainedByLargerOB(const OrderBlock &ob)

{

   for(int i = 0; i < internalOBSize; i++)

      if(IsContainedByLargerCandidate(ob, internalOB[i]))

         return true;

   for(int i = 0; i < swingOBSize; i++)

      if(IsContainedByLargerCandidate(ob, swingOB[i]))

         return true;

   return false;

}

bool IsOBAlreadySampled(datetime obTime, int obBias, int obType)

{

   for(int i = 0; i < sampledOBCount; i++)

      if(sampledOBTimes[i] == obTime && sampledOBBias[i] == obBias && sampledOBType[i] == obType)

         return true;

   return false;

}

void MarkOBAsSampled(datetime obTime, int obBias, int obType)

{

   if(sampledOBCount >= MAX_SAMPLED)

   {

      // Janela deslizante: descarta o mais antigo para abrir espaço

      for(int i = 0; i < MAX_SAMPLED-1; i++)

      {

         sampledOBTimes[i] = sampledOBTimes[i+1];

         sampledOBBias[i]  = sampledOBBias[i+1];

         sampledOBType[i]  = sampledOBType[i+1];

      }

      sampledOBCount = MAX_SAMPLED-1;

   }

   sampledOBTimes[sampledOBCount] = obTime;

   sampledOBBias[sampledOBCount]  = obBias;

   sampledOBType[sampledOBCount]  = obType;

   sampledOBCount++;

}

void FlushCSVBuffer()

{

   if(csvBuffer == "") return;

   // Cria a pasta se CsvPath tiver subdiretorio (ex: "SMC2\\dataset.csv")

   int sep = StringFind(CsvPath, "\\", 0);

   if(sep > 0)

   {

      string folder = StringSubstr(CsvPath, 0, sep);

      FolderCreate(folder, FILE_COMMON);

   }

   int file = FileOpen(CsvPath, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_SHARE_WRITE|FILE_COMMON);

   if(file == INVALID_HANDLE)

   {

      // Fallback sem FILE_COMMON se nao tiver permissao

      file = FileOpen(CsvPath, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_SHARE_WRITE);

      if(file == INVALID_HANDLE) return;

   }

   FileSeek(file, 0, SEEK_END);

   if(FileTell(file) == 0)

   {

      // As primeiras colunas seguem exatamente a ordem de ComputeMLFeatures().

      string h = "ob_size_atr,bars_since_ob,atr,range_atr_ratio,";

      h += "dist_to_swing_high,dist_to_swing_low,dist_to_last_BOS,ob_bias,";

      h += "pd_entry_zone,range_pos,velocity,pd_entry_distance_from_eq,pd_ob_mid_distance_from_eq,";

      h += "impulse_strength,swing_trend,internal_trend,num_obs_within_atr,alignment,";

      h += "ob_volume_ratio,impulse_volume_ratio,volume_per_range_ob,volume_per_range_impulse,";

      h += "atr20_atr200_ratio,pd_is_favorable_for_bias,";

      h += "approach_cleanliness,";

      h += "liquidity_sweep_depth_atr,liquidity_sweep_rejection_strength,";

      h += "liquidity_sweep_bars_to_ob,liquidity_sweep_before_ob,";

      h += "fvg_after_ob_same_bias_count,fvg_after_ob_opposite_bias_count,";

      h += "fvg_after_ob_same_bias_active_at_touch,fvg_after_ob_opposite_bias_active_at_touch,";

      h += "first_same_bias_fvg_after_ob_bars,first_same_bias_fvg_after_ob_size_atr,";

      h += "first_same_bias_fvg_after_ob_size_vs_ob,same_bias_fvg_within_5bars_count,";

      h += "same_bias_fvg_within_5bars_total_size_atr,opposite_bias_fvg_within_5bars_count,";

      h += "atr5_atr20_ratio,day_of_week,dist_to_prev_day_high,dist_to_prev_day_low,";

      h += "id,ob_id,ob_type,ob_bias,entry_time,entry_price,sl,risk,";

      h += "meta_havia_posicao_aberta,meta_passa_tamanho_minimo,meta_ob_contido_em_outro_maior,";

      h += "mfe,mae,hit_1R,hit_2R,hit_3R,";

      h += "bars_to_1R,bars_to_2R,bars_to_3R,bars_alive,end_reason,censored\n";

      FileWriteString(file, h);

   }

   FileWriteString(file, csvBuffer);

   FileClose(file);

   Print("SMC2 CSV flush: ", csvBufferCount, " samples gravados em ", CsvPath);

   csvBuffer      = "";

   csvBufferCount = 0;

}

void WriteSampleToCSV(TradeSample &s)

{

   // Mantem o CSV com as features primeiro, na mesma ordem usada na inferencia do EA.

   string row = DoubleToString(s.ob_size_atr,              4)       + ",";

   row += IntegerToString(s.bars_since_ob)                    + ",";

   row += DoubleToString(s.atr,                      2)       + ",";

   row += DoubleToString(s.range_atr_ratio,          4)       + ",";

   row += DoubleToString(s.dist_to_swing_high,       4)       + ",";

   row += DoubleToString(s.dist_to_swing_low,        4)       + ",";

   row += DoubleToString(s.dist_to_last_BOS,         4)       + ",";

   row += IntegerToString(s.ob_bias)                          + ",";

   row += IntegerToString(s.pd_entry_zone)                    + ",";

   row += DoubleToString(s.range_pos,                4)       + ",";

   row += DoubleToString(s.velocity,                 4)       + ",";

   row += DoubleToString(s.pd_entry_distance_from_eq, 4)      + ",";

   row += DoubleToString(s.pd_ob_mid_distance_from_eq, 4)     + ",";

   row += DoubleToString(s.impulse_strength,         4)       + ",";

   row += IntegerToString(s.swing_trend_val)                  + ",";

   row += IntegerToString(s.internal_trend_val)               + ",";

   row += IntegerToString(s.num_obs_within_atr)               + ",";

   row += IntegerToString(s.alignment)                        + ",";

   row += DoubleToString(s.ob_volume_ratio,          4)       + ",";

   row += DoubleToString(s.impulse_volume_ratio,     4)       + ",";

   row += DoubleToString(s.volume_per_range_ob,      4)       + ",";

   row += DoubleToString(s.volume_per_range_impulse, 4)       + ",";

   row += DoubleToString(s.meta_atr20_atr200_ratio,  4)       + ",";

   row += IntegerToString(s.pd_is_favorable_for_bias)         + ",";

   row += DoubleToString(s.approach_cleanliness,     4)       + ",";

   row += DoubleToString(s.liquidity_sweep_depth_atr, 4)      + ",";

   row += DoubleToString(s.liquidity_sweep_rejection_strength, 4) + ",";

   row += IntegerToString(s.liquidity_sweep_bars_to_ob)       + ",";

   row += IntegerToString(s.liquidity_sweep_before_ob)        + ",";

   row += IntegerToString(s.fvg_after_ob_same_bias_count)               + ",";

   row += IntegerToString(s.fvg_after_ob_opposite_bias_count)           + ",";

   row += IntegerToString(s.fvg_after_ob_same_bias_active_at_touch)     + ",";

   row += IntegerToString(s.fvg_after_ob_opposite_bias_active_at_touch) + ",";

   row += IntegerToString(s.first_same_bias_fvg_after_ob_bars)          + ",";

   row += DoubleToString(s.first_same_bias_fvg_after_ob_size_atr, 4)    + ",";

   row += DoubleToString(s.first_same_bias_fvg_after_ob_size_vs_ob, 4)  + ",";

   row += IntegerToString(s.same_bias_fvg_within_5bars_count)           + ",";

   row += DoubleToString(s.same_bias_fvg_within_5bars_total_size_atr, 4)+ ",";

   row += IntegerToString(s.opposite_bias_fvg_within_5bars_count)       + ",";

   row += DoubleToString(s.atr5_atr20_ratio,            4)       + ",";

   row += IntegerToString(s.day_of_week)                          + ",";

   row += DoubleToString(s.dist_to_prev_day_high,        4)       + ",";

   row += DoubleToString(s.dist_to_prev_day_low,         4)       + ",";

   row += IntegerToString(s.id)                         + ",";

   row += s.ob_id                                             + ",";

   row += IntegerToString(s.ob_type)                          + ",";

   row += IntegerToString(s.ob_bias)                          + ",";

   row += TimeToString(s.entry_time, TIME_DATE|TIME_MINUTES)  + ",";

   row += DoubleToString(s.entry_price,              2)       + ",";

   row += DoubleToString(s.sl,                       2)       + ",";

   row += DoubleToString(s.risk,                     2)       + ",";

   row += IntegerToString(s.meta_havia_posicao_aberta)        + ",";

   row += IntegerToString(s.meta_passa_tamanho_minimo)        + ",";

   row += IntegerToString(s.meta_ob_contido_em_outro_maior)   + ",";

   row += DoubleToString(s.mfe,                      4)       + ",";

   row += DoubleToString(s.mae,                      4)       + ",";

   row += IntegerToString(s.hit_1R ? 1 : 0)                   + ",";

   row += IntegerToString(s.hit_2R ? 1 : 0)                   + ",";

   row += IntegerToString(s.hit_3R ? 1 : 0)                   + ",";

   row += IntegerToString(s.bars_to_1R)                       + ",";

   row += IntegerToString(s.bars_to_2R)                       + ",";

   row += IntegerToString(s.bars_to_3R)                       + ",";

   row += IntegerToString(s.bars_alive)                       + ",";

   row += IntegerToString(s.end_reason)                       + ",";

   row += IntegerToString(s.censored ? 1 : 0);

   csvBuffer += row + "\n";

   csvBufferCount++;

   if(csvBufferCount >= CSV_FLUSH_EVERY)

      FlushCSVBuffer();

}

void RemoveSample(int index)

{

   // O(1): troca pelo ultimo e decrementa

   samples[index] = samples[sampleCount-1];

   sampleCount--;

}

void CreateSample(const OrderBlock &ob, bool isInternal, double entryPrice, double atrVal)

{

   if(sampleCount >= MAX_SAMPLES) return;

   double obHigh = ob.high, obLow = ob.low, obSize = obHigh - obLow;

   if(obSize <= 0 || atrVal <= 0) return;

   double stopOffset = StopOffsetPoints * _Point;

   double sl   = (ob.bias == BULLISH) ? (obLow  - stopOffset)

                                      : (obHigh + stopOffset);

   double risk = MathAbs(entryPrice - sl);

   if(risk <= 0) return;

   TradeSample s;

   s.id      = nextSampleId++;

   s.ob_id   = IntegerToString((long)ob.time)

               + (ob.bias == BULLISH ? "_BUL" : "_BEA")

               + (isInternal ? "_I" : "_S");

   s.ob_type = isInternal ? 0 : 1;

   s.ob_bias = ob.bias;

   // --- Entrada

   s.entry_time  = TimeCurrent();

   s.entry_price = entryPrice;

   s.sl          = sl;

   s.risk        = risk;

   // ==========================================================================
   // MODIFICACAO: Unificacao do caminho de calculo de features (2026-04-01)
   // --------------------------------------------------------------------------
   // PROBLEMA ORIGINAL:
   //   Esta funcao (CreateSample) calculava as 43 features manualmente, usando
   //   formulas inline. O motor de trade (TryTradeOrderBlocks) calculava as
   //   mesmas features usando ComputeMLFeaturesCached. Havia dois calculos
   //   separados do mesmo dado, e eles divergiam em pelo menos um ponto critico:
   //
   //   bars_since_ob:
   //     - CreateSample (antigo): BarsSinceOBCreated() que usa Bars()
   //     - Motor (inferencia):    GetCachedMLOBContext() que usa iBarShift()
   //     Essas duas funcoes podem retornar valores diferentes para o mesmo OB.
   //
   //   Isso significa que o modelo era TREINADO com um valor de bars_since_ob
   //   mas EXECUTADO (backtest/live) com outro valor. O modelo aprendia um
   //   padrao que nao era o mesmo que via em producao.
   //
   // SOLUCAO APLICADA:
   //   CreateSample agora chama ComputeMLFeaturesCached diretamente — a mesma
   //   funcao que o motor usa para decidir entrar ou nao numa operacao.
   //   Com isso, o CSV de treino e a inferencia usam exatamente o mesmo codigo.
   //
   // COMO REVERTER (caso precise voltar ao codigo original):
   //   1. Apague o bloco inteiro entre os comentarios "MODIFICACAO" e "FIM DA MODIFICACAO"
   //   2. Recoloque o bloco manual abaixo no lugar (era o codigo que estava aqui antes):
   //
   //   -- INICIO DO BLOCO ORIGINAL --
   //   // --- OB features
   //   s.ob_size_atr = obSize / atrVal;
   //   int bso = BarsSinceOBCreated(ob.time);
   //   s.bars_since_ob = bso;
   //   // --- Volatilidade e range de LookbackN barras
   //   int N = MathMax(2, LookbackN);
   //   double highest = rawHighs[0], lowest = rawLows[0];
   //   for(int i = 1; i < N && i < MAX_BARS; i++) {
   //      if(rawHighs[i] > highest) highest = rawHighs[i];
   //      if(rawLows[i]  < lowest)  lowest  = rawLows[i];
   //   }
   //   double rangeN = highest - lowest;
   //   s.atr             = atrVal;
   //   double atr20Now = GetCurrentATR20();
   //   if(atr20Now <= 0) atr20Now = atrVal;
   //   s.meta_atr20_atr200_ratio = (atrVal > 0) ? atr20Now / atrVal : 0.0;
   //   s.range_atr_ratio = (rangeN > 0) ? rangeN / atrVal : 0.0;
   //   int obBarIndex = GetOBBarIndex(ob.time);
   //   double swH = swingHigh.currentLevel;
   //   double swL = swingLow.currentLevel;
   //   s.dist_to_swing_high = (swH > 0) ? MathAbs(entryPrice - swH) / atrVal : 0.0;
   //   s.dist_to_swing_low  = (swL > 0) ? MathAbs(entryPrice - swL) / atrVal : 0.0;
   //   double lastBOS = 0;
   //   for(int i = eventCount-1; i >= 0; i--)
   //      if(events[i].breakTime <= s.entry_time) { lastBOS = events[i].level; break; }
   //   s.dist_to_last_BOS = (lastBOS > 0) ? MathAbs(entryPrice - lastBOS) / atrVal : 0.0;
   //   double obMid = (obHigh + obLow) / 2.0;
   //   double rangeTop, rangeBottom, eqTop, eqBottom, eqPrice;
   //   bool hasLuxPD = GetLuxPremiumDiscountRange(rangeTop, rangeBottom, eqTop, eqBottom, eqPrice);
   //   s.pd_entry_zone = ClassifyLuxPDZone(entryPrice);
   //   s.pd_entry_distance_from_eq = hasLuxPD ? MathAbs(entryPrice - eqPrice) / atrVal : 0.0;
   //   s.pd_ob_mid_distance_from_eq = hasLuxPD ? MathAbs(obMid - eqPrice) / atrVal : 0.0;
   //   s.pd_is_favorable_for_bias = ((ob.bias == BULLISH && s.pd_entry_zone == -1) ||
   //                                 (ob.bias == BEARISH && s.pd_entry_zone == 1)) ? 1 : 0;
   //   s.range_pos = LuxRangePosition(obMid);
   //   s.approach_cleanliness = ComputeApproachCleanliness(obBarIndex);
   //   ComputeLiquiditySweepBeforeOB(ob, obBarIndex, atrVal,
   //                                 s.liquidity_sweep_depth_atr,
   //                                 s.liquidity_sweep_rejection_strength,
   //                                 s.liquidity_sweep_bars_to_ob,
   //                                 s.liquidity_sweep_before_ob);
   //   double firstSameFvgSizeRaw = 0.0, sameWithin5BarsTotalSizeRaw = 0.0;
   //   LuxFVG_GetCombinedStats(ob.time, s.entry_time, ob.bias, 5,
   //                           s.fvg_after_ob_same_bias_count,
   //                           s.fvg_after_ob_opposite_bias_count,
   //                           s.fvg_after_ob_same_bias_active_at_touch,
   //                           s.fvg_after_ob_opposite_bias_active_at_touch,
   //                           s.first_same_bias_fvg_after_ob_bars, firstSameFvgSizeRaw,
   //                           s.same_bias_fvg_within_5bars_count, sameWithin5BarsTotalSizeRaw,
   //                           s.opposite_bias_fvg_within_5bars_count);
   //   s.first_same_bias_fvg_after_ob_size_atr = (atrVal > 0) ? firstSameFvgSizeRaw / atrVal : 0.0;
   //   s.first_same_bias_fvg_after_ob_size_vs_ob = (obSize > 0) ? firstSameFvgSizeRaw / obSize : 0.0;
   //   s.same_bias_fvg_within_5bars_total_size_atr = (atrVal > 0) ? sameWithin5BarsTotalSizeRaw / atrVal : 0.0;
   //   int vN = MathMax(1, VelocityN);
   //   s.velocity = (vN < MAX_BARS && atrVal > 0) ? (rawCloses[0] - rawCloses[vN]) / ((double)vN * atrVal) : 0.0;
   //   double bosLevel = FindCreatorBOSLevel(ob.time, ob.bias, isInternal);
   //   double obOrigin = (ob.bias == BULLISH) ? obLow : obHigh;
   //   s.impulse_strength = (bosLevel > 0) ? MathAbs(bosLevel - obOrigin) / atrVal : 0.0;
   //   s.swing_trend_val    = swingTrend;
   //   s.internal_trend_val = internalTrend;
   //   double crowdDist = CrowdingATR * atrVal;
   //   s.num_obs_within_atr = 0;
   //   int iLim = MathMin(internalOBSize, InternalOBCount);
   //   for(int i = 0; i < iLim; i++)
   //      if(MathAbs((internalOB[i].high+internalOB[i].low)/2.0 - entryPrice) < crowdDist)
   //         s.num_obs_within_atr++;
   //   int sLim = MathMin(swingOBSize, SwingOBCount);
   //   for(int i = 0; i < sLim; i++)
   //      if(MathAbs((swingOB[i].high+swingOB[i].low)/2.0 - entryPrice) < crowdDist)
   //         s.num_obs_within_atr++;
   //   s.alignment = (swingTrend != 0 && swingTrend == internalTrend) ? 1 : 0;
   //   s.ob_volume_ratio          = ob.ob_volume_ratio;
   //   s.impulse_volume_ratio     = ob.impulse_volume_ratio;
   //   s.volume_per_range_ob      = ob.volume_per_range_ob;
   //   s.volume_per_range_impulse = ob.volume_per_range_impulse;
   //   double atr5Val = GetCurrentATR5();
   //   if(atr5Val <= 0) atr5Val = atrVal;
   //   s.atr5_atr20_ratio = (atr20Now > 0) ? atr5Val / atr20Now : 1.0;
   //   MqlDateTime dtSample; TimeToStruct(s.entry_time, dtSample);
   //   s.day_of_week = dtSample.day_of_week;
   //   double d1HiArr[2], d1LoArr[2];
   //   double prevDH = 0.0, prevDL = 0.0;
   //   if(CopyHigh(_Symbol, PERIOD_D1, 0, 2, d1HiArr) == 2) prevDH = d1HiArr[1];
   //   if(CopyLow(_Symbol, PERIOD_D1, 0, 2, d1LoArr) == 2)  prevDL = d1LoArr[1];
   //   s.dist_to_prev_day_high = (atrVal > 0 && prevDH > 0) ? (prevDH - entryPrice) / atrVal : 0.0;
   //   s.dist_to_prev_day_low  = (atrVal > 0 && prevDL > 0) ? (entryPrice - prevDL)  / atrVal : 0.0;
   //   -- FIM DO BLOCO ORIGINAL --
   // ==========================================================================

   // Chama a mesma funcao que o motor de trade usa para calcular as features.
   // O resultado (43 valores) e desempacotado nos campos da struct TradeSample
   // na mesma ordem em que ComputeMLFeaturesCached os produz (k=0..42).
   double featArray[];

   if(!ComputeMLFeaturesCached(ob, isInternal, entryPrice, atrVal, featArray))

   {

      nextSampleId--;  // desfaz o incremento feito no inicio da funcao

      return;

   }

   // Desempacotamento: cada featArray[i] corresponde ao indice k=i dentro
   // de ComputeMLFeaturesCached. A ordem abaixo DEVE ser identica a ordem
   // dos features[k++] naquela funcao. Nao altere a ordem sem alterar la tambem.
   s.ob_size_atr                                = featArray[0];   // k=0  obSize/atrVal
   s.bars_since_ob                              = (int)featArray[1]; // k=1  iBarShift (era Bars() antes)
   s.atr                                        = featArray[2];   // k=2
   s.range_atr_ratio                            = featArray[3];   // k=3
   s.dist_to_swing_high                         = featArray[4];   // k=4
   s.dist_to_swing_low                          = featArray[5];   // k=5
   s.dist_to_last_BOS                           = featArray[6];   // k=6
   // k=7 e ob.bias — ja atribuido em s.ob_bias = ob.bias acima, nao duplicar
   s.pd_entry_zone                              = (int)featArray[8];  // k=8
   s.range_pos                                  = featArray[9];   // k=9
   s.velocity                                   = featArray[10];  // k=10
   s.pd_entry_distance_from_eq                  = featArray[11];  // k=11
   s.pd_ob_mid_distance_from_eq                 = featArray[12];  // k=12
   s.impulse_strength                           = featArray[13];  // k=13
   s.swing_trend_val                            = (int)featArray[14]; // k=14
   s.internal_trend_val                         = (int)featArray[15]; // k=15
   s.num_obs_within_atr                         = (int)featArray[16]; // k=16
   s.alignment                                  = (int)featArray[17]; // k=17
   s.ob_volume_ratio                            = featArray[18];  // k=18
   s.impulse_volume_ratio                       = featArray[19];  // k=19
   s.volume_per_range_ob                        = featArray[20];  // k=20
   s.volume_per_range_impulse                   = featArray[21];  // k=21
   s.meta_atr20_atr200_ratio                    = featArray[22];  // k=22
   s.pd_is_favorable_for_bias                   = (int)featArray[23]; // k=23
   s.approach_cleanliness                       = featArray[24];  // k=24
   s.liquidity_sweep_depth_atr                  = featArray[25];  // k=25
   s.liquidity_sweep_rejection_strength         = featArray[26];  // k=26
   s.liquidity_sweep_bars_to_ob                 = (int)featArray[27]; // k=27
   s.liquidity_sweep_before_ob                  = (int)featArray[28]; // k=28
   s.fvg_after_ob_same_bias_count               = (int)featArray[29]; // k=29
   s.fvg_after_ob_opposite_bias_count           = (int)featArray[30]; // k=30
   s.fvg_after_ob_same_bias_active_at_touch     = (int)featArray[31]; // k=31
   s.fvg_after_ob_opposite_bias_active_at_touch = (int)featArray[32]; // k=32
   s.first_same_bias_fvg_after_ob_bars          = (int)featArray[33]; // k=33
   s.first_same_bias_fvg_after_ob_size_atr      = featArray[34];  // k=34
   s.first_same_bias_fvg_after_ob_size_vs_ob    = featArray[35];  // k=35
   s.same_bias_fvg_within_5bars_count           = (int)featArray[36]; // k=36
   s.same_bias_fvg_within_5bars_total_size_atr  = featArray[37];  // k=37
   s.opposite_bias_fvg_within_5bars_count       = (int)featArray[38]; // k=38
   s.atr5_atr20_ratio                           = featArray[39];  // k=39
   s.day_of_week                                = (int)featArray[40]; // k=40
   s.dist_to_prev_day_high                      = featArray[41];  // k=41
   s.dist_to_prev_day_low                       = featArray[42];  // k=42

   // FIM DA MODIFICACAO ======================================================

   // --- Metadados do CSV: nao entram nas 23 features do modelo

   s.meta_havia_posicao_aberta      = HasOpenPosition() ? 1 : 0;

   s.meta_passa_tamanho_minimo      = (obSize >= (CSV_META_MIN_OB_POINTS * _Point)) ? 1 : 0;

   s.meta_ob_contido_em_outro_maior = IsOBContainedByLargerOB(ob) ? 1 : 0;

   // --- Tracking inicial

   s.mfe = 0.0; s.mae = 0.0;

   s.hit_1R = false; s.hit_2R = false; s.hit_3R = false;

   s.bars_alive = 0;

   s.bars_to_1R = -1; s.bars_to_2R = -1; s.bars_to_3R = -1;

   s.finished   = false;

   s.end_reason = -1;

   s.censored   = false;

   samples[sampleCount++] = s;

}

// Chamado a cada barra fechada com o high/low da barra que fechou

void UpdateSamples(double barHigh, double barLow)

{

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);

   int leh, lem; EnumToHM(CloseTime, leh, lem);

   int logEndMin = leh*60 + lem;

   for(int i = 0; i < sampleCount; i++)

   {

      if(samples[i].finished) continue;

      // MFE e MAE dependem da direcao do OB

      double fav_move, adv_move;

      if(samples[i].ob_bias == BULLISH)

      {

         fav_move = (barHigh - samples[i].entry_price) / samples[i].risk;

         adv_move = (samples[i].entry_price - barLow)  / samples[i].risk;

      }

      else

      {

         fav_move = (samples[i].entry_price - barLow)  / samples[i].risk;

         adv_move = (barHigh - samples[i].entry_price) / samples[i].risk;

      }

      if(fav_move > samples[i].mfe) samples[i].mfe = fav_move;

      if(adv_move > samples[i].mae) samples[i].mae = adv_move;

      samples[i].bars_alive++;

      if(!samples[i].hit_1R && samples[i].mfe >= 1.0) { samples[i].hit_1R = true; samples[i].bars_to_1R = samples[i].bars_alive; }

      if(!samples[i].hit_2R && samples[i].mfe >= 2.0) { samples[i].hit_2R = true; samples[i].bars_to_2R = samples[i].bars_alive; }

      if(!samples[i].hit_3R && samples[i].mfe >= 3.0) { samples[i].hit_3R = true; samples[i].bars_to_3R = samples[i].bars_alive; }

      if(samples[i].mae >= 1.0)

      {

         samples[i].finished   = true;

         samples[i].end_reason = 0;

      }

      else if(samples[i].mfe >= MaxRTracking)

      {

         samples[i].mfe        = MaxRTracking;

         samples[i].finished   = true;

         samples[i].end_reason = 1;

      }

      else

      {

         MqlDateTime now; TimeToStruct(TimeCurrent(), now);

         int curMin = now.hour*60 + now.min;

         if(curMin >= logEndMin)

         {

            samples[i].finished   = true;

            samples[i].end_reason = 2;

            samples[i].censored   = true;

         }

         else if(samples[i].bars_alive >= MaxBarsTracking)

         {

            samples[i].finished   = true;

            samples[i].end_reason = 3;

            samples[i].censored   = true;

         }

      }

      if(samples[i].finished)

      {

         WriteSampleToCSV(samples[i]);

         RemoveSample(i);

         i--;

      }

   }

}

// Detecta toque em OBs a cada tick e cria samples independentemente do trading

void CheckOBTouches(double ask, double bid)

{

   if(!EnableCSVLogging) return;

   double atrVal = GetCurrentATR();

   if(atrVal <= 0) return;

   // Internal OBs

   int iLimit = MathMin(internalOBSize, InternalOBCount);

   for(int i = 0; i < iLimit; i++)

   {

      if(IsOBAlreadySampled(internalOB[i].time, internalOB[i].bias, 0)) continue;

      double obSize = internalOB[i].high - internalOB[i].low;

      if(obSize <= 0) continue;

      bool touched = false;

      double entryPrice = 0;

      if(internalOB[i].bias == BULLISH && ask <= internalOB[i].high && ask >= internalOB[i].low)

      { touched = true; entryPrice = internalOB[i].high; }

      else if(internalOB[i].bias == BEARISH && bid >= internalOB[i].low && bid <= internalOB[i].high)

      { touched = true; entryPrice = internalOB[i].low; }

      if(touched)

      {

         int before = sampleCount;

         CreateSample(internalOB[i], true, entryPrice, atrVal);

         if(sampleCount > before)

         {

            Print("SMC2 sample criado ID=", samples[sampleCount-1].id,

                  " OB=", internalOB[i].time, " bias=", internalOB[i].bias, " INTERNAL");

            MarkOBAsSampled(internalOB[i].time, internalOB[i].bias, 0);

         }

      }

   }

   // Swing OBs

   int sLimit = MathMin(swingOBSize, SwingOBCount);

   for(int i = 0; i < sLimit; i++)

   {

      if(IsOBAlreadySampled(swingOB[i].time, swingOB[i].bias, 1)) continue;

      double obSize = swingOB[i].high - swingOB[i].low;

      if(obSize <= 0) continue;

      bool touched = false;

      double entryPrice = 0;

      if(swingOB[i].bias == BULLISH && ask <= swingOB[i].high && ask >= swingOB[i].low)

      { touched = true; entryPrice = swingOB[i].high; }

      else if(swingOB[i].bias == BEARISH && bid >= swingOB[i].low && bid <= swingOB[i].high)

      { touched = true; entryPrice = swingOB[i].low; }

      if(touched)

      {

         int before = sampleCount;

         CreateSample(swingOB[i], false, entryPrice, atrVal);

         if(sampleCount > before)

         {

            Print("SMC2 sample criado ID=", samples[sampleCount-1].id,

                  " OB=", swingOB[i].time, " bias=", swingOB[i].bias, " SWING");

            MarkOBAsSampled(swingOB[i].time, swingOB[i].bias, 1);

         }

      }

   }

}

bool ComputeMLFeatures_LGBM(const OrderBlock &ob, bool isInternal,
                       double entryPrice, double atrVal,
                       double &features[])
{
   if(ArraySize(features) != 23)
      ArrayResize(features, 23);

   double obHigh = ob.high, obLow = ob.low, obSize = obHigh - obLow;
   if(obSize <= 0 || atrVal <= 0) return false;

   int N = MathMax(2, LookbackN);
   double highest = rawHighs[0], lowest = rawLows[0];
   for(int i = 1; i < N && i < MAX_BARS; i++)
   {
      if(rawHighs[i] > highest) highest = rawHighs[i];
      if(rawLows[i]  < lowest)  lowest  = rawLows[i];
   }
   double rangeN = highest - lowest;

   double lastBOS = 0;
   for(int i = eventCount-1; i >= 0; i--)
      if(events[i].breakTime <= TimeCurrent()) { lastBOS = events[i].level; break; }

   int k = 0;
   features[k++] = obSize / atrVal;
   int bso = (int)Bars(_Symbol, _Period, ob.time, TimeCurrent()) - 1;
   features[k++] = (double)MathMax(0, bso);
   features[k++] = MathLog((double)MathMax(0, bso) + 1.0);
   features[k++] = atrVal;
   features[k++] = (rangeN > 0) ? rangeN / atrVal : 0.0;
   features[k++] = (swingHigh.currentLevel > 0) ? MathAbs(entryPrice - swingHigh.currentLevel) / atrVal : 0.0;
   features[k++] = (swingLow.currentLevel  > 0) ? MathAbs(entryPrice - swingLow.currentLevel)  / atrVal : 0.0;
   features[k++] = (lastBOS > 0) ? MathAbs(entryPrice - lastBOS) / atrVal : 0.0;
   features[k++] = (entryPrice > (highest+lowest)/2.0) ? 1.0 : 0.0;
   features[k++] = (rangeN > 0) ? MathMax(0.0, MathMin(1.0, (((obHigh+obLow)/2.0)-lowest)/rangeN)) : 0.0;
   features[k++] = (VelocityN < MAX_BARS && atrVal > 0) ? (rawCloses[0]-rawCloses[MathMax(1,VelocityN)])/((double)MathMax(1,VelocityN)*atrVal) : 0.0;

   int swH=0, swL=0;
   for(int i=1; i<MathMax(2,SweepN) && i+1<MAX_BARS; i++) {
      if(rawHighs[i]>rawHighs[i+1] && rawCloses[i]<rawHighs[i+1]) swH=1;
      if(rawLows[i]<rawLows[i+1] && rawCloses[i]>rawLows[i+1]) swL=1;
   }
   features[k++] = (double)swH; features[k++] = (double)swL;

   double bosL=0; datetime obW=ob.time+(datetime)PeriodSeconds(_Period)*2;
   for(int i=eventCount-1; i>=0; i--) if(events[i].breakTime<=obW) { bosL=events[i].level; break; }
   features[k++] = (bosL>0)?MathAbs(bosL-(ob.bias==BULLISH?ob.low:ob.high))/atrVal:0.0;

   int chop=0; for(int i=1; i<N && i<MAX_BARS; i++) if(rawHighs[i]>=ob.low && rawLows[i]<=ob.high) chop++;
   features[k++] = (double)chop;
   features[k++] = (double)swingTrend;
   features[k++] = (double)internalTrend;

   int nOBs=0; double crd=CrowdingATR*atrVal;
   for(int i=0; i<MathMin(internalOBSize,InternalOBCount); i++) if(MathAbs((internalOB[i].high+internalOB[i].low)/2.0-entryPrice)<crd) nOBs++;
   for(int i=0; i<MathMin(swingOBSize,SwingOBCount); i++) if(MathAbs((swingOB[i].high+swingOB[i].low)/2.0-entryPrice)<crd) nOBs++;
   features[k++] = (double)nOBs;
   features[k++] = (swingTrend!=0 && swingTrend==internalTrend)?1.0:0.0;
   features[k++] = ob.ob_volume_ratio;
   features[k++] = ob.impulse_volume_ratio;
   features[k++] = ob.volume_per_range_ob;
   features[k++] = ob.volume_per_range_impulse;

   return true;
}

#endif
