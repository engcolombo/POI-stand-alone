//+------------------------------------------------------------------+
//| POI_DatasetPOI.mqh - dataset POI no formato do V2000              |
//| Mantem as 42 features esperadas por train_AFT_model_POI_local.py. |
//+------------------------------------------------------------------+
#ifndef POI_DATASET_POI_MQH
#define POI_DATASET_POI_MQH

#include "POI_Config.mqh"
#include "POI_FeaturesML.mqh"
#include "POI_ContextSMC.mqh"
#include "POI_FVG_LuxAlgo.mqh"

struct POITradeSample
{
   long     id;
   long     poi_id;
   string   poi_tag;
   int      poi_bias;
   datetime confirm_time;
   datetime entry_time;
   datetime entry_bar_time;
   double   entry_price;
   double   sl;
   double   risk;

   int      confirm_age_minutes;
   double   range_atr_ratio;
   double   dist_to_favorable_liquidity;
   double   dist_to_adverse_liquidity;
   double   dist_to_last_bos;
   int      pd_entry_zone;
   double   pd_zone_mid_distance_from_eq;
   int      pd_is_favorable_for_bias;
   double   range_pos;
   double   velocity;
   int      alignment;
   double   atr5_atr20_ratio;
   double   dist_to_prev_day_high;
   double   dist_to_prev_day_low;

   double   pattern_total_range_atr;
   double   leg_ab_atr;
   double   leg_bc_atr;
   double   leg_cd_atr;
   double   leg_de_atr;
   double   leg_ef_atr;
   double   bc_retracement_of_ab;
   double   de_retracement_of_cd;
   double   ef_extension_vs_de;
   double   confirm_displacement_atr;
   double   zone_size_vs_pattern_range;
   double   path_efficiency;
   double   e_candle_range_atr;
   double   e_rejection_wick_atr;
   int      bars_a_to_f_m1;

   double   sweep_depth_beyond_c_atr;
   double   sweep_depth_beyond_c_ratio;
   double   f_break_margin_vs_d_atr;
   double   confirm_to_touch_max_extension_atr;
   double   confirm_to_touch_pullback_efficiency;
   int      poi_overlaps_m5_ob;
   double   dist_to_nearest_m5_ob_atr;
   int      poi_overlaps_fvg;
   double   dist_to_nearest_fvg_atr;
   double   real_volume_e_atr_norm;
   double   real_volume_f_atr_norm;
   double   m1_pattern_velocity;
   int      m1_bias_aligned_with_m5;

   double   mfe;
   double   mae;
   bool     hit_1R;
   bool     hit_2R;
   bool     hit_3R;
   int      bars_alive;
   int      bars_to_1R;
   int      bars_to_2R;
   int      bars_to_3R;
   bool     finished;
   int      end_reason;
   bool     censored;
};

POITradeSample poiSamples[POI_MAX_SAMPLES];
int            poiSampleCount  = 0;
long           nextPOISampleId = 1;

long           sampledPOIIds[POI_MAX_SAMPLED];
int            sampledPOICount = 0;

string         poiCsvBuffer      = "";
int            poiCsvBufferCount = 0;

void POI_DatasetReset()
{
   poiSampleCount = 0;
   nextPOISampleId = 1;
   sampledPOICount = 0;
   poiCsvBuffer = "";
   poiCsvBufferCount = 0;
   POI_ResetMLFeatureCaches();
}

long POI_DatasetZoneId(const POI_Zone &zone)
{
   long t = (long)zone.createdTime;
   long midPts = (_Point > 0.0) ? (long)MathRound(zone.midPrice / _Point) : (long)MathRound(zone.midPrice);
   long h = (t % 1000003) * 31 + (midPts % 100003) * 17 + (zone.bias == POI_BULLISH ? 1 : 2);
   if(h < 0) h = -h;
   return h;
}

bool POI_IsPOIAlreadySampled(const long poiId)
{
   for(int i = 0; i < sampledPOICount; i++)
      if(sampledPOIIds[i] == poiId)
         return true;
   return false;
}

void POI_MarkPOIAsSampled(const long poiId)
{
   if(POI_IsPOIAlreadySampled(poiId)) return;

   if(sampledPOICount >= POI_MAX_SAMPLED)
   {
      for(int i = 0; i < POI_MAX_SAMPLED - 1; i++)
         sampledPOIIds[i] = sampledPOIIds[i + 1];
      sampledPOICount = POI_MAX_SAMPLED - 1;
   }

   sampledPOIIds[sampledPOICount++] = poiId;
}

