//+------------------------------------------------------------------+
//| POI_Strategy.mqh — esqueleto da logica BOS+CHoCH+CHoCH @ 50%      |
//|                                                                   |
//| Setup ALTA  : BOS bullish -> CHoCH bearish -> CHoCH bullish       |
//|               entrar BUY no toque do 50% da perna do CHoCH bull   |
//| Setup BAIXA : BOS bearish -> CHoCH bullish -> CHoCH bearish       |
//|               entrar SELL no toque do 50% da perna do CHoCH bear  |
//|                                                                   |
//| Inputs auxiliares (ainda exploratorios) declarados em POI.mq5:    |
//|   ChochLeg1MinPoints, ChochLeg1MaxPoints, ChochLeg2MinPoints     |
//|                                                                   |
//| Implementacao final do gatilho/entrada vira em iteracao seguinte. |
//+------------------------------------------------------------------+
#ifndef POI_STRATEGY_MQH
#define POI_STRATEGY_MQH

#include "POI_Config.mqh"
#include "POI_LuxAlgo.mqh"
#include "POI_Execution.mqh"

//═══════════════════════════════════════════════════════════════════
//  ESTADO DA ESTRATEGIA
//═══════════════════════════════════════════════════════════════════

#define POI_MAX_ZONES 32
#define POI_MAX_MITIGATED_ZONES 128
#define POI_MAX_CONSUMED_ZONES 256

#define POI_ZONE_VIS_PREFIX     "POI_ZONE_"
#define POI_ZONE_MIT_VIS_PREFIX "POI_MITZONE_"

POI_Zone   poi_zones[POI_MAX_ZONES];
int        poi_zoneCount = 0;
datetime   poi_lastTradeBarTime = 0;

POI_Zone   poi_mitigatedZones[POI_MAX_MITIGATED_ZONES];
datetime   poi_mitigatedRightTime[POI_MAX_MITIGATED_ZONES];
int        poi_mitigatedCount = 0;

POI_Zone   poi_consumedZones[POI_MAX_CONSUMED_ZONES];
int        poi_consumedCount = 0;

void POI_ClearStrategyVisualObjects(bool redraw = true);

void POI_StrategyReset()
{
   for(int i = 0; i < POI_MAX_ZONES; i++)
   {
      poi_zones[i].active          = false;
      poi_zones[i].id              = 0;
      poi_zones[i].bias            = 0;
      poi_zones[i].legHigh         = 0.0;
      poi_zones[i].legLow          = 0.0;
      poi_zones[i].midPrice        = 0.0;
      poi_zones[i].createdTime     = 0;
      poi_zones[i].visualStartTime = 0;
      poi_zones[i].createdBarIndex = -1;
      poi_zones[i].barsAlive       = 0;
      poi_zones[i].legSizePoints   = 0.0;
      poi_zones[i].poiSizePoints   = 0.0;
      poi_zones[i].sampled         = false;
      poi_zones[i].firstTouchSeen  = false;
      poi_zones[i].firstTouchTime  = 0;
      poi_zones[i].firstTouchBarTime = 0;
      poi_zones[i].tA = 0; poi_zones[i].pA = 0.0;
      poi_zones[i].tB = 0; poi_zones[i].pB = 0.0;
      poi_zones[i].tC = 0; poi_zones[i].pC = 0.0;
      poi_zones[i].tD = 0; poi_zones[i].pD = 0.0;
      poi_zones[i].tE = 0; poi_zones[i].pE = 0.0;
      poi_zones[i].tF = 0; poi_zones[i].pF = 0.0;
      poi_zones[i].eCandleHigh = 0.0;
      poi_zones[i].eCandleLow  = 0.0;
   }
   poi_zoneCount        = 0;
   poi_lastTradeBarTime = 0;

   for(int i = 0; i < POI_MAX_MITIGATED_ZONES; i++)
   {
      poi_mitigatedZones[i].active = false;
      poi_mitigatedRightTime[i] = 0;
   }
   poi_mitigatedCount = 0;

   for(int i = 0; i < POI_MAX_CONSUMED_ZONES; i++)
      poi_consumedZones[i].active = false;
   poi_consumedCount = 0;

   POI_ClearStrategyVisualObjects();
}

