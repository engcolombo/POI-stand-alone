//+------------------------------------------------------------------+
//| ROBOSMC_V900_ML1_DatasetPOI.mqh - Dataset isolado para POIs      |
//| Mantem o logger atual intacto e cria um pipeline paralelo novo   |
//+------------------------------------------------------------------+
#ifndef ROBOSMC_V2000_DATASET_POI_MQH
#define ROBOSMC_V2000_DATASET_POI_MQH

#define MAX_SAMPLED_POI 500

struct POITradeSample
{
   long     id;
   int      poi_id;
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

POITradeSample poiSamples[MAX_SAMPLES];
int            poiSampleCount  = 0;
long           nextPOISampleId = 1;

int            sampledPOIIds[MAX_SAMPLED_POI];
int            sampledPOICount = 0;

string         poiCsvBuffer      = "";
int            poiCsvBufferCount = 0;

bool IsPOIAlreadySampled(const int poiId)
{
   for(int i = 0; i < sampledPOICount; i++)
      if(sampledPOIIds[i] == poiId)
         return true;
   return false;
}

void MarkPOIAsSampled(const int poiId)
{
   if(sampledPOICount >= MAX_SAMPLED_POI)
   {
      for(int i = 0; i < MAX_SAMPLED_POI - 1; i++)
         sampledPOIIds[i] = sampledPOIIds[i + 1];
      sampledPOICount = MAX_SAMPLED_POI - 1;
   }

   sampledPOIIds[sampledPOICount++] = poiId;
}

double SafeDivide(const double numerator, const double denominator)
{
   if(MathAbs(denominator) <= 1e-12) return 0.0;
   return numerator / denominator;
}

int MinutesBetween(const datetime newerTime, const datetime olderTime)
{
   if(newerTime <= 0 || olderTime <= 0 || newerTime <= olderTime) return 0;
   return (int)((newerTime - olderTime) / 60);
}

int BarsBetweenM1(const datetime newerTime, const datetime olderTime)
{
   if(newerTime <= 0 || olderTime <= 0 || newerTime <= olderTime) return 0;
   return (int)((newerTime - olderTime) / PeriodSeconds(PERIOD_M1));
}

double GetPOIDatasetEntryPrice(const POIZone &zone, const double entryPct)
{
   double zoneSize = zone.zoneHigh - zone.zoneLow;
   if(zoneSize <= 0.0) return 0.0;

   if(zone.bias == BULLISH)
      return NormalizePrice(zone.zoneHigh - zoneSize * entryPct);

   return NormalizePrice(zone.zoneLow + zoneSize * entryPct);
}

double POIMaxPrice(const POIZone &zone)
{
   double maxVal = zone.pA;
   if(zone.pB > maxVal) maxVal = zone.pB;
   if(zone.pC > maxVal) maxVal = zone.pC;
   if(zone.pD > maxVal) maxVal = zone.pD;
   if(zone.pE > maxVal) maxVal = zone.pE;
   if(zone.pF > maxVal) maxVal = zone.pF;
   if(zone.eCandleHigh > maxVal) maxVal = zone.eCandleHigh;
   if(zone.zoneHigh    > maxVal) maxVal = zone.zoneHigh;
   return maxVal;
}

double POIMinPrice(const POIZone &zone)
{
   double minVal = zone.pA;
   if(zone.pB < minVal) minVal = zone.pB;
   if(zone.pC < minVal) minVal = zone.pC;
   if(zone.pD < minVal) minVal = zone.pD;
   if(zone.pE < minVal) minVal = zone.pE;
   if(zone.pF < minVal) minVal = zone.pF;
   if(zone.eCandleLow < minVal) minVal = zone.eCandleLow;
   if(zone.zoneLow    < minVal) minVal = zone.zoneLow;
   return minVal;
}

double IntervalDistance(const double aLow, const double aHigh, const double bLow, const double bHigh)
{
   if(aHigh >= bLow && bHigh >= aLow) return 0.0;
   if(aHigh < bLow) return bLow - aHigh;
   return aLow - bHigh;
}

void GetPOILiquidityDistances(const int bias, const double entryPrice, const double atrVal,
                              double &favorableDist, double &adverseDist)
{
   favorableDist = 0.0;
   adverseDist   = 0.0;
   if(atrVal <= 0.0) return;

   if(bias == BULLISH)
   {
      favorableDist = (swingHigh.currentLevel > 0.0) ? MathAbs(entryPrice - swingHigh.currentLevel) / atrVal : 0.0;
      adverseDist   = (swingLow.currentLevel  > 0.0) ? MathAbs(entryPrice - swingLow.currentLevel)  / atrVal : 0.0;
   }
   else
   {
      favorableDist = (swingLow.currentLevel  > 0.0) ? MathAbs(entryPrice - swingLow.currentLevel)  / atrVal : 0.0;
      adverseDist   = (swingHigh.currentLevel > 0.0) ? MathAbs(entryPrice - swingHigh.currentLevel) / atrVal : 0.0;
   }
}

void GetPOIOverlapWithOBs(const double zoneLow, const double zoneHigh, const double atrVal,
                          int &overlaps, double &nearestDistATR)
{
   overlaps = 0;
   nearestDistATR = 0.0;
   if(atrVal <= 0.0) return;

   double bestDist = DBL_MAX;
   bool found = false;

   int iLimit = MathMin(internalOBSize, InternalOBCount);
   for(int i = 0; i < iLimit; i++)
   {
      double dist = IntervalDistance(zoneLow, zoneHigh, internalOB[i].low, internalOB[i].high);
      if(dist <= 0.0) overlaps = 1;
      if(dist < bestDist)
      {
         bestDist = dist;
         found = true;
      }
   }

   int sLimit = MathMin(swingOBSize, SwingOBCount);
   for(int i = 0; i < sLimit; i++)
   {
      double dist = IntervalDistance(zoneLow, zoneHigh, swingOB[i].low, swingOB[i].high);
      if(dist <= 0.0) overlaps = 1;
      if(dist < bestDist)
      {
         bestDist = dist;
         found = true;
      }
   }

   nearestDistATR = found ? bestDist / atrVal : 0.0;
}

void GetPOIOverlapWithFVGs(const double zoneLow, const double zoneHigh, const double atrVal,
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
      double dist = IntervalDistance(zoneLow, zoneHigh, fvgBottom, fvgTop);
      if(dist <= 0.0) overlaps = 1;
      if(dist < bestDist)
      {
         bestDist = dist;
         found = true;
      }
   }