double POI_GetDatasetEntryPrice(const POI_Zone &zone, const double entryPct)
{
   double rectHigh, rectLow;
   POI_ResolveVisualZoneBounds(zone, rectHigh, rectLow);
   double zoneSize = rectHigh - rectLow;
   if(zoneSize <= 0.0) return 0.0;

   double pct = MathMax(0.0, MathMin(1.0, entryPct));
   if(zone.bias == POI_BULLISH)
      return POI_NormalizePrice(rectHigh - zoneSize * pct);

   return POI_NormalizePrice(rectLow + zoneSize * pct);
}

double POI_DatasetMaxPrice(const POI_Zone &zone)
{
   double maxVal = zone.pA;
   if(zone.pB > maxVal) maxVal = zone.pB;
   if(zone.pC > maxVal) maxVal = zone.pC;
   if(zone.pD > maxVal) maxVal = zone.pD;
   if(zone.pE > maxVal) maxVal = zone.pE;
   if(zone.pF > maxVal) maxVal = zone.pF;
   if(zone.eCandleHigh > maxVal) maxVal = zone.eCandleHigh;
   if(zone.legHigh > maxVal) maxVal = zone.legHigh;
   return maxVal;
}

double POI_DatasetMinPrice(const POI_Zone &zone)
{
   double minVal = zone.pA;
   if(zone.pB < minVal) minVal = zone.pB;
   if(zone.pC < minVal) minVal = zone.pC;
   if(zone.pD < minVal) minVal = zone.pD;
   if(zone.pE < minVal) minVal = zone.pE;
   if(zone.pF < minVal) minVal = zone.pF;
   if(zone.eCandleLow < minVal) minVal = zone.eCandleLow;
   if(zone.legLow < minVal) minVal = zone.legLow;
   return minVal;
}

double POI_IntervalDistance(const double aLow, const double aHigh, const double bLow, const double bHigh)
{
   if(aHigh >= bLow && bHigh >= aLow) return 0.0;
   if(aHigh < bLow) return bLow - aHigh;
   return aLow - bHigh;
}

void POI_GetPOILiquidityDistances(const int bias, const double entryPrice, const double atrVal,
                                  double &favorableDist, double &adverseDist)
{
   favorableDist = 0.0;
   adverseDist   = 0.0;
   if(atrVal <= 0.0) return;

   double swingHighLevel = POI_ContextHasState() ? poi_ctxSwingHigh.currentLevel : luxSwingHigh.currentLevel;
   double swingLowLevel  = POI_ContextHasState() ? poi_ctxSwingLow.currentLevel  : luxSwingLow.currentLevel;

   if(bias == POI_BULLISH)
   {
      favorableDist = (swingHighLevel > 0.0) ? MathAbs(entryPrice - swingHighLevel) / atrVal : 0.0;
      adverseDist   = (swingLowLevel  > 0.0) ? MathAbs(entryPrice - swingLowLevel)  / atrVal : 0.0;
   }
   else
   {
      favorableDist = (swingLowLevel  > 0.0) ? MathAbs(entryPrice - swingLowLevel)  / atrVal : 0.0;
      adverseDist   = (swingHighLevel > 0.0) ? MathAbs(entryPrice - swingHighLevel) / atrVal : 0.0;
   }
}

void POI_GetPOIOverlapWithOBs(const double zoneLow, const double zoneHigh, const double atrVal,
                              int &overlaps, double &nearestDistATR)
{
   overlaps = 0;
   nearestDistATR = 0.0;
   if(atrVal <= 0.0) return;

   double bestDist = DBL_MAX;
   bool found = false;

   int iLimit = MathMin(poi_internalOBSize, POIContextInternalOBCount);
   for(int i = 0; i < iLimit; i++)
   {
      double dist = POI_IntervalDistance(zoneLow, zoneHigh, poi_internalOB[i].low, poi_internalOB[i].high);
      if(dist <= 0.0) overlaps = 1;
      if(dist < bestDist)
      {
         bestDist = dist;
         found = true;
      }
   }

   int sLimit = MathMin(poi_swingOBSize, POIContextSwingOBCount);
   for(int i = 0; i < sLimit; i++)
   {
      double dist = POI_IntervalDistance(zoneLow, zoneHigh, poi_swingOB[i].low, poi_swingOB[i].high);
      if(dist <= 0.0) overlaps = 1;
      if(dist < bestDist)
      {
         bestDist = dist;
         found = true;
      }
   }

   nearestDistATR = found ? bestDist / atrVal : 0.0;
}