void POI_PushZone(const POI_Zone &z)
{
   int slot = -1;
   for(int i = 0; i < POI_MAX_ZONES; i++)
      if(!poi_zones[i].active) { slot = i; break; }

   if(slot < 0)
   {
      // Substitui a zona mais antiga (FIFO).
      int oldest = 0;
      for(int i = 1; i < POI_MAX_ZONES; i++)
         if(poi_zones[i].createdTime < poi_zones[oldest].createdTime) oldest = i;
      slot = oldest;
   }
   poi_zones[slot] = z;
   poi_zones[slot].active = true;
   if(poi_zoneCount < POI_MAX_ZONES) poi_zoneCount++;
}

//═══════════════════════════════════════════════════════════════════
//  VISUAL DAS ZONAS POI
//═══════════════════════════════════════════════════════════════════

string POI_ZoneVisualKey(const POI_Zone &z)
{
   return IntegerToString((long)z.createdTime) + "_" + (z.bias == POI_BULLISH ? "BUL" : "BEA");
}

bool POI_SameZoneKey(const POI_Zone &a, const POI_Zone &b)
{
   return (a.createdTime == b.createdTime &&
           a.bias == b.bias &&
           MathAbs(a.midPrice - b.midPrice) <= (_Point * 0.1));
}

bool POI_IsZoneMitigated(const POI_Zone &z)
{
   for(int i = 0; i < POI_MAX_MITIGATED_ZONES; i++)
      if(poi_mitigatedZones[i].active && POI_SameZoneKey(poi_mitigatedZones[i], z))
         return true;
   return false;
}

bool POI_IsZoneConsumed(const POI_Zone &z)
{
   for(int i = 0; i < POI_MAX_CONSUMED_ZONES; i++)
      if(poi_consumedZones[i].active && POI_SameZoneKey(poi_consumedZones[i], z))
         return true;
   return false;
}

void POI_RegisterConsumedZone(const POI_Zone &z)
{
   if(POI_IsZoneConsumed(z)) return;

   int slot = -1;
   for(int i = 0; i < POI_MAX_CONSUMED_ZONES; i++)
   {
      if(!poi_consumedZones[i].active)
      {
         slot = i;
         break;
      }
   }

   if(slot < 0)
   {
      slot = 0;
      for(int i = 1; i < POI_MAX_CONSUMED_ZONES; i++)
         if(poi_consumedZones[i].createdTime < poi_consumedZones[slot].createdTime)
            slot = i;
   }
   else if(poi_consumedCount < POI_MAX_CONSUMED_ZONES)
   {
      poi_consumedCount++;
   }

   poi_consumedZones[slot] = z;
   poi_consumedZones[slot].active = true;
}

void POI_DeleteZoneVisual(const POI_Zone &z, bool mitigated)
{
   if(!POI_CanDraw()) return;

   string prefix = mitigated ? POI_ZONE_MIT_VIS_PREFIX : POI_ZONE_VIS_PREFIX;
   string name = prefix + POI_ZoneVisualKey(z);
   ObjectDelete(0, name);
   ObjectDelete(0, name + "_MID");
   ObjectDelete(0, name + "_LBL");
}

void POI_ResolveVisualZoneBounds(const POI_Zone &z, double &rectHigh, double &rectLow)
{
   double legTop = MathMax(z.legHigh, z.legLow);
   double legBot = MathMin(z.legHigh, z.legLow);

   rectHigh = legTop;
   rectLow  = legBot;

   if(rectHigh <= rectLow)
   {
      rectHigh = z.midPrice + _Point;
      rectLow  = z.midPrice - _Point;
   }
}