   nearestDistATR = found ? bestDist / atrVal : 0.0;
}

double GetRealVolumeSumBetweenTimes(const ENUM_TIMEFRAMES tf, const datetime startTime, const datetime endTime)
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

double GetConfirmToTouchMaxExtensionATR(const int bias, const double zoneLow, const double zoneHigh,
                                        const datetime confirmTime, const datetime touchTime, const double atrVal)
{
   if(atrVal <= 0.0 || confirmTime <= 0 || touchTime <= 0 || touchTime < confirmTime)
      return 0.0;

   int startShift = iBarShift(_Symbol, _Period, confirmTime, false);
   int endShift   = iBarShift(_Symbol, _Period, touchTime, false);
   if(startShift < 0 || endShift < 0) return 0.0;

   int fromShift = MathMax(startShift, endShift);
   int toShift   = MathMin(startShift, endShift);
   int count = fromShift - toShift + 1;
   if(count <= 0) return 0.0;

   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, _Period, toShift, count, highs) <= 0) return 0.0;
   if(CopyLow(_Symbol, _Period, toShift, count, lows) <= 0) return 0.0;

   double best = 0.0;
   for(int i = 0; i < count; i++)
   {
      double ext = (bias == BULLISH) ? (highs[i] - zoneHigh) : (zoneLow - lows[i]);
      if(ext > best) best = ext;
   }
   return MathMax(0.0, best) / atrVal;
}

