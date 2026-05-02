//+------------------------------------------------------------------+
//| POI_ContextSMC.mqh - OB/context engine ported from V2000          |
//| Builds chart-timeframe LuxAlgo SMC context for ML features only.  |
//+------------------------------------------------------------------+
#ifndef POI_CONTEXT_SMC_MQH
#define POI_CONTEXT_SMC_MQH

#include "POI_Config.mqh"

POI_Pivot          poi_ctxSwingHigh;
POI_Pivot          poi_ctxSwingLow;
POI_Pivot          poi_ctxInternalHigh;
POI_Pivot          poi_ctxInternalLow;

POI_StructureEvent poi_ctxEvents[POI_MAX_EVENTS];
int                poi_ctxEventCount      = 0;

int                poi_ctxSwingTrend      = 0;
int                poi_ctxInternalTrend   = 0;
int                poi_ctxSwingLastLeg    = -1;
int                poi_ctxInternalLastLeg = -1;

int                poi_ctxBarsCount       = 0;
ENUM_TIMEFRAMES    poi_ctxBaseTf          = PERIOD_CURRENT;

double             poi_ctxRawHighs[POI_MAX_BARS];
double             poi_ctxRawLows[POI_MAX_BARS];
double             poi_ctxRawOpens[POI_MAX_BARS];
double             poi_ctxRawCloses[POI_MAX_BARS];
double             poi_ctxRawVolumes[POI_MAX_BARS];
double             poi_ctxParsedHighs[POI_MAX_BARS];
double             poi_ctxParsedLows[POI_MAX_BARS];
double             poi_ctxAtrValues[POI_MAX_BARS];
double             poi_ctxVolatilityArr[POI_MAX_BARS];
datetime           poi_ctxTimeArr[POI_MAX_BARS];

POI_OrderBlock     poi_internalOB[POI_MAX_OBS];
POI_OrderBlock     poi_swingOB[POI_MAX_OBS];
int                poi_internalOBSize     = 0;
int                poi_swingOBSize        = 0;

int                poi_ctxAtrHandle       = INVALID_HANDLE;
ENUM_TIMEFRAMES    poi_ctxAtrHandleTf     = PERIOD_CURRENT;

ENUM_TIMEFRAMES POI_ContextBaseTimeframe()
{
   return (POIContextOrderBlockTimeframe == PERIOD_CURRENT)
          ? (ENUM_TIMEFRAMES)_Period
          : POIContextOrderBlockTimeframe;
}

bool POI_ContextEnabled()
{
   return (POIContextBuildOrderBlocks || POIContextBuildFVG);
}

bool POI_ContextHasState()
{
   return (poi_ctxBarsCount > 0);
}

void POI_ContextResetPivot(POI_Pivot &p)
{
   p.currentLevel = 0.0;
   p.lastLevel    = 0.0;
   p.crossed      = false;
   p.barTime      = 0;
   p.barIndex     = -1;
}

void POI_ContextResetState()
{
   POI_ContextResetPivot(poi_ctxSwingHigh);
   POI_ContextResetPivot(poi_ctxSwingLow);
   POI_ContextResetPivot(poi_ctxInternalHigh);
   POI_ContextResetPivot(poi_ctxInternalLow);
   poi_ctxSwingTrend      = 0;
   poi_ctxInternalTrend   = 0;
   poi_ctxSwingLastLeg    = -1;
   poi_ctxInternalLastLeg = -1;
   poi_ctxEventCount      = 0;
   poi_internalOBSize     = 0;
   poi_swingOBSize        = 0;
}

void POI_ContextSMCReset()
{
   POI_ContextResetState();
   poi_ctxBarsCount = 0;
}

void POI_ContextSMCDeinit()
{
   if(poi_ctxAtrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(poi_ctxAtrHandle);
      poi_ctxAtrHandle = INVALID_HANDLE;
   }
}

bool POI_ContextEnsureAtrHandle(const ENUM_TIMEFRAMES tf)
{
   if(!POIContextUseAtrFilter)
      return true;

   if(poi_ctxAtrHandle != INVALID_HANDLE && poi_ctxAtrHandleTf == tf)
      return true;

   if(poi_ctxAtrHandle != INVALID_HANDLE)
      IndicatorRelease(poi_ctxAtrHandle);

   poi_ctxAtrHandle = iATR(_Symbol, tf, 200);
   poi_ctxAtrHandleTf = tf;
   return (poi_ctxAtrHandle != INVALID_HANDLE);
}