datetime POI_ActiveZoneRightTime()
{
   int seconds = MathMax(1, PeriodSeconds(_Period));
   datetime base = (luxBarsCount > 0 && timeArr[0] > 0) ? timeArr[0] : TimeCurrent();
   return base + (datetime)(seconds * 20);
}

datetime POI_CurrentCandleCloseTime()
{
   int seconds = MathMax(1, PeriodSeconds(POI_DETECTION_TIMEFRAME));
   datetime barOpen = iTime(_Symbol, POI_DETECTION_TIMEFRAME, 0);
   if(barOpen <= 0 && luxBarsCount > 0)
      barOpen = timeArr[0];
   if(barOpen <= 0)
      barOpen = TimeCurrent();
   return barOpen + (datetime)seconds;
}

bool POI_ZoneMitigatedAt100(const POI_Zone &z, const double high, const double low)
{
   double rectHigh, rectLow;
   POI_ResolveVisualZoneBounds(z, rectHigh, rectLow);

   if(z.bias == POI_BULLISH)
      return (low < rectLow);
   if(z.bias == POI_BEARISH)
      return (high > rectHigh);
   return false;
}

bool POI_FindHistoricalMitigationTime(const POI_Zone &z, datetime &mitigationTime)
{
   mitigationTime = 0;
   if(luxBarsCount <= 0)
      return false;

   int start = z.createdBarIndex - 1;
   if(start < 0)
      return false;
   if(start >= luxBarsCount)
      start = luxBarsCount - 1;

   int seconds = MathMax(1, PeriodSeconds(POI_DETECTION_TIMEFRAME));
   for(int i = start; i >= 0; i--)
   {
      if(timeArr[i] <= z.createdTime)
         continue;

      if(POI_ZoneMitigatedAt100(z, rawHighs[i], rawLows[i]))
      {
         mitigationTime = timeArr[i] + (datetime)seconds;
         return true;
      }
   }

   return false;
}

bool POI_SameDate(const datetime a, const datetime b)
{
   MqlDateTime da, db;
   TimeToStruct(a, da);
   TimeToStruct(b, db);

   return (da.year == db.year && da.mon == db.mon && da.day == db.day);
}

bool POI_ResolveFirstChochLegRange(const POI_StructureEvent &chochEvent,
                                   double &legHigh, double &legLow,
                                   datetime &visualStartTime)
{
   legHigh = -DBL_MAX;
   legLow = DBL_MAX;
   visualStartTime = chochEvent.pivotTime;

   int from = MathMin(chochEvent.pivotBarIndex, chochEvent.breakBarIndex);
   int to   = MathMax(chochEvent.pivotBarIndex, chochEvent.breakBarIndex);
   if(from < 0 || to < 0 || luxBarsCount <= 0)
      return false;

   from = MathMax(0, from);
   to   = MathMin(luxBarsCount - 1, to);
   if(to < from)
      return false;

   int highIdx = -1;
   int lowIdx = -1;
   for(int b = from; b <= to; b++)
   {
      if(rawHighs[b] > legHigh)
      {
         legHigh = rawHighs[b];
         highIdx = b;
      }
      if(rawLows[b] < legLow)
      {
         legLow = rawLows[b];
         lowIdx = b;
      }
   }

   if(highIdx < 0 || lowIdx < 0 || legHigh <= legLow)
      return false;

   int startIdx = chochEvent.bullish ? lowIdx : highIdx;
   if(startIdx >= 0 && startIdx < luxBarsCount)
      visualStartTime = timeArr[startIdx];

   return true;
}

double POI_EventBreakPrice(const POI_StructureEvent &ev)
{
   if(ev.breakBarIndex >= 0 && ev.breakBarIndex < luxBarsCount)
      return rawCloses[ev.breakBarIndex];
   return ev.level;
}