void POI_GetPOIOverlapWithFVGs(const double zoneLow, const double zoneHigh, const double atrVal,
                               int &overlaps, double &nearestDistATR)
{
   overlaps = 0;
   nearestDistATR = 0.0;
   if(atrVal <= 0.0) return;

   double bestDist = DBL_MAX;
   bool found = false;

   for(int i = 0; i < g_luxFvgCount; i++)
   {
      double fvgTop = g_luxFvgBuf[i].top;
      double fvgBottom = g_luxFvgBuf[i].bottom;
      double dist = POI_IntervalDistance(zoneLow, zoneHigh, fvgBottom, fvgTop);
      if(dist <= 0.0) overlaps = 1;
      if(dist < bestDist)
      {
         bestDist = dist;
         found = true;
      }
   }

   nearestDistATR = found ? bestDist / atrVal : 0.0;
}

double POI_GetRealVolumeSumBetweenTimes(const ENUM_TIMEFRAMES tf, const datetime startTime, const datetime endTime)
{
   if(startTime <= 0 || endTime <= 0 || endTime < startTime) return 0.0;

   long volumeArrLocal[];
   if(CopyRealVolume(_Symbol, tf, startTime, endTime, volumeArrLocal) > 0)
   {
      double sum = 0.0;
      for(int i = 0; i < ArraySize(volumeArrLocal); i++)
         sum += (double)volumeArrLocal[i];
      return sum;
   }

   return 0.0;
}

double POI_GetConfirmToTouchMaxExtensionATR(const int bias, const double zoneLow, const double zoneHigh,
                                           const datetime confirmTime, const datetime touchTime, const double atrVal)
{
   if(atrVal <= 0.0 || confirmTime <= 0 || touchTime <= 0 || touchTime < confirmTime)
      return 0.0;

   double best = 0.0;
   for(int i = 0; i < luxBarsCount; i++)
   {
      if(timeArr[i] < confirmTime || timeArr[i] > touchTime) continue;
      double ext = (bias == POI_BULLISH) ? (rawHighs[i] - zoneHigh) : (zoneLow - rawLows[i]);
      if(ext > best) best = ext;
   }
   return MathMax(0.0, best) / atrVal;
}

double POI_GetConfirmToTouchPullbackEfficiency(const datetime confirmTime, const datetime touchTime,
                                               const double entryPrice)
{
   if(confirmTime <= 0 || touchTime <= 0 || touchTime < confirmTime) return 0.0;

   double firstPrice = 0.0;
   double lastPrice = 0.0;
   double pathDist = 0.0;
   bool found = false;

   for(int i = luxBarsCount - 1; i >= 0; i--)
   {
      if(timeArr[i] < confirmTime || timeArr[i] > touchTime) continue;
      if(!found)
      {
         firstPrice = rawCloses[i];
         lastPrice = rawCloses[i];
         found = true;
      }
      else
      {
         pathDist += MathAbs(rawCloses[i] - lastPrice);
         lastPrice = rawCloses[i];
      }
   }

   if(!found) return 0.0;
   pathDist += MathAbs(lastPrice - entryPrice);
   return POI_SafeDivide(MathAbs(firstPrice - entryPrice), pathDist);
}