int POI_ContextHighestRecent(const double &arr[], int startIndex, int count)
{
   int best = startIndex;
   double bestVal = arr[startIndex];
   for(int i = startIndex + 1; i < startIndex + count; i++)
   {
      if(arr[i] > bestVal)
      {
         bestVal = arr[i];
         best = i;
      }
   }
   return best;
}

int POI_ContextLowestRecent(const double &arr[], int startIndex, int count)
{
   int best = startIndex;
   double bestVal = arr[startIndex];
   for(int i = startIndex + 1; i < startIndex + count; i++)
   {
      if(arr[i] < bestVal)
      {
         bestVal = arr[i];
         best = i;
      }
   }
   return best;
}

int POI_ContextLegAt(const double &high[], const double &low[], int barsCount, int currentIndex, int size)
{
   int candidate = currentIndex + size;
   if(candidate >= barsCount || currentIndex + size - 1 >= barsCount)
      return -1;

   int recentHighIndex = POI_ContextHighestRecent(high, currentIndex, size);
   int recentLowIndex  = POI_ContextLowestRecent(low, currentIndex, size);

   bool newLegHigh = high[candidate] > high[recentHighIndex];
   bool newLegLow  = low[candidate]  < low[recentLowIndex];

   if(newLegHigh) return POI_BEARISH_LEG;
   if(newLegLow)  return POI_BULLISH_LEG;
   return -1;
}

void POI_ContextUpdateStructurePivot(POI_Pivot &p, double level, datetime barTime, int barIndex)
{
   p.lastLevel    = p.currentLevel;
   p.currentLevel = level;
   p.crossed      = false;
   p.barTime      = barTime;
   p.barIndex     = barIndex;
}

void POI_ContextProcessStructurePivot(bool internal, int barsCount, int currentIndex, int size)
{
   int leg = POI_ContextLegAt(poi_ctxRawHighs, poi_ctxRawLows, barsCount, currentIndex, size);
   if(leg == -1) return;

   int pivotIndex = currentIndex + size;

   if(internal)
   {
      if(leg != poi_ctxInternalLastLeg)
      {
         if(leg == POI_BULLISH_LEG)
            POI_ContextUpdateStructurePivot(poi_ctxInternalLow, poi_ctxRawLows[pivotIndex], poi_ctxTimeArr[pivotIndex], pivotIndex);
         else
            POI_ContextUpdateStructurePivot(poi_ctxInternalHigh, poi_ctxRawHighs[pivotIndex], poi_ctxTimeArr[pivotIndex], pivotIndex);
      }
      poi_ctxInternalLastLeg = leg;
   }
   else
   {
      if(leg != poi_ctxSwingLastLeg)
      {
         if(leg == POI_BULLISH_LEG)
            POI_ContextUpdateStructurePivot(poi_ctxSwingLow, poi_ctxRawLows[pivotIndex], poi_ctxTimeArr[pivotIndex], pivotIndex);
         else
            POI_ContextUpdateStructurePivot(poi_ctxSwingHigh, poi_ctxRawHighs[pivotIndex], poi_ctxTimeArr[pivotIndex], pivotIndex);
      }
      poi_ctxSwingLastLeg = leg;
   }
}

bool POI_ContextBullishConfluence(int index)
{
   double upperWick    = poi_ctxRawHighs[index] - MathMax(poi_ctxRawCloses[index], poi_ctxRawOpens[index]);
   double lowerMeasure = MathMin(poi_ctxRawCloses[index], poi_ctxRawOpens[index] - poi_ctxRawLows[index]);
   return upperWick > lowerMeasure;
}

bool POI_ContextBearishConfluence(int index)
{
   double upperWick    = poi_ctxRawHighs[index] - MathMax(poi_ctxRawCloses[index], poi_ctxRawOpens[index]);
   double lowerMeasure = MathMin(poi_ctxRawCloses[index], poi_ctxRawOpens[index] - poi_ctxRawLows[index]);
   return upperWick < lowerMeasure;
}