void POI_FillDatasetPatternPoints(POI_Zone &z,
                                  const POI_StructureEvent &bosEvent,
                                  const POI_StructureEvent &choch1Event,
                                  const POI_StructureEvent &choch2Event)
{
   z.tA = bosEvent.pivotTime;
   z.pA = bosEvent.level;
   z.tB = bosEvent.breakTime;
   z.pB = POI_EventBreakPrice(bosEvent);

   z.tC = choch1Event.pivotTime;
   z.pC = choch1Event.level;
   z.tD = choch1Event.breakTime;
   z.pD = POI_EventBreakPrice(choch1Event);

   z.tE = choch2Event.pivotTime;
   z.pE = choch2Event.level;
   z.tF = choch2Event.breakTime;
   z.pF = POI_EventBreakPrice(choch2Event);

   z.eCandleHigh = MathMax(z.legHigh, z.legLow);
   z.eCandleLow  = MathMin(z.legHigh, z.legLow);
}

void POI_DrawSingleZoneVisual(const POI_Zone &z, bool mitigated, datetime rightTime)
{
   if(!POI_CanDraw()) return;
   if(!ShowPOIsOnChart) return;
   if(mitigated && !ShowMitigatedPOIs) return;

   double rectHigh, rectLow;
   POI_ResolveVisualZoneBounds(z, rectHigh, rectLow);

   string prefix = mitigated ? POI_ZONE_MIT_VIS_PREFIX : POI_ZONE_VIS_PREFIX;
   string name = prefix + POI_ZoneVisualKey(z);
   string midName = name + "_MID";
   string labelName = name + "_LBL";

   datetime leftTime = (z.visualStartTime > 0 ? z.visualStartTime : z.createdTime);
   if(leftTime <= 0) leftTime = TimeCurrent();
   if(rightTime <= leftTime)
      rightTime = leftTime + (datetime)(MathMax(1, PeriodSeconds(_Period)) * 20);

   color rawColor = (z.bias == POI_BULLISH) ? POIBullZoneColor : POIBearZoneColor;
   if(mitigated)
      rawColor = POI_ColorFromRGB(POI_ColorComponent(rawColor, 0) / 3,
                                  POI_ColorComponent(rawColor, 1) / 3,
                                  POI_ColorComponent(rawColor, 2) / 3);
   color finalColor = POI_BlendWithBackground(rawColor, POIBlendAlpha);

   ObjectDelete(0, name);
   ObjectDelete(0, midName);
   ObjectDelete(0, labelName);

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, leftTime, rectHigh, rightTime, rectLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR, finalColor);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   color midLineColor = mitigated ? clrGray : (z.bias == POI_BULLISH ? POIBullZoneColor : POIBearZoneColor);
   ObjectCreate(0, midName, OBJ_TREND, 0, leftTime, z.midPrice, rightTime, z.midPrice);
   ObjectSetInteger(0, midName, OBJPROP_COLOR, midLineColor);
   ObjectSetInteger(0, midName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, midName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, midName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, midName, OBJPROP_BACK, false);

   ObjectCreate(0, labelName, OBJ_TEXT, 0, leftTime, (rectHigh + rectLow) * 0.5);
   ObjectSetString(0, labelName, OBJPROP_TEXT, z.bias == POI_BULLISH ? "POI BUY" : "POI SELL");
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, mitigated ? clrGray : clrWhite);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
}

void POI_DrawMitigatedZones()
{
   if(!POI_CanDraw()) return;

   if(!ShowPOIsOnChart || !ShowMitigatedPOIs)
   {
      POI_DeletePrefixedObjects(POI_ZONE_MIT_VIS_PREFIX);
      return;
   }

   for(int i = 0; i < POI_MAX_MITIGATED_ZONES; i++)
      if(poi_mitigatedZones[i].active)
         POI_DrawSingleZoneVisual(poi_mitigatedZones[i], true, poi_mitigatedRightTime[i]);
}