void POI_FlushPOICSVBuffer()
{
   if(poiCsvBuffer == "") return;

   int sep = StringFind(CsvPathPOI, "\\", 0);
   if(sep > 0)
   {
      string folder = StringSubstr(CsvPathPOI, 0, sep);
      FolderCreate(folder, FILE_COMMON);
   }

   int file = FileOpen(CsvPathPOI, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_SHARE_WRITE|FILE_COMMON);
   if(file == INVALID_HANDLE)
   {
      file = FileOpen(CsvPathPOI, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_SHARE_WRITE);
      if(file == INVALID_HANDLE) return;
   }

   FileSeek(file, 0, SEEK_END);
   if(FileTell(file) == 0)
   {
      string h = "confirm_age_minutes,range_atr_ratio,";
      h += "dist_to_favorable_liquidity,dist_to_adverse_liquidity,dist_to_last_bos,pd_entry_zone,";
      h += "pd_zone_mid_distance_from_eq,pd_is_favorable_for_bias,range_pos,velocity,alignment,";
      h += "atr5_atr20_ratio,dist_to_prev_day_high,dist_to_prev_day_low,";
      h += "pattern_total_range_atr,leg_ab_atr,leg_bc_atr,leg_cd_atr,leg_de_atr,leg_ef_atr,";
      h += "bc_retracement_of_ab,de_retracement_of_cd,ef_extension_vs_de,";
      h += "confirm_displacement_atr,zone_size_vs_pattern_range,";
      h += "path_efficiency,e_candle_range_atr,e_rejection_wick_atr,bars_a_to_f_m1,";
      h += "sweep_depth_beyond_c_atr,sweep_depth_beyond_c_ratio,f_break_margin_vs_d_atr,";
      h += "confirm_to_touch_max_extension_atr,confirm_to_touch_pullback_efficiency,";
      h += "poi_overlaps_m5_ob,dist_to_nearest_m5_ob_atr,poi_overlaps_fvg,dist_to_nearest_fvg_atr,";
      h += "real_volume_e_atr_norm,real_volume_f_atr_norm,";
      h += "m1_pattern_velocity,m1_bias_aligned_with_m5,";
      h += "id,poi_id,poi_tag,poi_bias,confirm_time,entry_time,entry_price,sl,risk,";
      h += "mfe,mae,hit_1R,hit_2R,hit_3R,";
      h += "bars_to_1R,bars_to_2R,bars_to_3R,bars_alive,end_reason,censored\n";
      FileWriteString(file, h);
   }

   FileWriteString(file, poiCsvBuffer);
   FileClose(file);

   Print("POI CSV flush: ", poiCsvBufferCount, " samples gravados em ", CsvPathPOI);
   poiCsvBuffer = "";
   poiCsvBufferCount = 0;
}

void POI_WritePOISampleToCSV(POITradeSample &s)
{
   string row = IntegerToString(s.confirm_age_minutes) + ",";
   row += DoubleToString(s.range_atr_ratio, 4) + ",";
   row += DoubleToString(s.dist_to_favorable_liquidity, 4) + ",";
   row += DoubleToString(s.dist_to_adverse_liquidity, 4) + ",";
   row += DoubleToString(s.dist_to_last_bos, 4) + ",";
   row += IntegerToString(s.pd_entry_zone) + ",";
   row += DoubleToString(s.pd_zone_mid_distance_from_eq, 4) + ",";
   row += IntegerToString(s.pd_is_favorable_for_bias) + ",";
   row += DoubleToString(s.range_pos, 4) + ",";
   row += DoubleToString(s.velocity, 4) + ",";
   row += IntegerToString(s.alignment) + ",";
   row += DoubleToString(s.atr5_atr20_ratio, 4) + ",";
   row += DoubleToString(s.dist_to_prev_day_high, 4) + ",";
   row += DoubleToString(s.dist_to_prev_day_low, 4) + ",";
   row += DoubleToString(s.pattern_total_range_atr, 4) + ",";
   row += DoubleToString(s.leg_ab_atr, 4) + ",";
   row += DoubleToString(s.leg_bc_atr, 4) + ",";
   row += DoubleToString(s.leg_cd_atr, 4) + ",";
   row += DoubleToString(s.leg_de_atr, 4) + ",";
   row += DoubleToString(s.leg_ef_atr, 4) + ",";
   row += DoubleToString(s.bc_retracement_of_ab, 4) + ",";
   row += DoubleToString(s.de_retracement_of_cd, 4) + ",";
   row += DoubleToString(s.ef_extension_vs_de, 4) + ",";
   row += DoubleToString(s.confirm_displacement_atr, 4) + ",";
   row += DoubleToString(s.zone_size_vs_pattern_range, 4) + ",";
   row += DoubleToString(s.path_efficiency, 4) + ",";
   row += DoubleToString(s.e_candle_range_atr, 4) + ",";
   row += DoubleToString(s.e_rejection_wick_atr, 4) + ",";
   row += IntegerToString(s.bars_a_to_f_m1) + ",";
   row += DoubleToString(s.sweep_depth_beyond_c_atr, 4) + ",";
   row += DoubleToString(s.sweep_depth_beyond_c_ratio, 4) + ",";
   row += DoubleToString(s.f_break_margin_vs_d_atr, 4) + ",";
   row += DoubleToString(s.confirm_to_touch_max_extension_atr, 4) + ",";
   row += DoubleToString(s.confirm_to_touch_pullback_efficiency, 4) + ",";
   row += IntegerToString(s.poi_overlaps_m5_ob) + ",";
   row += DoubleToString(s.dist_to_nearest_m5_ob_atr, 4) + ",";
   row += IntegerToString(s.poi_overlaps_fvg) + ",";
   row += DoubleToString(s.dist_to_nearest_fvg_atr, 4) + ",";
   row += DoubleToString(s.real_volume_e_atr_norm, 4) + ",";
   row += DoubleToString(s.real_volume_f_atr_norm, 4) + ",";
   row += DoubleToString(s.m1_pattern_velocity, 6) + ",";
   row += IntegerToString(s.m1_bias_aligned_with_m5) + ",";
   row += IntegerToString((int)s.id) + ",";
   row += IntegerToString((int)s.poi_id) + ",";
   row += s.poi_tag + ",";
   row += IntegerToString(s.poi_bias) + ",";
   row += TimeToString(s.confirm_time, TIME_DATE|TIME_MINUTES) + ",";
   row += TimeToString(s.entry_time, TIME_DATE|TIME_MINUTES) + ",";
   row += DoubleToString(s.entry_price, _Digits) + ",";
   row += DoubleToString(s.sl, _Digits) + ",";
   row += DoubleToString(s.risk, _Digits) + ",";
   row += DoubleToString(s.mfe, 4) + ",";
   row += DoubleToString(s.mae, 4) + ",";
   row += IntegerToString(s.hit_1R ? 1 : 0) + ",";
   row += IntegerToString(s.hit_2R ? 1 : 0) + ",";
   row += IntegerToString(s.hit_3R ? 1 : 0) + ",";
   row += IntegerToString(s.bars_to_1R) + ",";
   row += IntegerToString(s.bars_to_2R) + ",";
   row += IntegerToString(s.bars_to_3R) + ",";
   row += IntegerToString(s.bars_alive) + ",";
   row += IntegerToString(s.end_reason) + ",";
   row += IntegerToString(s.censored ? 1 : 0) + "\n";

   poiCsvBuffer += row;
   poiCsvBufferCount++;

   if(poiCsvBufferCount >= POI_CSV_FLUSH_EVERY)
      POI_FlushPOICSVBuffer();
}