double GetConfirmToTouchPullbackEfficiency(const datetime confirmTime, const datetime touchTime, const double entryPrice)
{
   if(confirmTime <= 0 || touchTime <= 0 || touchTime < confirmTime) return 0.0;

   int startShift = iBarShift(_Symbol, _Period, confirmTime, false);
   int endShift   = iBarShift(_Symbol, _Period, touchTime, false);
   if(startShift < 0 || endShift < 0) return 0.0;

   int fromShift = MathMax(startShift, endShift);
   int toShift   = MathMin(startShift, endShift);
   int count = fromShift - toShift + 1;
   if(count <= 0) return 0.0;

   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, _Period, toShift, count, closes) <= 0) return 0.0;

   double directDist = MathAbs(closes[count - 1] - entryPrice);
   double pathDist = 0.0;
   for(int i = count - 1; i > 0; i--)
      pathDist += MathAbs(closes[i] - closes[i - 1]);
   pathDist += MathAbs(closes[0] - entryPrice);

   return SafeDivide(directDist, pathDist);
}

void FlushPOICSVBuffer()
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

   Print("SMC2 POI CSV flush: ", poiCsvBufferCount, " samples gravados em ", CsvPathPOI);
   poiCsvBuffer      = "";
   poiCsvBufferCount = 0;
}

void WritePOISampleToCSV(POITradeSample &s)
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
   row += IntegerToString(s.poi_id) + ",";
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

   if(poiCsvBufferCount >= CSV_FLUSH_EVERY)
      FlushPOICSVBuffer();
}

void RemovePOISample(const int index)
{
   if(index < 0 || index >= poiSampleCount) return;
   poiSamples[index] = poiSamples[poiSampleCount - 1];
   poiSampleCount--;
}