void POI_RegisterMitigatedZone(const POI_Zone &z, datetime rightTime)
{
   int slot = -1;
   for(int i = 0; i < POI_MAX_MITIGATED_ZONES; i++)
   {
      if(poi_mitigatedZones[i].active && POI_SameZoneKey(poi_mitigatedZones[i], z))
      {
         slot = i;
         break;
      }
   }

   if(slot < 0)
      for(int i = 0; i < POI_MAX_MITIGATED_ZONES; i++)
         if(!poi_mitigatedZones[i].active)
         {
            slot = i;
            break;
         }

   if(slot < 0)
   {
      slot = 0;
      for(int i = 1; i < POI_MAX_MITIGATED_ZONES; i++)
         if(poi_mitigatedZones[i].createdTime < poi_mitigatedZones[slot].createdTime)
            slot = i;
   }

   if(poi_mitigatedZones[slot].active)
      POI_DeleteZoneVisual(poi_mitigatedZones[slot], true);
   else if(poi_mitigatedCount < POI_MAX_MITIGATED_ZONES)
      poi_mitigatedCount++;

   poi_mitigatedZones[slot] = z;
   poi_mitigatedZones[slot].active = true;
   poi_mitigatedRightTime[slot] = rightTime;

   POI_DeleteZoneVisual(z, false);
   if(!ShowPOIsOnChart || !ShowMitigatedPOIs)
      POI_DeleteZoneVisual(poi_mitigatedZones[slot], true);

   if(ShowPOIsOnChart && ShowMitigatedPOIs)
      POI_DrawSingleZoneVisual(poi_mitigatedZones[slot], true, poi_mitigatedRightTime[slot]);
}

void POI_DrawActiveZones()
{
   if(!POI_CanDraw()) return;

   POI_DeletePrefixedObjects(POI_ZONE_VIS_PREFIX);
   if(!ShowPOIsOnChart || !ShowMitigatedPOIs)
      POI_DeletePrefixedObjects(POI_ZONE_MIT_VIS_PREFIX);

   if(!ShowPOIsOnChart)
   {
      ChartRedraw(0);
      return;
   }

   datetime rightTime = POI_ActiveZoneRightTime();
   for(int i = 0; i < POI_MAX_ZONES; i++)
      if(poi_zones[i].active)
         POI_DrawSingleZoneVisual(poi_zones[i], false, rightTime);

   POI_DrawMitigatedZones();

   ChartRedraw(0);
}

void POI_ClearStrategyVisualObjects(bool redraw)
{
   if(!POI_CanDraw()) return;
   POI_DeletePrefixedObjects(POI_ZONE_VIS_PREFIX);
   POI_DeletePrefixedObjects(POI_ZONE_MIT_VIS_PREFIX);
   if(redraw) ChartRedraw(0);
}

//═══════════════════════════════════════════════════════════════════
//  IDENTIFICACAO DA SEQUENCIA  BOS -> CHoCH -> CHoCH
//═══════════════════════════════════════════════════════════════════
//
// Estrategia opera nos eventos INTERNAL: o POI e um padrao curto/micro.
// Para cada sequencia detectada, criamos uma POI_Zone que representa a
// perna do ultimo CHoCH (a perna a favor).
//
// Detalhes:
//   - LongSetup  = sequencia [BOS bull, CHoCH bear, CHoCH bull]
//                  zona: range high/low da perna que gerou o primeiro CHoCH.
//   - ShortSetup = sequencia [BOS bear, CHoCH bull, CHoCH bear]
//                  zona: range high/low da perna que gerou o primeiro CHoCH.
//
// A heuristica de tamanho minimo/maximo do POI e tamanho minimo da perna
// de confirmacao (ChochLeg2) e aplicada como filtro.