void POI_ContextRecordEvent(const POI_Pivot &p, datetime breakTime, int breakBarIndex,
                            bool bullish, bool internal, bool choch)
{
   if(poi_ctxEventCount >= POI_MAX_EVENTS) return;
   poi_ctxEvents[poi_ctxEventCount].pivotTime     = p.barTime;
   poi_ctxEvents[poi_ctxEventCount].breakTime     = breakTime;
   poi_ctxEvents[poi_ctxEventCount].level         = p.currentLevel;
   poi_ctxEvents[poi_ctxEventCount].bullish       = bullish;
   poi_ctxEvents[poi_ctxEventCount].internal      = internal;
   poi_ctxEvents[poi_ctxEventCount].choch         = choch;
   poi_ctxEvents[poi_ctxEventCount].pivotBarIndex = p.barIndex;
   poi_ctxEvents[poi_ctxEventCount].breakBarIndex = breakBarIndex;
   poi_ctxEventCount++;
}

void POI_ContextRemoveOrderBlock(POI_OrderBlock &arr[], int &size, const int idx)
{
   if(idx < 0 || idx >= size) return;
   for(int i = idx; i < size - 1; i++)
      arr[i] = arr[i + 1];
   size--;
}

void POI_ContextPushOrderBlock(POI_OrderBlock &arr[], int &size, const POI_OrderBlock &ob)
{
   int lim = MathMin(size, POI_MAX_OBS - 1);
   for(int i = lim; i > 0; i--)
      arr[i] = arr[i - 1];

   arr[0] = ob;
   if(size < POI_MAX_OBS)
      size++;
   else
      size = POI_MAX_OBS;
}

void POI_ContextFilterNestedOrderBlocks(POI_OrderBlock &arr[], int &size)
{
   for(int i = size - 1; i >= 0; i--)
   {
      for(int j = 0; j < size; j++)
      {
         if(i == j) continue;
         if(arr[i].bias == arr[j].bias && arr[i].high <= arr[j].high && arr[i].low >= arr[j].low)
         {
            POI_ContextRemoveOrderBlock(arr, size, i);
            break;
         }
      }
   }
}

void POI_ContextFilterCrossNestedOrderBlocks()
{
   for(int i = poi_internalOBSize - 1; i >= 0; i--)
   {
      for(int j = 0; j < poi_swingOBSize; j++)
      {
         if(poi_internalOB[i].bias == poi_swingOB[j].bias &&
            poi_internalOB[i].high <= poi_swingOB[j].high &&
            poi_internalOB[i].low  >= poi_swingOB[j].low)
         {
            POI_ContextRemoveOrderBlock(poi_internalOB, poi_internalOBSize, i);
            break;
         }
      }
   }

   for(int i = poi_swingOBSize - 1; i >= 0; i--)
   {
      for(int j = 0; j < poi_internalOBSize; j++)
      {
         if(poi_swingOB[i].bias == poi_internalOB[j].bias &&
            poi_swingOB[i].high <= poi_internalOB[j].high &&
            poi_swingOB[i].low  >= poi_internalOB[j].low)
         {
            POI_ContextRemoveOrderBlock(poi_swingOB, poi_swingOBSize, i);
            break;
         }
      }
   }
}

double POI_ContextAverageVolume(int start, int count, int barsCount)
{
   double sum = 0.0;
   int valid = 0;
   for(int i = start; i < start + count && i < barsCount; i++)
   {
      if(poi_ctxRawVolumes[i] > 0.0)
      {
         sum += poi_ctxRawVolumes[i];
         valid++;
      }
   }
   return (valid > 0) ? sum / (double)valid : 1.0;
}

double POI_ContextComputeOBVolumeRatio(int obIndex, int barsCount)
{
   double avg = POI_ContextAverageVolume(obIndex, 20, barsCount);
   return (avg > 0.0) ? poi_ctxRawVolumes[obIndex] / avg : 0.0;
}

double POI_ContextComputeImpulseVolumeRatio(int obIndex, int bosIndex, int barsCount)
{
   double sum = 0.0;
   int count = 0;
   int lo = MathMin(obIndex, bosIndex);
   int hi = MathMax(obIndex, bosIndex);
   for(int i = lo; i <= hi && i < barsCount; i++)
   {
      sum += poi_ctxRawVolumes[i];
      count++;
   }
   if(count == 0) return 0.0;

   double avg = POI_ContextAverageVolume(hi, 20, barsCount);
   return (avg > 0.0) ? (sum / (double)count) / avg : 0.0;
}