void POI_RemovePOISample(const int index)
{
   if(index < 0 || index >= poiSampleCount) return;
   poiSamples[index] = poiSamples[poiSampleCount - 1];
   poiSampleCount--;
}

bool POI_CreatePOISample(const POI_Zone &zone, const double atrVal)
{
   if(poiSampleCount >= POI_MAX_SAMPLES) return false;
   if(atrVal <= 0.0) return false;

   double rectHigh, rectLow;
   POI_ResolveVisualZoneBounds(zone, rectHigh, rectLow);
   double zoneSize = rectHigh - rectLow;
   if(zoneSize <= 0.0) return false;

   double entryPrice = POI_GetDatasetEntryPrice(zone, POIEntryPercent);
   if(entryPrice <= 0.0) return false;

   double stopOffset = StopOffsetPoints * _Point;
   double sl = (zone.bias == POI_BULLISH)
               ? POI_NormalizePrice(rectLow - stopOffset)
               : POI_NormalizePrice(rectHigh + stopOffset);
   double risk = MathAbs(entryPrice - sl);
   if(risk <= 0.0) return false;

   POI_EnsureMLBarContextCache(atrVal);

   double zoneMid = (rectHigh + rectLow) / 2.0;
   double atr20Val = POI_GetCurrentATR20();
   double atr5Val  = POI_GetCurrentATR5();
   if(atr20Val <= 0.0) atr20Val = atrVal;
   if(atr5Val  <= 0.0) atr5Val  = atrVal;

   double prevDayHighVal = 0.0, prevDayLowVal = 0.0;
   double d1Hi[1], d1Lo[1];
   if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, d1Hi) == 1) prevDayHighVal = d1Hi[0];
   if(CopyLow(_Symbol, PERIOD_D1, 1, 1, d1Lo) == 1)  prevDayLowVal  = d1Lo[0];

   double legAB = MathAbs(zone.pB - zone.pA);
   double legBC = MathAbs(zone.pC - zone.pB);
   double legCD = MathAbs(zone.pD - zone.pC);
   double legDE = MathAbs(zone.pE - zone.pD);
   double legEF = MathAbs(zone.pF - zone.pE);
   double totalLegTravel = legAB + legBC + legCD + legDE + legEF;
   double patternMax = POI_DatasetMaxPrice(zone);
   double patternMin = POI_DatasetMinPrice(zone);
   double patternRange = patternMax - patternMin;
   double sweepDepthBeyondC = (zone.bias == POI_BULLISH)
                              ? MathMax(0.0, zone.pC - zone.pE)
                              : MathMax(0.0, zone.pE - zone.pC);
   double fBreakMarginVsD = (zone.bias == POI_BULLISH)
                            ? MathMax(0.0, zone.pF - zone.pD)
                            : MathMax(0.0, zone.pD - zone.pF);

   double realVolumeE = POI_GetRealVolumeSumBetweenTimes(PERIOD_M1, zone.tD, zone.tE);
   double realVolumeF = POI_GetRealVolumeSumBetweenTimes(PERIOD_M1, zone.tE + PeriodSeconds(PERIOD_M1), zone.tF);

   POITradeSample s;
   s.id           = nextPOISampleId++;
   s.poi_id       = POI_DatasetZoneId(zone);
   s.poi_tag      = StringFormat("POI_%I64d_%I64d_%s",
                                 s.poi_id,
                                 (long)zone.createdTime,
                                 zone.bias == POI_BULLISH ? "BUL" : "BEA");
   s.poi_bias     = zone.bias;
   s.confirm_time = zone.createdTime;
   s.entry_time   = TimeCurrent();
   s.entry_bar_time = (luxBarsCount > 0 ? timeArr[0] : TimeCurrent());
   s.entry_price  = entryPrice;
   s.sl           = sl;
   s.risk         = risk;

   s.confirm_age_minutes          = POI_MinutesBetween(s.entry_time, zone.createdTime);
   s.range_atr_ratio              = (poi_mlBarContextCache.rangeN > 0.0) ? poi_mlBarContextCache.rangeN / atrVal : 0.0;
   POI_GetPOILiquidityDistances(zone.bias, entryPrice, atrVal,
                                s.dist_to_favorable_liquidity, s.dist_to_adverse_liquidity);
   s.dist_to_last_bos             = (poi_mlBarContextCache.lastBOS > 0.0) ? MathAbs(entryPrice - poi_mlBarContextCache.lastBOS) / atrVal : 0.0;
   s.pd_entry_zone                = POI_ClassifyPDZoneCached(entryPrice);
   s.pd_zone_mid_distance_from_eq = poi_mlBarContextCache.hasLuxPD ? MathAbs(zoneMid - poi_mlBarContextCache.eqPrice) / atrVal : 0.0;
   s.pd_is_favorable_for_bias     = ((zone.bias == POI_BULLISH && s.pd_entry_zone == -1) ||
                                     (zone.bias == POI_BEARISH && s.pd_entry_zone == 1)) ? 1 : 0;
   s.range_pos                    = POI_LuxRangePositionCached(zoneMid);
   s.velocity                     = poi_mlBarContextCache.velocity;
   int contextSwingTrend = POI_ContextHasState() ? poi_ctxSwingTrend : luxSwingTrend;
   int contextInternalTrend = POI_ContextHasState() ? poi_ctxInternalTrend : luxInternalTrend;
   s.alignment                    = (contextSwingTrend != 0 && contextSwingTrend == contextInternalTrend) ? 1 : 0;
   s.atr5_atr20_ratio             = (atr20Val > 0.0) ? atr5Val / atr20Val : 1.0;
   s.dist_to_prev_day_high        = (prevDayHighVal > 0.0) ? (prevDayHighVal - entryPrice) / atrVal : 0.0;
   s.dist_to_prev_day_low         = (prevDayLowVal  > 0.0) ? (entryPrice - prevDayLowVal) / atrVal : 0.0;

   s.pattern_total_range_atr      = (patternRange > 0.0) ? patternRange / atrVal : 0.0;
   s.leg_ab_atr                   = legAB / atrVal;
   s.leg_bc_atr                   = legBC / atrVal;
   s.leg_cd_atr                   = legCD / atrVal;
   s.leg_de_atr                   = legDE / atrVal;
   s.leg_ef_atr                   = legEF / atrVal;
   s.bc_retracement_of_ab         = POI_SafeDivide(legBC, legAB);
   s.de_retracement_of_cd         = POI_SafeDivide(legDE, legCD);
   s.ef_extension_vs_de           = POI_SafeDivide(legEF, legDE);
   s.confirm_displacement_atr     = (zone.bias == POI_BULLISH)
                                    ? MathMax(0.0, zone.pF - rectHigh) / atrVal
                                    : MathMax(0.0, rectLow - zone.pF) / atrVal;
   s.zone_size_vs_pattern_range   = POI_SafeDivide(zoneSize, patternRange);
   s.path_efficiency              = POI_SafeDivide(MathAbs(zone.pF - zone.pA), totalLegTravel);
   s.e_candle_range_atr           = MathMax(0.0, zone.eCandleHigh - zone.eCandleLow) / atrVal;
   s.e_rejection_wick_atr         = (zone.bias == POI_BULLISH)
                                    ? MathMax(0.0, zone.pE - zone.eCandleLow) / atrVal
                                    : MathMax(0.0, zone.eCandleHigh - zone.pE) / atrVal;
   s.bars_a_to_f_m1               = POI_BarsBetweenM1(zone.tF, zone.tA);

   s.sweep_depth_beyond_c_atr       = sweepDepthBeyondC / atrVal;
   s.sweep_depth_beyond_c_ratio     = POI_SafeDivide(sweepDepthBeyondC, legCD);
   s.f_break_margin_vs_d_atr        = fBreakMarginVsD / atrVal;
   s.confirm_to_touch_max_extension_atr = POI_GetConfirmToTouchMaxExtensionATR(zone.bias, rectLow, rectHigh,
                                                                               zone.createdTime, s.entry_time, atrVal);
   s.confirm_to_touch_pullback_efficiency = POI_GetConfirmToTouchPullbackEfficiency(zone.createdTime, s.entry_time, entryPrice);
   POI_GetPOIOverlapWithOBs(rectLow, rectHigh, atrVal, s.poi_overlaps_m5_ob, s.dist_to_nearest_m5_ob_atr);
   POI_GetPOIOverlapWithFVGs(rectLow, rectHigh, atrVal, s.poi_overlaps_fvg, s.dist_to_nearest_fvg_atr);
   s.real_volume_e_atr_norm         = realVolumeE / atrVal;
   s.real_volume_f_atr_norm         = realVolumeF / atrVal;

   int barsAF = POI_BarsBetweenM1(zone.tF, zone.tA);
   s.m1_pattern_velocity            = (barsAF > 0) ? POI_SafeDivide((zone.pF - zone.pA) / atrVal, (double)barsAF) : 0.0;
   s.m1_bias_aligned_with_m5        = ((zone.bias == POI_BULLISH && contextInternalTrend == 1) ||
                                       (zone.bias == POI_BEARISH && contextInternalTrend == -1)) ? 1 : 0;

   s.mfe = 0.0;
   s.mae = 0.0;
   s.hit_1R = false;
   s.hit_2R = false;
   s.hit_3R = false;
   s.bars_alive = 0;
   s.bars_to_1R = -1;
   s.bars_to_2R = -1;
   s.bars_to_3R = -1;
   s.finished   = false;
   s.end_reason = -1;
   s.censored   = false;

   poiSamples[poiSampleCount++] = s;
   return true;
}