void POI_BuildZonesFromEvents()
{
   POI_Zone previousZones[POI_MAX_ZONES];
   for(int i = 0; i < POI_MAX_ZONES; i++)
      previousZones[i] = poi_zones[i];

   // Limpa zonas antes de reconstruir (mantem barsAlive coerente apenas
   // quando reaproveitamos via match — aqui estamos reescrevendo a partir
   // do snapshot mais recente do lux engine).
   for(int i = 0; i < POI_MAX_ZONES; i++)
   {
      poi_zones[i].active = false;
   }
   poi_zoneCount = 0;

   int n = POI_LuxEventCount();
   if(n < 3) return;

   POI_StructureEvent internalEvents[POI_MAX_EVENTS];
   int internalCount = 0;
   for(int i = 0; i < n && internalCount < POI_MAX_EVENTS; i++)
   {
      POI_StructureEvent ev;
      if(!POI_LuxGetEvent(i, ev)) continue;
      if(!ev.internal) continue;
      internalEvents[internalCount++] = ev;
   }

   if(internalCount < 3)
   {
      if(DebugMode)
         PrintFormat("POI DBG | zonas=0 eventosLux=%d eventosInternal=%d: internal insuficiente para BOS->CHoCH->CHoCH",
                     n, internalCount);
      return;
   }

   int builtZones = 0;

   for(int i = 0; i + 2 < internalCount; i++)
   {
      POI_StructureEvent e1 = internalEvents[i];
      POI_StructureEvent e2 = internalEvents[i + 1];
      POI_StructureEvent e3 = internalEvents[i + 2];

      // ----- Setup LONG: BOS bull -> CHoCH bear -> CHoCH bull -----
      bool longPattern = (!e1.choch &&  e1.bullish) &&
                         ( e2.choch && !e2.bullish) &&
                         ( e3.choch &&  e3.bullish);

      // ----- Setup SHORT: BOS bear -> CHoCH bull -> CHoCH bear ----
      bool shortPattern = (!e1.choch && !e1.bullish) &&
                          ( e2.choch &&  e2.bullish) &&
                          ( e3.choch && !e3.bullish);

      if(!longPattern && !shortPattern) continue;

      if(!POI_SameDate(e1.breakTime, e2.breakTime) ||
         !POI_SameDate(e2.breakTime, e3.breakTime))
         continue;

      int barsBosToChoch1 = (int)MathAbs((double)(e1.breakBarIndex - e2.breakBarIndex));
      int barsChoch1ToChoch2 = (int)MathAbs((double)(e2.breakBarIndex - e3.breakBarIndex));
      if(BosToChoch1MaxBars > 0 && barsBosToChoch1 > BosToChoch1MaxBars) continue;
      if(Choch1ToChoch2MaxBars > 0 && barsChoch1ToChoch2 > Choch1ToChoch2MaxBars) continue;

      POI_Zone z;
      z.active          = true;
      z.id              = 0;
      z.bias            = longPattern ? POI_BULLISH : POI_BEARISH;
      z.createdTime     = e3.breakTime;
      z.createdBarIndex = e3.breakBarIndex;
      z.barsAlive       = 0;
      z.sampled         = false;
      z.firstTouchSeen  = false;
      z.firstTouchTime  = 0;
      z.firstTouchBarTime = 0;

      // A zona fica na perna que gerou o primeiro CHoCH (e2), mas so nasce
      // depois da confirmacao do segundo CHoCH (e3).
      if(!POI_ResolveFirstChochLegRange(e2, z.legHigh, z.legLow, z.visualStartTime))
         continue;

      double legSize = MathAbs(z.legHigh - z.legLow);
      if(legSize <= 0.0) continue;

      z.midPrice      = (z.legHigh + z.legLow) * 0.5;
      z.legSizePoints = legSize / _Point;
      z.poiSizePoints = z.legSizePoints;
      long zoneKey = ((long)z.createdTime % 1000003) * 31 + (long)MathRound(z.midPrice / _Point) * 17 + (z.bias == POI_BULLISH ? 1 : 2);
      if(zoneKey < 0) zoneKey = -zoneKey;
      z.id = (int)(zoneKey % 2147480000);
      POI_FillDatasetPatternPoints(z, e1, e2, e3);
      for(int prev = 0; prev < POI_MAX_ZONES; prev++)
      {
         if(!previousZones[prev].active) continue;
         if(!POI_SameZoneKey(previousZones[prev], z)) continue;

         z.sampled = previousZones[prev].sampled;
         z.firstTouchSeen = previousZones[prev].firstTouchSeen;
         z.firstTouchTime = previousZones[prev].firstTouchTime;
         z.firstTouchBarTime = previousZones[prev].firstTouchBarTime;
         break;
      }

      // Filtros de tamanho minimo das pernas — comuns aos dois lados.
      if(ChochLeg1MinPoints > 0 || ChochLeg1MaxPoints > 0 || ChochLeg2MinPoints > 0)
      {
         double leg1Size = z.legSizePoints;                  // perna do primeiro CHoCH
         double leg2Size = MathAbs(e3.level - e2.level) / _Point; // perna de confirmacao
         if(ChochLeg1MinPoints > 0 && leg1Size < ChochLeg1MinPoints) continue;
         if(ChochLeg1MaxPoints > 0 && leg1Size > ChochLeg1MaxPoints) continue;
         if(ChochLeg2MinPoints > 0 && leg2Size < ChochLeg2MinPoints) continue;
      }

      if(POI_IsZoneMitigated(z)) continue;

      datetime mitigationTime = 0;
      if(POI_FindHistoricalMitigationTime(z, mitigationTime))
      {
         POI_RegisterMitigatedZone(z, mitigationTime);
         continue;
      }

      POI_PushZone(z);
      builtZones++;
   }

   if(DebugMode)
      PrintFormat("POI DBG | zonas=%d eventosLux=%d eventosInternal=%d", builtZones, n, internalCount);
}