double POI_ContextVolumePerRange(int index)
{
   double range = poi_ctxRawHighs[index] - poi_ctxRawLows[index];
   return (range > 0.0) ? poi_ctxRawVolumes[index] / range : 0.0;
}

double POI_ContextComputeImpulseVolumePerRange(int obIndex, int bosIndex, int barsCount)
{
   double sum = 0.0;
   int count = 0;
   int lo = MathMin(obIndex, bosIndex);
   int hi = MathMax(obIndex, bosIndex);
   for(int i = lo; i <= hi && i < barsCount; i++)
   {
      double range = poi_ctxRawHighs[i] - poi_ctxRawLows[i];
      if(range > 0.0)
      {
         sum += poi_ctxRawVolumes[i] / range;
         count++;
      }
   }
   return (count > 0) ? sum / (double)count : 0.0;
}

void POI_ContextStoreOrderBlockFromRange(const POI_Pivot &p, bool internal, int bias, int currentIndex, int barsCount)
{
   if(!POIContextBuildOrderBlocks) return;
   if(p.barIndex < 0 || currentIndex > p.barIndex) return;

   int picked = p.barIndex;
   if(bias == POI_BEARISH)
   {
      double best = poi_ctxParsedHighs[currentIndex];
      picked = currentIndex;
      for(int i = currentIndex; i <= p.barIndex; i++)
      {
         if(poi_ctxParsedHighs[i] > best)
         {
            best = poi_ctxParsedHighs[i];
            picked = i;
         }
      }
   }
   else
   {
      double best = poi_ctxParsedLows[currentIndex];
      picked = currentIndex;
      for(int i = currentIndex; i <= p.barIndex; i++)
      {
         if(poi_ctxParsedLows[i] < best)
         {
            best = poi_ctxParsedLows[i];
            picked = i;
         }
      }
   }

   POI_OrderBlock ob;
   ob.high = poi_ctxParsedHighs[picked];
   ob.low  = poi_ctxParsedLows[picked];
   ob.time = poi_ctxTimeArr[picked];
   ob.bias = bias;
   ob.ob_volume_ratio          = POI_ContextComputeOBVolumeRatio(picked, barsCount);
   ob.impulse_volume_ratio     = POI_ContextComputeImpulseVolumeRatio(picked, currentIndex, barsCount);
   ob.volume_per_range_ob      = POI_ContextVolumePerRange(picked);
   ob.volume_per_range_impulse = POI_ContextComputeImpulseVolumePerRange(picked, currentIndex, barsCount);
   ob.ob_raw_volume            = poi_ctxRawVolumes[picked];

   if(internal)
   {
      POI_ContextPushOrderBlock(poi_internalOB, poi_internalOBSize, ob);
      if(POIContextFilterContainedOBs)
         POI_ContextFilterNestedOrderBlocks(poi_internalOB, poi_internalOBSize);
   }
   else
   {
      POI_ContextPushOrderBlock(poi_swingOB, poi_swingOBSize, ob);
      if(POIContextFilterContainedOBs)
         POI_ContextFilterNestedOrderBlocks(poi_swingOB, poi_swingOBSize);
   }
}