bool CreatePOISample(const POIZone &zone, const double atrVal)
{
   if(poiSampleCount >= MAX_SAMPLES) return false;
   if(atrVal <= 0.0) return false;

   double zoneHigh = zone.zoneHigh;
   double zoneLow  = zone.zoneLow;
   double zoneSize = zoneHigh - zoneLow;
   if(zoneSize <= 0.0) return false;

   double entryPrice = GetPOIDatasetEntryPrice(zone, POIEntryPercent);
   if(entryPrice <= 0.0) return false;

   double stopOffset = POIStopOffsetPts * _Point;
   double sl = (zone.bias == BULLISH)
               ? NormalizePrice(zone.eCandleLow - stopOffset)
               : NormalizePrice(zone.eCandleHigh + stopOffset);
   double risk = MathAbs(entryPrice - sl);
   if(risk <= 0.0) return false;

   EnsureMLBarContextCache(atrVal);

   double zoneMid = (zoneHigh + zoneLow) / 2.0;
   double atr20Val = GetCurrentATR20();
   double atr5Val  = GetCurrentATR5();
   if(atr20Val <= 0.0) atr20Val = atrVal;
   if(atr5Val  <= 0.0) atr5Val  = atrVal;

   double prevDayHighVal = 0.0, prevDayLowVal = 0.0;
   double d1Hi[2], d1Lo[2];
   if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, d1Hi) == 1) prevDayHighVal = d1Hi[0];
   if(CopyLow(_Symbol, PERIOD_D1, 1, 1, d1Lo) == 1)  prevDayLowVal  = d1Lo[0];

   double legAB = MathAbs(zone.pB - zone.pA);
   double legBC = MathAbs(zone.pC - zone.pB);
   double legCD = MathAbs(zone.pD - zone.pC);
   double legDE = MathAbs(zone.pE - zone.pD);
   double legEF = MathAbs(zone.pF - zone.pE);
   double totalLegTravel = legAB + legBC + legCD + legDE + legEF;
   double patternMax = POIMaxPrice(zone);
   double patternMin = POIMinPrice(zone);
   double patternRange = patternMax - patternMin;
   double sweepDepthBeyondC = (zone.bias == BULLISH)
                              ? MathMax(0.0, zone.pC - zone.pE)
                              : MathMax(0.0, zone.pE - zone.pC);
   double fBreakMarginVsD = (zone.bias == BULLISH)
                            ? MathMax(0.0, zone.pF - zone.pD)
                            : MathMax(0.0, zone.pD - zone.pF);
   // Evita double-count da barra E: segunda soma comeca na barra seguinte a E
   double realVolumeE = GetRealVolumeSumBetweenTimes(PERIOD_M1, zone.tD, zone.tE);
   double realVolumeF = GetRealVolumeSumBetweenTimes(PERIOD_M1, zone.tE + PeriodSeconds(PERIOD_M1), zone.tF);

   POITradeSample s;
   s.id           = nextPOISampleId++;
   s.poi_id       = zone.id;
   s.poi_tag      = StringFormat("POI_%d_%I64d_%s",
                                 zone.id,
                                 (long)zone.confirmTime,
                                 zone.bias == BULLISH ? "BUL" : "BEA");
   s.poi_bias     = zone.bias;
   s.confirm_time = zone.confirmTime;
   s.entry_time   = TimeCurrent();  // instante exato do touch (melhora precisao de confirm_age_minutes)
   s.entry_price  = entryPrice;
   s.sl           = sl;
   s.risk         = risk;

   s.confirm_age_minutes          = MinutesBetween(s.entry_time, zone.confirmTime);
   s.range_atr_ratio              = (g_mlBarContextCache.rangeN > 0.0) ? g_mlBarContextCache.rangeN / atrVal : 0.0;
   GetPOILiquidityDistances(zone.bias, entryPrice, atrVal,
                            s.dist_to_favorable_liquidity, s.dist_to_adverse_liquidity);
   s.dist_to_last_bos             = (g_mlBarContextCache.lastBOS > 0.0) ? MathAbs(entryPrice - g_mlBarContextCache.lastBOS) / atrVal : 0.0;
   s.pd_entry_zone                = ClassifyLuxPDZoneCached(entryPrice);
   s.pd_zone_mid_distance_from_eq = g_mlBarContextCache.hasLuxPD ? MathAbs(zoneMid - g_mlBarContextCache.eqPrice) / atrVal : 0.0;
   s.pd_is_favorable_for_bias     = ((zone.bias == BULLISH && s.pd_entry_zone == -1) ||
                                     (zone.bias == BEARISH && s.pd_entry_zone == 1)) ? 1 : 0;
   s.range_pos                    = LuxRangePositionCached(zoneMid);
   s.velocity                     = g_mlBarContextCache.velocity;
   s.alignment                    = (swingTrend != 0 && swingTrend == internalTrend) ? 1 : 0;
   s.atr5_atr20_ratio             = (atr20Val > 0.0) ? atr5Val / atr20Val : 1.0;
   s.dist_to_prev_day_high        = (prevDayHighVal > 0.0) ? (prevDayHighVal - entryPrice) / atrVal : 0.0;
   s.dist_to_prev_day_low         = (prevDayLowVal  > 0.0) ? (entryPrice - prevDayLowVal) / atrVal : 0.0;

   s.pattern_total_range_atr      = (patternRange > 0.0) ? patternRange / atrVal : 0.0;
   s.leg_ab_atr                   = legAB / atrVal;
   s.leg_bc_atr                   = legBC / atrVal;
   s.leg_cd_atr                   = legCD / atrVal;
   s.leg_de_atr                   = legDE / atrVal;
   s.leg_ef_atr                   = legEF / atrVal;
   s.bc_retracement_of_ab         = SafeDivide(legBC, legAB);
   s.de_retracement_of_cd         = SafeDivide(legDE, legCD);
   s.ef_extension_vs_de           = SafeDivide(legEF, legDE);
   s.confirm_displacement_atr     = (zone.bias == BULLISH)
                                    ? MathMax(0.0, zone.pF - zoneHigh) / atrVal
                                    : MathMax(0.0, zoneLow - zone.pF) / atrVal;
   s.zone_size_vs_pattern_range   = SafeDivide(zoneSize, patternRange);
   s.path_efficiency              = SafeDivide(MathAbs(zone.pF - zone.pA), totalLegTravel);
   s.e_candle_range_atr           = MathMax(0.0, zone.eCandleHigh - zone.eCandleLow) / atrVal;
   // Pavio de rejeicao do candle E medido contra o close de E (nao contra a zona,
   // pois zoneLow/zoneHigh == eCandleLow/eCandleHigh por construcao).
   s.e_rejection_wick_atr         = (zone.bias == BULLISH)
                                    ? MathMax(0.0, zone.pE - zone.eCandleLow) / atrVal
                                    : MathMax(0.0, zone.eCandleHigh - zone.pE) / atrVal;
   s.bars_a_to_f_m1               = BarsBetweenM1(zone.tF, zone.tA);

   s.sweep_depth_beyond_c_atr           = sweepDepthBeyondC / atrVal;
   s.sweep_depth_beyond_c_ratio         = SafeDivide(sweepDepthBeyondC, legCD);
   s.f_break_margin_vs_d_atr            = fBreakMarginVsD / atrVal;
   s.confirm_to_touch_max_extension_atr = GetConfirmToTouchMaxExtensionATR(zone.bias, zoneLow, zoneHigh,
                                                                           zone.confirmTime, s.entry_time, atrVal);
   s.confirm_to_touch_pullback_efficiency = GetConfirmToTouchPullbackEfficiency(zone.confirmTime, s.entry_time, entryPrice);
   GetPOIOverlapWithOBs(zoneLow, zoneHigh, atrVal, s.poi_overlaps_m5_ob, s.dist_to_nearest_m5_ob_atr);
   GetPOIOverlapWithFVGs(zoneLow, zoneHigh, atrVal, s.poi_overlaps_fvg, s.dist_to_nearest_fvg_atr);
   s.real_volume_e_atr_norm             = realVolumeE / atrVal;
   s.real_volume_f_atr_norm             = realVolumeF / atrVal;

   int barsAF = BarsBetweenM1(zone.tF, zone.tA);
   s.m1_pattern_velocity                = (barsAF > 0) ? SafeDivide((zone.pF - zone.pA) / atrVal, (double)barsAF) : 0.0;
   s.m1_bias_aligned_with_m5            = ((zone.bias == BULLISH && internalTrend == 1) ||
                                           (zone.bias == BEARISH && internalTrend == -1)) ? 1 : 0;

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