//═══════════════════════════════════════════════════════════════════
//  EXPIRACAO / INVALIDACAO DE ZONAS
//═══════════════════════════════════════════════════════════════════

void POI_ExpireZones(double bid, double ask)
{
   bool changed = false;

   for(int i = 0; i < POI_MAX_ZONES; i++)
   {
      if(!poi_zones[i].active) continue;

      // Mitiga somente quando o preco atravessa 100% da caixa do POI.
      if(POI_ZoneMitigatedAt100(poi_zones[i], ask, bid))
      {
         POI_RegisterMitigatedZone(poi_zones[i], POI_CurrentCandleCloseTime());
         poi_zones[i].active = false;
         poi_zoneCount--;
         changed = true;
         continue;
      }
   }

   if(changed)
      POI_DrawActiveZones();
}

//═══════════════════════════════════════════════════════════════════
//  GATILHO DE ENTRADA — toque do 50% da perna
//═══════════════════════════════════════════════════════════════════
//
// Implementacao default: usa LIMIT no preco midPrice quando a entrada
// pendente esta liberada via UseLimitOrder. Se UseLimitOrder=false,
// executa market no toque do 50% ou no toque da caixa do POI conforme
// MarketEntryOnPOITouch. SL/TP definidos abaixo.
//
// SL bullish: legLow  - StopOffsetPoints * _Point
// SL bearish: legHigh + StopOffsetPoints * _Point
// TP via TPMultiplier: entrada-stop, modo antigo LEG_BASE, ou tamanho do POI se habilitado.