void POI_UpdatePOISamplesOnBarClose()
{
   int leh, lem;
   POI_EnumToHM(CloseTime, leh, lem);
   int logEndMin = leh * 60 + lem;

   for(int i = 0; i < poiSampleCount; i++)
   {
      if(poiSamples[i].finished) continue;

      poiSamples[i].bars_alive++;

      MqlDateTime now;
      TimeToStruct(TimeCurrent(), now);
      int curMin = now.hour * 60 + now.min;

      if(curMin >= logEndMin)
      {
         poiSamples[i].finished   = true;
         poiSamples[i].end_reason = 2;
         poiSamples[i].censored   = true;
      }
      else if(poiSamples[i].bars_alive >= MaxBarsTracking)
      {
         poiSamples[i].finished   = true;
         poiSamples[i].end_reason = 3;
         poiSamples[i].censored   = true;
      }

      if(poiSamples[i].finished)
      {
         POI_WritePOISampleToCSV(poiSamples[i]);
         POI_RemovePOISample(i);
         i--;
      }
   }
}

void POI_UpdatePOIMFEMAE_OnTick(const double ask, const double bid)
{
   for(int i = 0; i < poiSampleCount; i++)
   {
      if(poiSamples[i].finished) continue;

      double favMove, advMove;
      if(poiSamples[i].poi_bias == POI_BULLISH)
      {
         favMove = (bid - poiSamples[i].entry_price) / poiSamples[i].risk;
         advMove = (poiSamples[i].entry_price - bid) / poiSamples[i].risk;
      }
      else
      {
         favMove = (poiSamples[i].entry_price - ask) / poiSamples[i].risk;
         advMove = (ask - poiSamples[i].entry_price) / poiSamples[i].risk;
      }

      if(favMove > poiSamples[i].mfe) poiSamples[i].mfe = favMove;
      if(advMove > poiSamples[i].mae) poiSamples[i].mae = advMove;

      if(!poiSamples[i].hit_1R && poiSamples[i].mfe >= 1.0)
      {
         poiSamples[i].hit_1R = true;
         poiSamples[i].bars_to_1R = poiSamples[i].bars_alive;
      }
      if(!poiSamples[i].hit_2R && poiSamples[i].mfe >= 2.0)
      {
         poiSamples[i].hit_2R = true;
         poiSamples[i].bars_to_2R = poiSamples[i].bars_alive;
      }
      if(!poiSamples[i].hit_3R && poiSamples[i].mfe >= 3.0)
      {
         poiSamples[i].hit_3R = true;
         poiSamples[i].bars_to_3R = poiSamples[i].bars_alive;
      }

      if(poiSamples[i].mae >= 1.0)
      {
         poiSamples[i].finished   = true;
         poiSamples[i].end_reason = 0;
      }
      else if(poiSamples[i].mfe >= MaxRTracking)
      {
         poiSamples[i].mfe        = MaxRTracking;
         poiSamples[i].finished   = true;
         poiSamples[i].end_reason = 1;
      }

      if(poiSamples[i].finished)
      {
         POI_WritePOISampleToCSV(poiSamples[i]);
         POI_RemovePOISample(i);
         i--;
      }
   }
}