void UpdatePOISamplesOnBarClose()
{
   int leh, lem;
   EnumToHM(CloseTime, leh, lem);
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
         WritePOISampleToCSV(poiSamples[i]);
         RemovePOISample(i);
         i--;
      }
   }
}

void UpdatePOIMFEMAE_OnTick(const double ask, const double bid)
{
   for(int i = 0; i < poiSampleCount; i++)
   {
      if(poiSamples[i].finished) continue;

      double favMove, advMove;
      if(poiSamples[i].poi_bias == BULLISH)
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
         WritePOISampleToCSV(poiSamples[i]);
         RemovePOISample(i);
         i--;
      }
   }
}

void CheckPOIEntryTouches(const double ask, const double bid)
{
   if(!EnablePOICSVLogging || !EnablePOI) return;

   double atrVal = GetCurrentATR();
   if(atrVal <= 0.0) return;

   int maxZones = MathMin(POIMaxZones, POI_MAX_ZONES_HARD);
   int maxBarsAfterTouch = (POIMarketMaxBarsAfterFirstTouch < 0 ? 0 : POIMarketMaxBarsAfterFirstTouch);
   datetime latestClosedM5 = iTime(_Symbol, PERIOD_M5, 1);
   for(int i = 0; i < maxZones; i++)
   {
      if(!g_poiZones[i].active) continue;
      if(g_poiZones[i].sampled) continue;

      // Expira POIs zumbi: padroes muito antigos nao refletem o regime atual do mercado
      if(POIMaxAgeMinutes > 0 && g_poiZones[i].confirmTime > 0 &&
         (TimeCurrent() - g_poiZones[i].confirmTime) / 60 > POIMaxAgeMinutes)
      {
         g_poiZones[i].active = false;
         continue;
      }

      double zoneH = g_poiZones[i].zoneHigh;
      double zoneL = g_poiZones[i].zoneLow;
      double zoneSize = zoneH - zoneL;
      if(zoneSize <= 0.0) continue;

      double refPrice = (g_poiZones[i].bias == BULLISH ? ask : bid);
      bool priceInsideZone = (refPrice <= zoneH && refPrice >= zoneL);

      if(!g_poiZones[i].firstTouchSeen && priceInsideZone)
      {
         g_poiZones[i].firstTouchSeen = true;
         g_poiZones[i].firstTouchTime = TimeCurrent();
         g_poiZones[i].firstTouchBarTime = timeArr[0];
      }

      if(g_poiZones[i].firstTouchSeen)
      {
         int barsSinceFirstTouch = POIGetBarsSinceFirstTouch(g_poiZones[i], latestClosedM5);
         if(barsSinceFirstTouch < 0) barsSinceFirstTouch = 0;

         if(maxBarsAfterTouch > 0 && barsSinceFirstTouch > maxBarsAfterTouch)
         {
             g_poiZones[i].traded = true;
            continue;
         }
      }

      double entryPrice = GetPOIDatasetEntryPrice(g_poiZones[i], POIEntryPercent);
      if(entryPrice <= 0.0) continue;
      if(!POIEntryCooldownReadyAt(g_poiZones[i], latestClosedM5)) continue;
      if(!g_poiZones[i].firstTouchSeen) continue;

      bool touched = false;
      if(g_poiZones[i].bias == BULLISH)
         touched = (ask <= entryPrice);
      else
         touched = (bid >= entryPrice);

      if(!touched) continue;

      int before = poiSampleCount;
      if(!CreatePOISample(g_poiZones[i], atrVal)) continue;

      if(poiSampleCount > before)
      {
         g_poiZones[i].sampled = true;
         Print("SMC2 POI sample criado ID=", poiSamples[poiSampleCount - 1].id,
               " POI=", g_poiZones[i].id,
               " confirm=", g_poiZones[i].confirmTime,
               " bias=", g_poiZones[i].bias);
         MarkPOIAsSampled(g_poiZones[i].id);
      }
   }
}