void POI_TryEnter(double ask, double bid)
{
   if(POI_HasActiveExposureByMagic()) return;
   if(OneTradePerBar && poi_lastTradeBarTime == timeArr[0]) return;

   for(int i = 0; i < POI_MAX_ZONES; i++)
   {
      if(!poi_zones[i].active) continue;
      if(POI_IsZoneConsumed(poi_zones[i])) continue;
      if(POI_HasPendingForZone(poi_zones[i].createdTime, poi_zones[i].bias)) continue;

      double mid     = poi_zones[i].midPrice;
      double sl      = 0.0;
      double legBase = 0.0;
      string cmt;
      double rectHigh, rectLow;
      POI_ResolveVisualZoneBounds(poi_zones[i], rectHigh, rectLow);
      double poiSizePrice = MathAbs(rectHigh - rectLow);
      if(poiSizePrice <= 0.0) continue;

      if(poi_zones[i].bias == POI_BULLISH)
      {
         sl      = poi_zones[i].legLow  - StopOffsetPoints * _Point;
         legBase = poi_zones[i].legLow;
         cmt     = "POI_LONG_50";

         if(UseLimitOrder)
         {
            if(POI_PlaceBuyLimit(mid, sl, legBase, poiSizePrice,
                                 poi_zones[i].createdTime, poi_zones[i].bias,
                                 TPMultiplier, cmt))
            {
               POI_RegisterConsumedZone(poi_zones[i]);
               poi_lastTradeBarTime = timeArr[0];
               return;
            }
         }
         else
         {
            bool touched = MarketEntryOnPOITouch
                           ? (ask <= rectHigh && ask >= rectLow)
                           : (ask <= mid + 0.5 * _Point && ask >= mid - 0.5 * _Point);
            if(touched)
            {
               string entryComment = MarketEntryOnPOITouch ? "POI_LONG_TOUCH" : cmt;
               if(POI_BuyWithRetry(sl, legBase, poiSizePrice, TPMultiplier, entryComment))
               {
                  POI_RegisterConsumedZone(poi_zones[i]);
                  poi_lastTradeBarTime = timeArr[0];
                  return;
               }
            }
         }
      }
      else if(poi_zones[i].bias == POI_BEARISH)
      {
         sl      = poi_zones[i].legHigh + StopOffsetPoints * _Point;
         legBase = poi_zones[i].legHigh;
         cmt     = "POI_SHORT_50";

         if(UseLimitOrder)
         {
            if(POI_PlaceSellLimit(mid, sl, legBase, poiSizePrice,
                                  poi_zones[i].createdTime, poi_zones[i].bias,
                                  TPMultiplier, cmt))
            {
               POI_RegisterConsumedZone(poi_zones[i]);
               poi_lastTradeBarTime = timeArr[0];
               return;
            }
         }
         else
         {
            bool touched = MarketEntryOnPOITouch
                           ? (bid >= rectLow && bid <= rectHigh)
                           : (bid >= mid - 0.5 * _Point && bid <= mid + 0.5 * _Point);
            if(touched)
            {
               string entryComment = MarketEntryOnPOITouch ? "POI_SHORT_TOUCH" : cmt;
               if(POI_SellWithRetry(sl, legBase, poiSizePrice, TPMultiplier, entryComment))
               {
                  POI_RegisterConsumedZone(poi_zones[i]);
                  poi_lastTradeBarTime = timeArr[0];
                  return;
               }
            }
         }
      }

      if(POI_HasActiveExposureByMagic()) return;
   }
}

//═══════════════════════════════════════════════════════════════════
//  ENTRY POINT por barra/tick
//═══════════════════════════════════════════════════════════════════

void POI_StrategyOnNewBar(bool incrementPendingBars = true)
{
   // Reconstroi snapshot de zonas a cada nova barra a partir do lux engine.
   POI_BuildZonesFromEvents();
   for(int i = 0; i < POI_MAX_ZONES; i++)
      if(poi_zones[i].active) poi_zones[i].barsAlive++;
   if(incrementPendingBars)
      POI_IncrementPendingBars();
   POI_DrawActiveZones();
}

void POI_StrategyOnTick(double ask, double bid)
{
   POI_ExpireZones(bid, ask);
   if(!EnableTrading) return;
   if(poi_dailyLossLimitHit || poi_closedThisSession) return;
   if(!POI_IsWithinTradingHours()) return;
   POI_TryEnter(ask, bid);
}

#endif