void POI_ContextProcessDisplayStructure(bool internal, int index, int barsCount, bool internalFilterConfluence)
{
   bool bullishBar = !internalFilterConfluence || !internal || POI_ContextBullishConfluence(index);
   bool bearishBar = !internalFilterConfluence || !internal || POI_ContextBearishConfluence(index);

   if(internal)
   {
      if(poi_ctxInternalHigh.currentLevel > 0.0)
      {
         bool extraCondition = (poi_ctxInternalHigh.currentLevel != poi_ctxSwingHigh.currentLevel) && bullishBar;
         bool crossed = poi_ctxRawCloses[index] > poi_ctxInternalHigh.currentLevel &&
                        poi_ctxRawCloses[index + 1] <= poi_ctxInternalHigh.currentLevel;
         if(crossed && !poi_ctxInternalHigh.crossed && extraCondition)
         {
            bool choch = (poi_ctxInternalTrend == POI_BEARISH);
            poi_ctxInternalHigh.crossed = true;
            poi_ctxInternalTrend = POI_BULLISH;
            POI_ContextRecordEvent(poi_ctxInternalHigh, poi_ctxTimeArr[index], index, true, true, choch);
            POI_ContextStoreOrderBlockFromRange(poi_ctxInternalHigh, true, POI_BULLISH, index, barsCount);
         }
      }

      if(poi_ctxInternalLow.currentLevel > 0.0)
      {
         bool extraCondition = (poi_ctxInternalLow.currentLevel != poi_ctxSwingLow.currentLevel) && bearishBar;
         bool crossed = poi_ctxRawCloses[index] < poi_ctxInternalLow.currentLevel &&
                        poi_ctxRawCloses[index + 1] >= poi_ctxInternalLow.currentLevel;
         if(crossed && !poi_ctxInternalLow.crossed && extraCondition)
         {
            bool choch = (poi_ctxInternalTrend == POI_BULLISH);
            poi_ctxInternalLow.crossed = true;
            poi_ctxInternalTrend = POI_BEARISH;
            POI_ContextRecordEvent(poi_ctxInternalLow, poi_ctxTimeArr[index], index, false, true, choch);
            POI_ContextStoreOrderBlockFromRange(poi_ctxInternalLow, true, POI_BEARISH, index, barsCount);
         }
      }
   }
   else
   {
      if(poi_ctxSwingHigh.currentLevel > 0.0)
      {
         bool crossed = poi_ctxRawCloses[index] > poi_ctxSwingHigh.currentLevel &&
                        poi_ctxRawCloses[index + 1] <= poi_ctxSwingHigh.currentLevel;
         if(crossed && !poi_ctxSwingHigh.crossed)
         {
            bool choch = (poi_ctxSwingTrend == POI_BEARISH);
            poi_ctxSwingHigh.crossed = true;
            poi_ctxSwingTrend = POI_BULLISH;
            POI_ContextRecordEvent(poi_ctxSwingHigh, poi_ctxTimeArr[index], index, true, false, choch);
            POI_ContextStoreOrderBlockFromRange(poi_ctxSwingHigh, false, POI_BULLISH, index, barsCount);
         }
      }

      if(poi_ctxSwingLow.currentLevel > 0.0)
      {
         bool crossed = poi_ctxRawCloses[index] < poi_ctxSwingLow.currentLevel &&
                        poi_ctxRawCloses[index + 1] >= poi_ctxSwingLow.currentLevel;
         if(crossed && !poi_ctxSwingLow.crossed)
         {
            bool choch = (poi_ctxSwingTrend == POI_BULLISH);
            poi_ctxSwingLow.crossed = true;
            poi_ctxSwingTrend = POI_BEARISH;
            POI_ContextRecordEvent(poi_ctxSwingLow, poi_ctxTimeArr[index], index, false, false, choch);
            POI_ContextStoreOrderBlockFromRange(poi_ctxSwingLow, false, POI_BEARISH, index, barsCount);
         }
      }
   }
}

void POI_ContextDeleteMitigatedOrderBlocks(bool internal, int index)
{
   double bearSource = POIContextUseCloseForOBMitigation ? poi_ctxRawCloses[index] : poi_ctxRawHighs[index];
   double bullSource = POIContextUseCloseForOBMitigation ? poi_ctxRawCloses[index] : poi_ctxRawLows[index];

   if(internal)
   {
      for(int i = poi_internalOBSize - 1; i >= 0; i--)
      {
         if((poi_internalOB[i].bias == POI_BEARISH && bearSource > poi_internalOB[i].high) ||
            (poi_internalOB[i].bias == POI_BULLISH && bullSource < poi_internalOB[i].low))
            POI_ContextRemoveOrderBlock(poi_internalOB, poi_internalOBSize, i);
      }
   }
   else
   {
      for(int i = poi_swingOBSize - 1; i >= 0; i--)
      {
         if((poi_swingOB[i].bias == POI_BEARISH && bearSource > poi_swingOB[i].high) ||
            (poi_swingOB[i].bias == POI_BULLISH && bullSource < poi_swingOB[i].low))
            POI_ContextRemoveOrderBlock(poi_swingOB, poi_swingOBSize, i);
      }
   }
}