void POI_CheckPOIEntryTouches(const double ask, const double bid)
{
   if(!EnablePOICSVLogging) return;

   double atrVal = POI_GetCurrentATR();
   if(atrVal <= 0.0) return;

   int maxBarsAfterTouch = (POIDatasetMaxBarsAfterFirstTouch < 0 ? 0 : POIDatasetMaxBarsAfterFirstTouch);
   datetime currentBarTime = (luxBarsCount > 0 ? timeArr[0] : TimeCurrent());

   for(int i = 0; i < POI_MAX_ZONES; i++)
   {
      if(!poi_zones[i].active) continue;

      long zoneId = POI_DatasetZoneId(poi_zones[i]);
      if(POI_IsPOIAlreadySampled(zoneId)) continue;
      if(poi_zones[i].sampled) continue;

      double rectHigh, rectLow;
      POI_ResolveVisualZoneBounds(poi_zones[i], rectHigh, rectLow);
      if(rectHigh <= rectLow) continue;

      double refPrice = (poi_zones[i].bias == POI_BULLISH ? ask : bid);
      bool priceInsideZone = (refPrice <= rectHigh && refPrice >= rectLow);

      if(!poi_zones[i].firstTouchSeen && priceInsideZone)
      {
         poi_zones[i].firstTouchSeen = true;
         poi_zones[i].firstTouchTime = TimeCurrent();
         poi_zones[i].firstTouchBarTime = currentBarTime;
      }

      if(!poi_zones[i].firstTouchSeen) continue;

      if(maxBarsAfterTouch > 0 && poi_zones[i].firstTouchBarTime > 0)
      {
         int barsSinceFirstTouch = POI_BarsBetweenM1(currentBarTime, poi_zones[i].firstTouchBarTime);
         if(barsSinceFirstTouch > maxBarsAfterTouch) continue;
      }

      double entryPrice = POI_GetDatasetEntryPrice(poi_zones[i], POIEntryPercent);
      if(entryPrice <= 0.0) continue;

      bool touched = false;
      if(poi_zones[i].bias == POI_BULLISH)
         touched = (ask <= entryPrice);
      else
         touched = (bid >= entryPrice);

      if(!touched) continue;

      int before = poiSampleCount;
      if(!POI_CreatePOISample(poi_zones[i], atrVal)) continue;

      if(poiSampleCount > before)
      {
         poi_zones[i].sampled = true;
         POI_MarkPOIAsSampled(zoneId);
         if(DebugMode)
            Print("POI sample criado ID=", poiSamples[poiSampleCount - 1].id,
                  " POI=", zoneId,
                  " confirm=", TimeToString(poi_zones[i].createdTime, TIME_DATE|TIME_MINUTES),
                  " bias=", poi_zones[i].bias);
      }
   }
}

void POI_FinalizePOIDataset()
{
   for(int i = 0; i < poiSampleCount; i++)
   {
      poiSamples[i].finished   = true;
      poiSamples[i].end_reason = 3;
      poiSamples[i].censored   = true;
      POI_WritePOISampleToCSV(poiSamples[i]);
   }

   poiSampleCount = 0;
   POI_FlushPOICSVBuffer();
}

#endif