void FinalizePOIDataset()
{
   for(int i = 0; i < poiSampleCount; i++)
   {
      poiSamples[i].finished   = true;
      poiSamples[i].end_reason = 3;
      poiSamples[i].censored   = true;
      WritePOISampleToCSV(poiSamples[i]);
   }

   poiSampleCount = 0;
   FlushPOICSVBuffer();
}


//+------------------------------------------------------------------+
//| BuildPOIInferenceFeatures                                        |
//| Monta o vetor de 42 features para inferencia do modelo POIAFT   |
//| IMPORTANTE: real_volume_e_atr_norm e real_volume_f_atr_norm      |
//|   sao transformadas com log1p antes de retornar — OBRIGATORIO    |
//|   porque o modelo Python foi treinado com log1p nessas colunas.  |
//|   O dataset CSV coleta os valores brutos (correto), mas na       |
//|   inferencia em tempo real o log1p deve ser aplicado aqui.       |
//|                                                                  |
//| Uso futuro (quando POIUseMLFilter for implementado):             |
//|   double poiFeats[];                                             |
//|   if(BuildPOIInferenceFeatures(zone, atrVal, poiFeats))          |
//|      double predMFE = POIAFT_PredictMFE(poiFeats);              |
//|      if(predMFE >= POIAFT_MFE_THRESHOLD) { ... executar trade }  |
//+------------------------------------------------------------------+
bool BuildPOIInferenceFeatures(const POIZone &zone, const double atrVal, double &features[])
{
   const int N_FEATS = 42;
   if(ArraySize(features) != N_FEATS)
      ArrayResize(features, N_FEATS);

   if(atrVal <= 0.0) return false;

   double zoneHigh = zone.zoneHigh;
   double zoneLow  = zone.zoneLow;
   double zoneSize = zoneHigh - zoneLow;
   if(zoneSize <= 0.0) return false;

   double entryPrice = GetPOIDatasetEntryPrice(zone, POIEntryPercent);
   if(entryPrice <= 0.0) return false;

   EnsureMLBarContextCache(atrVal);

   static datetime s_cachedFeatureBarTime = 0;
   static double   s_cachedPrevDayHigh = 0.0;
   static double   s_cachedPrevDayLow = 0.0;

   if(s_cachedFeatureBarTime != timeArr[0])
   {
      s_cachedFeatureBarTime = timeArr[0];
      s_cachedPrevDayHigh = 0.0;
      s_cachedPrevDayLow = 0.0;

      double d1Hi[1], d1Lo[1];
      if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, d1Hi) == 1) s_cachedPrevDayHigh = d1Hi[0];
      if(CopyLow (_Symbol, PERIOD_D1, 1, 1, d1Lo) == 1) s_cachedPrevDayLow  = d1Lo[0];
   }

   double zoneMid    = zone.cachedZoneMid;
   double atr20Val   = GetCurrentATR20();
   double atr5Val    = GetCurrentATR5();
   if(atr20Val <= 0.0) atr20Val = atrVal;
   if(atr5Val  <= 0.0) atr5Val  = atrVal;

   double prevDayHighVal = s_cachedPrevDayHigh;
   double prevDayLowVal  = s_cachedPrevDayLow;

   double legAB = zone.cachedLegAB;
   double legBC = zone.cachedLegBC;
   double legCD = zone.cachedLegCD;
   double legDE = zone.cachedLegDE;
   double legEF = zone.cachedLegEF;
   double totalLeg = zone.cachedTotalLeg;
   double patternRange = zone.cachedPatternRange;

   double sweepDepthBeyondC = zone.cachedSweepDepthBeyondC;
   double fBreakMarginVsD   = zone.cachedFBreakMarginVsD;

   // Volume bruto das pernas E e F — evita double-count da barra E
   double realVolE = zone.rawVolE;
   double realVolF = zone.rawVolF;
   // OBRIGATORIO: log1p — modelo foi treinado com essa transformacao
   double volENorm = MathLog(1.0 + realVolE / atrVal);
   double volFNorm = MathLog(1.0 + realVolF / atrVal);

   double favorableDist = 0.0, adverseDist = 0.0;
   GetPOILiquidityDistances(zone.bias, entryPrice, atrVal, favorableDist, adverseDist);

   datetime nowRef = TimeCurrent();
   int confirmAge = MinutesBetween(nowRef, zone.confirmTime);
   double rangeN  = g_mlBarContextCache.rangeN;
   double lastBOS = g_mlBarContextCache.lastBOS;
   int pdZone     = ClassifyLuxPDZoneCached(entryPrice);
   int pdFav      = ((zone.bias == BULLISH && pdZone == -1) ||
                     (zone.bias == BEARISH && pdZone ==  1)) ? 1 : 0;
   int alignVal   = (swingTrend != 0 && swingTrend == internalTrend) ? 1 : 0;

   double confirmToTouchExt = GetConfirmToTouchMaxExtensionATR(zone.bias, zoneLow, zoneHigh,
                                                                zone.confirmTime, nowRef, atrVal);
   double confirmToTouchEff = GetConfirmToTouchPullbackEfficiency(zone.confirmTime, nowRef, entryPrice);

   int obOverlaps = 0; double obDist = 0.0;
   int fvgOverlaps = 0; double fvgDist = 0.0;
   GetPOIOverlapWithOBs(zoneLow, zoneHigh, atrVal, obOverlaps, obDist);
   GetPOIOverlapWithFVGs(zoneLow, zoneHigh, atrVal, fvgOverlaps, fvgDist);

   int k = 0;
   features[k++] = (double)confirmAge;                                                   // confirm_age_minutes
   features[k++] = (rangeN > 0.0) ? rangeN / atrVal : 0.0;                             // range_atr_ratio
   features[k++] = favorableDist;                                                        // dist_to_favorable_liquidity
   features[k++] = adverseDist;                                                          // dist_to_adverse_liquidity
   features[k++] = (lastBOS > 0.0) ? MathAbs(entryPrice - lastBOS) / atrVal : 0.0;    // dist_to_last_bos
   features[k++] = (double)pdZone;                                                       // pd_entry_zone
   features[k++] = g_mlBarContextCache.hasLuxPD ? MathAbs(zoneMid - g_mlBarContextCache.eqPrice) / atrVal : 0.0; // pd_zone_mid_distance_from_eq
   features[k++] = (double)pdFav;                                                        // pd_is_favorable_for_bias
   features[k++] = LuxRangePositionCached(zoneMid);                                     // range_pos
   features[k++] = g_mlBarContextCache.velocity;                                         // velocity
   features[k++] = (double)alignVal;                                                     // alignment
   features[k++] = (atr20Val > 0.0) ? atr5Val / atr20Val : 1.0;                        // atr5_atr20_ratio
   features[k++] = (prevDayHighVal > 0.0) ? (prevDayHighVal - entryPrice) / atrVal : 0.0; // dist_to_prev_day_high
   features[k++] = (prevDayLowVal  > 0.0) ? (entryPrice - prevDayLowVal)  / atrVal : 0.0; // dist_to_prev_day_low
   features[k++] = (patternRange > 0.0) ? patternRange / atrVal : 0.0;                 // pattern_total_range_atr
   features[k++] = legAB / atrVal;                                                       // leg_ab_atr
   features[k++] = legBC / atrVal;                                                       // leg_bc_atr
   features[k++] = legCD / atrVal;                                                       // leg_cd_atr
   features[k++] = legDE / atrVal;                                                       // leg_de_atr
   features[k++] = legEF / atrVal;                                                       // leg_ef_atr
   features[k++] = SafeDivide(legBC, legAB);                                             // bc_retracement_of_ab
   features[k++] = SafeDivide(legDE, legCD);                                             // de_retracement_of_cd
   features[k++] = SafeDivide(legEF, legDE);                                             // ef_extension_vs_de
   features[k++] = zone.cachedConfirmDisplacement / atrVal;                              // confirm_displacement_atr
   features[k++] = SafeDivide(zoneSize, patternRange);                                   // zone_size_vs_pattern_range
   features[k++] = SafeDivide(zone.cachedPathAbsFA, totalLeg);                           // path_efficiency
   features[k++] = zone.cachedECandleRange / atrVal;                                     // e_candle_range_atr
   features[k++] = zone.cachedERejectionWick / atrVal;                                   // e_rejection_wick_atr
   features[k++] = (double)zone.cachedBarsAF;                                            // bars_a_to_f_m1
   features[k++] = sweepDepthBeyondC / atrVal;                                           // sweep_depth_beyond_c_atr
   features[k++] = SafeDivide(sweepDepthBeyondC, legCD);                                 // sweep_depth_beyond_c_ratio
   features[k++] = fBreakMarginVsD / atrVal;                                             // f_break_margin_vs_d_atr
   features[k++] = confirmToTouchExt;                                                    // confirm_to_touch_max_extension_atr
   features[k++] = confirmToTouchEff;                                                    // confirm_to_touch_pullback_efficiency
   features[k++] = (double)obOverlaps;                                                   // poi_overlaps_m5_ob
   features[k++] = obDist;                                                               // dist_to_nearest_m5_ob_atr
   features[k++] = (double)fvgOverlaps;                                                  // poi_overlaps_fvg
   features[k++] = fvgDist;                                                              // dist_to_nearest_fvg_atr
   features[k++] = volENorm;  // real_volume_e_atr_norm — JA COM LOG1P APLICADO
   features[k++] = volFNorm;  // real_volume_f_atr_norm — JA COM LOG1P APLICADO

   int barsAF_inf = zone.cachedBarsAF;
   features[k++] = (barsAF_inf > 0) ? SafeDivide((zone.pF - zone.pA) / atrVal, (double)barsAF_inf) : 0.0;  // m1_pattern_velocity
   features[k++] = (double)(((zone.bias == BULLISH && internalTrend == 1) ||
                              (zone.bias == BEARISH && internalTrend == -1)) ? 1 : 0);  // m1_bias_aligned_with_m5

   if(k != N_FEATS)
   {
      PrintFormat("SMC2 POI ERRO: BuildPOIInferenceFeatures gerou %d features, esperado %d", k, N_FEATS);
      return false;
   }
   return true;
}

#endif