bool POI_ContextSMCRun(int swingLength, int internalLength, bool internalFilterConfluence)
{
   if(!POI_ContextEnabled())
   {
      POI_ContextSMCReset();
      return true;
   }

   ENUM_TIMEFRAMES tf = POI_ContextBaseTimeframe();
   int rates_total = Bars(_Symbol, tf);
   if(rates_total < MathMax(swingLength, internalLength) + 3)
   {
      POI_ContextSMCReset();
      return false;
   }

   int barsCount = MathMin(rates_total, POI_MAX_BARS);
   double openTmp[], highTmp[], lowTmp[], closeTmp[], atrTmp[];
   datetime timeTmp[];
   long volumeLong[];

   ArraySetAsSeries(openTmp, true);
   ArraySetAsSeries(highTmp, true);
   ArraySetAsSeries(lowTmp, true);
   ArraySetAsSeries(closeTmp, true);
   ArraySetAsSeries(timeTmp, true);
   ArraySetAsSeries(atrTmp, true);
   ArraySetAsSeries(volumeLong, true);

   if(CopyOpen (_Symbol, tf, 0, barsCount, openTmp)  <= 0) return false;
   if(CopyHigh (_Symbol, tf, 0, barsCount, highTmp)  <= 0) return false;
   if(CopyLow  (_Symbol, tf, 0, barsCount, lowTmp)   <= 0) return false;
   if(CopyClose(_Symbol, tf, 0, barsCount, closeTmp) <= 0) return false;
   if(CopyTime (_Symbol, tf, 0, barsCount, timeTmp)  <= 0) return false;

   bool volumeOK = false;
   if(CopyRealVolume(_Symbol, tf, 0, barsCount, volumeLong) > 0)
      volumeOK = true;
   else if(CopyTickVolume(_Symbol, tf, 0, barsCount, volumeLong) > 0)
      volumeOK = true;

   if(POIContextUseAtrFilter)
   {
      if(!POI_ContextEnsureAtrHandle(tf)) return false;
      if(CopyBuffer(poi_ctxAtrHandle, 0, 0, barsCount, atrTmp) <= 0) return false;
   }

   double cumulativeTR = 0.0;
   for(int i = barsCount - 1; i >= 0; i--)
   {
      poi_ctxRawHighs[i]   = highTmp[i];
      poi_ctxRawLows[i]    = lowTmp[i];
      poi_ctxRawOpens[i]   = openTmp[i];
      poi_ctxRawCloses[i]  = closeTmp[i];
      poi_ctxRawVolumes[i] = volumeOK ? (double)volumeLong[i] : 1.0;
      poi_ctxTimeArr[i]    = timeTmp[i];

      double prevClose = (i == barsCount - 1 ? closeTmp[i] : closeTmp[i + 1]);
      double tr = MathMax(highTmp[i] - lowTmp[i],
                          MathMax(MathAbs(highTmp[i] - prevClose), MathAbs(lowTmp[i] - prevClose)));
      cumulativeTR += tr;

      double rangeMeasure = ((barsCount - 1 - i) + 1 > 0)
                            ? cumulativeTR / (double)((barsCount - 1 - i) + 1)
                            : tr;
      double atrVal = rangeMeasure;
      if(POIContextUseAtrFilter)
         atrVal = atrTmp[i];
      double volatility = (atrVal > 0.0) ? atrVal : rangeMeasure;

      poi_ctxAtrValues[i]     = atrVal;
      poi_ctxVolatilityArr[i] = volatility;

      bool highVol = (highTmp[i] - lowTmp[i]) >= (2.0 * volatility);
      poi_ctxParsedHighs[i] = highVol ? lowTmp[i]  : highTmp[i];
      poi_ctxParsedLows[i]  = highVol ? highTmp[i] : lowTmp[i];
   }

   POI_ContextResetState();
   poi_ctxBarsCount = barsCount;
   poi_ctxBaseTf = tf;

   for(int index = barsCount - MathMax(swingLength, internalLength) - 2; index >= 0; index--)
   {
      if(index + 1 >= barsCount) continue;

      POI_ContextProcessStructurePivot(false, barsCount, index, swingLength);
      POI_ContextProcessStructurePivot(true,  barsCount, index, internalLength);

      POI_ContextProcessDisplayStructure(true,  index, barsCount, internalFilterConfluence);
      POI_ContextProcessDisplayStructure(false, index, barsCount, internalFilterConfluence);

      if(POIContextBuildOrderBlocks)
      {
         POI_ContextDeleteMitigatedOrderBlocks(true,  index);
         POI_ContextDeleteMitigatedOrderBlocks(false, index);
      }
   }

   if(POIContextFilterContainedOBs && POIContextBuildOrderBlocks)
      POI_ContextFilterCrossNestedOrderBlocks();

   return true;
}

#endif
