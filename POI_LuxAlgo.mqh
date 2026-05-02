//+------------------------------------------------------------------+
//| POI_LuxAlgo.mqh — Pine-faithful SMC core (BOS / CHoCH)      |
//| Replica do LUXALGO_100IDENTICO.mq5 embarcada no EA POI.          |
//| Self-contained: nao referencia o arquivo do indicador.           |
//+------------------------------------------------------------------+
#ifndef POI_LUXALGO_MQH
#define POI_LUXALGO_MQH

#include "POI_Config.mqh"

#define POI_DETECTION_TIMEFRAME PERIOD_M1

//═══════════════════════════════════════════════════════════════════
//  ESTADO DO CALCULO LUX (privado deste modulo)
//═══════════════════════════════════════════════════════════════════

POI_Pivot          luxSwingHigh;
POI_Pivot          luxSwingLow;
POI_Pivot          luxInternalHigh;
POI_Pivot          luxInternalLow;

POI_StructureEvent luxEvents[POI_MAX_EVENTS];
int                luxEventCount     = 0;

int                luxSwingTrend      = 0;
int                luxInternalTrend   = 0;
int                luxSwingLastLeg    = -1;
int                luxInternalLastLeg = -1;

int                luxBarsCount      = 0;

double             rawHighs[POI_MAX_BARS];
double             rawLows[POI_MAX_BARS];
double             rawOpens[POI_MAX_BARS];
double             rawCloses[POI_MAX_BARS];
datetime           timeArr[POI_MAX_BARS];

//═══════════════════════════════════════════════════════════════════
//  RESET / HELPERS INTERNOS
//═══════════════════════════════════════════════════════════════════

void POI_ResetPivot(POI_Pivot &p)
{
   p.currentLevel = 0.0;
   p.lastLevel    = 0.0;
   p.crossed      = false;
   p.barTime      = 0;
   p.barIndex     = -1;
}

void POI_ResetLuxState()
{
   POI_ResetPivot(luxSwingHigh);
   POI_ResetPivot(luxSwingLow);
   POI_ResetPivot(luxInternalHigh);
   POI_ResetPivot(luxInternalLow);
   luxSwingTrend      = 0;
   luxInternalTrend   = 0;
   luxSwingLastLeg    = -1;
   luxInternalLastLeg = -1;
   luxEventCount      = 0;
}

int POI_HighestRecent(const double &arr[], int startIndex, int count)
{
   int    best    = startIndex;
   double bestVal = arr[startIndex];
   for(int i = startIndex + 1; i < startIndex + count; i++)
   {
      if(arr[i] > bestVal)
      {
         bestVal = arr[i];
         best    = i;
      }
   }
   return best;
}

int POI_LowestRecent(const double &arr[], int startIndex, int count)
{
   int    best    = startIndex;
   double bestVal = arr[startIndex];
   for(int i = startIndex + 1; i < startIndex + count; i++)
   {
      if(arr[i] < bestVal)
      {
         bestVal = arr[i];
         best    = i;
      }
   }
   return best;
}

int POI_LegAt(const double &high[], const double &low[], int barsCount, int currentIndex, int size)
{
   int candidate = currentIndex + size;
   if(candidate >= barsCount || currentIndex + size - 1 >= barsCount)
      return -1;

   int recentHighIndex = POI_HighestRecent(high, currentIndex, size);
   int recentLowIndex  = POI_LowestRecent(low, currentIndex, size);

   bool newLegHigh = high[candidate] > high[recentHighIndex];
   bool newLegLow  = low[candidate]  < low[recentLowIndex];

   if(newLegHigh) return POI_BEARISH_LEG;
   if(newLegLow)  return POI_BULLISH_LEG;
   return -1;
}

void POI_RecordEvent(const POI_Pivot &p, datetime breakTime, int breakBarIndex,
                     bool bullish, bool internal, bool choch)
{
   if(luxEventCount >= POI_MAX_EVENTS) return;
   luxEvents[luxEventCount].pivotTime     = p.barTime;
   luxEvents[luxEventCount].breakTime     = breakTime;
   luxEvents[luxEventCount].level         = p.currentLevel;
   luxEvents[luxEventCount].bullish       = bullish;
   luxEvents[luxEventCount].internal      = internal;
   luxEvents[luxEventCount].choch         = choch;
   luxEvents[luxEventCount].pivotBarIndex = p.barIndex;
   luxEvents[luxEventCount].breakBarIndex = breakBarIndex;
   luxEventCount++;
}

void POI_UpdateStructurePivot(POI_Pivot &p, double level, datetime barTime, int barIndex)
{
   p.lastLevel    = p.currentLevel;
   p.currentLevel = level;
   p.crossed      = false;
   p.barTime      = barTime;
   p.barIndex     = barIndex;
}

void POI_ProcessStructurePivot(bool internal, int barsCount, int currentIndex, int size)
{
   int leg = POI_LegAt(rawHighs, rawLows, barsCount, currentIndex, size);
   if(leg == -1) return;

   int pivotIndex = currentIndex + size;

   if(internal)
   {
      if(leg != luxInternalLastLeg)
      {
         if(leg == POI_BULLISH_LEG)
            POI_UpdateStructurePivot(luxInternalLow, rawLows[pivotIndex], timeArr[pivotIndex], pivotIndex);
         else
            POI_UpdateStructurePivot(luxInternalHigh, rawHighs[pivotIndex], timeArr[pivotIndex], pivotIndex);
      }
      luxInternalLastLeg = leg;
   }
   else
   {
      if(leg != luxSwingLastLeg)
      {
         if(leg == POI_BULLISH_LEG)
            POI_UpdateStructurePivot(luxSwingLow, rawLows[pivotIndex], timeArr[pivotIndex], pivotIndex);
         else
            POI_UpdateStructurePivot(luxSwingHigh, rawHighs[pivotIndex], timeArr[pivotIndex], pivotIndex);
      }
      luxSwingLastLeg = leg;
   }
}

bool POI_BullishConfluence(int index)
{
   double upperWick    = rawHighs[index] - MathMax(rawCloses[index], rawOpens[index]);
   double lowerMeasure = MathMin(rawCloses[index], rawOpens[index] - rawLows[index]);
   return upperWick > lowerMeasure;
}

bool POI_BearishConfluence(int index)
{
   double upperWick    = rawHighs[index] - MathMax(rawCloses[index], rawOpens[index]);
   double lowerMeasure = MathMin(rawCloses[index], rawOpens[index] - rawLows[index]);
   return upperWick < lowerMeasure;
}

void POI_ProcessDisplayStructure(bool internal, int index, bool internalFilterConfluence)
{
   bool bullishBar = !internalFilterConfluence || !internal || POI_BullishConfluence(index);
   bool bearishBar = !internalFilterConfluence || !internal || POI_BearishConfluence(index);

   if(internal)
   {
      if(luxInternalHigh.currentLevel > 0.0)
      {
         bool extraCondition = (luxInternalHigh.currentLevel != luxSwingHigh.currentLevel) && bullishBar;
         bool crossed        = rawCloses[index]   > luxInternalHigh.currentLevel
                            && rawCloses[index+1] <= luxInternalHigh.currentLevel;
         if(crossed && !luxInternalHigh.crossed && extraCondition)
         {
            bool choch = (luxInternalTrend == POI_BEARISH);
            luxInternalHigh.crossed = true;
            luxInternalTrend        = POI_BULLISH;
            POI_RecordEvent(luxInternalHigh, timeArr[index], index, true, true, choch);
         }
      }

      if(luxInternalLow.currentLevel > 0.0)
      {
         bool extraCondition = (luxInternalLow.currentLevel != luxSwingLow.currentLevel) && bearishBar;
         bool crossed        = rawCloses[index]   < luxInternalLow.currentLevel
                            && rawCloses[index+1] >= luxInternalLow.currentLevel;
         if(crossed && !luxInternalLow.crossed && extraCondition)
         {
            bool choch = (luxInternalTrend == POI_BULLISH);
            luxInternalLow.crossed = true;
            luxInternalTrend       = POI_BEARISH;
            POI_RecordEvent(luxInternalLow, timeArr[index], index, false, true, choch);
         }
      }
   }
   else
   {
      if(luxSwingHigh.currentLevel > 0.0)
      {
         bool crossed = rawCloses[index]   > luxSwingHigh.currentLevel
                     && rawCloses[index+1] <= luxSwingHigh.currentLevel;
         if(crossed && !luxSwingHigh.crossed)
         {
            bool choch = (luxSwingTrend == POI_BEARISH);
            luxSwingHigh.crossed = true;
            luxSwingTrend        = POI_BULLISH;
            POI_RecordEvent(luxSwingHigh, timeArr[index], index, true, false, choch);
         }
      }

      if(luxSwingLow.currentLevel > 0.0)
      {
         bool crossed = rawCloses[index]   < luxSwingLow.currentLevel
                     && rawCloses[index+1] >= luxSwingLow.currentLevel;
         if(crossed && !luxSwingLow.crossed)
         {
            bool choch = (luxSwingTrend == POI_BULLISH);
            luxSwingLow.crossed = true;
            luxSwingTrend       = POI_BEARISH;
            POI_RecordEvent(luxSwingLow, timeArr[index], index, false, false, choch);
         }
      }
   }
}

//═══════════════════════════════════════════════════════════════════
//  VISUAL HELPERS — estrutura BOS/CHoCH
//═══════════════════════════════════════════════════════════════════

#define POI_LUX_VIS_PREFIX "POI_VIS_"

bool POI_CanDraw()
{
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return false;
   return true;
}

void POI_DeletePrefixedObjects(const string prefix)
{
   if(prefix == "") return;
   ObjectsDeleteAll(0, prefix);
}

int POI_ColorComponent(color c, int component)
{
   if(component == 0) return (int)((c >> 16) & 0xFF);
   if(component == 1) return (int)((c >>  8) & 0xFF);
   return                    (int)( c        & 0xFF);
}

color POI_ColorFromRGB(int r, int g, int b)
{
   r = MathMax(0, MathMin(255, r));
   g = MathMax(0, MathMin(255, g));
   b = MathMax(0, MathMin(255, b));
   return (color)((r << 16) | (g << 8) | b);
}

color POI_BlendWithBackground(color obColor, int alpha)
{
   int a = MathMax(0, MathMin(255, alpha));
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int r = (POI_ColorComponent(obColor, 0) * a + POI_ColorComponent(bg, 0) * (255 - a)) / 255;
   int g = (POI_ColorComponent(obColor, 1) * a + POI_ColorComponent(bg, 1) * (255 - a)) / 255;
   int b = (POI_ColorComponent(obColor, 2) * a + POI_ColorComponent(bg, 2) * (255 - a)) / 255;
   return POI_ColorFromRGB(r, g, b);
}

void POI_DrawStructureEvent(int index)
{
   if(!POI_CanDraw()) return;
   if(index < 0 || index >= luxEventCount) return;

   POI_StructureEvent ev = luxEvents[index];
   string base = POI_LUX_VIS_PREFIX + "STR_" + IntegerToString(index);
   color c = ev.internal ? (ev.bullish ? InternalBullColor : InternalBearColor)
                         : (ev.bullish ? SwingBullColor    : SwingBearColor);
   ENUM_LINE_STYLE style = ev.internal ? STYLE_DASH : STYLE_SOLID;
   string text = ev.choch ? "CHoCH" : "BOS";

   ObjectCreate(0, base + "_L", OBJ_TREND, 0, ev.pivotTime, ev.level, ev.breakTime, ev.level);
   ObjectSetInteger(0, base + "_L", OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, base + "_L", OBJPROP_COLOR, c);
   ObjectSetInteger(0, base + "_L", OBJPROP_STYLE, style);
   ObjectSetInteger(0, base + "_L", OBJPROP_WIDTH, ev.internal ? 1 : 2);

   datetime mid = (datetime)((long)ev.pivotTime + ((long)ev.breakTime - (long)ev.pivotTime) / 2);
   ObjectCreate(0, base + "_T", OBJ_TEXT, 0, mid, ev.level);
   ObjectSetString(0,  base + "_T", OBJPROP_TEXT, text);
   ObjectSetInteger(0, base + "_T", OBJPROP_COLOR, c);
   ObjectSetInteger(0, base + "_T", OBJPROP_FONTSIZE, ev.internal ? 8 : 10);
}

void POI_DrawLuxVisuals(datetime rightTime)
{
   if(!POI_CanDraw()) return;

   POI_DeletePrefixedObjects(POI_LUX_VIS_PREFIX);

   if(ShowInternalStructure || ShowSwingStructure)
   {
      for(int i = 0; i < luxEventCount; i++)
      {
         if((luxEvents[i].internal && ShowInternalStructure) ||
            (!luxEvents[i].internal && ShowSwingStructure))
            POI_DrawStructureEvent(i);
      }
   }

   ChartRedraw(0);
}

void POI_ClearLuxVisualObjects(bool redraw = true)
{
   if(!POI_CanDraw()) return;
   POI_DeletePrefixedObjects(POI_LUX_VIS_PREFIX);
   if(redraw) ChartRedraw(0);
}

//═══════════════════════════════════════════════════════════════════
//  CICLO PUBLICO — INIT / DEINIT / RUN
//═══════════════════════════════════════════════════════════════════

bool POI_LuxAlgoInit()
{
   POI_ResetLuxState();
   return true;
}

void POI_LuxAlgoDeinit()
{
}

// Recalcula todo o estado lux (BOS/CHoCH) a partir do M1 do simbolo.
// Parametros chamam o mesmo nome do indicador para fidelidade.
bool POI_LuxAlgoRun(int swingLength, int internalLength,
                    bool internalFilterConfluence)
{
   int rates_total = Bars(_Symbol, POI_DETECTION_TIMEFRAME);
   if(rates_total < MathMax(swingLength, internalLength) + 3) return false;

   double openTmp[],  highTmp[],  lowTmp[],  closeTmp[];
   datetime timeTmp[];

   ArraySetAsSeries(openTmp,  true);
   ArraySetAsSeries(highTmp,  true);
   ArraySetAsSeries(lowTmp,   true);
   ArraySetAsSeries(closeTmp, true);
   ArraySetAsSeries(timeTmp,  true);

   int barsCount = MathMin(rates_total, POI_MAX_BARS);
   if(CopyOpen (_Symbol, POI_DETECTION_TIMEFRAME, 0, barsCount, openTmp)  <= 0) return false;
   if(CopyHigh (_Symbol, POI_DETECTION_TIMEFRAME, 0, barsCount, highTmp)  <= 0) return false;
   if(CopyLow  (_Symbol, POI_DETECTION_TIMEFRAME, 0, barsCount, lowTmp)   <= 0) return false;
   if(CopyClose(_Symbol, POI_DETECTION_TIMEFRAME, 0, barsCount, closeTmp) <= 0) return false;
   if(CopyTime (_Symbol, POI_DETECTION_TIMEFRAME, 0, barsCount, timeTmp)  <= 0) return false;

   for(int i = barsCount - 1; i >= 0; i--)
   {
      rawHighs[i]  = highTmp[i];
      rawLows[i]   = lowTmp[i];
      rawOpens[i]  = openTmp[i];
      rawCloses[i] = closeTmp[i];
      timeArr[i]   = timeTmp[i];
   }

   POI_ResetLuxState();
   luxBarsCount = barsCount;

   for(int index = barsCount - MathMax(swingLength, internalLength) - 2; index >= 0; index--)
   {
      if(index + 1 >= barsCount) continue;

      POI_ProcessStructurePivot(false, barsCount, index, swingLength);
      POI_ProcessStructurePivot(true,  barsCount, index, internalLength);

      POI_ProcessDisplayStructure(true,  index, internalFilterConfluence);
      POI_ProcessDisplayStructure(false, index, internalFilterConfluence);
   }

   POI_DrawLuxVisuals(timeArr[0]);

   return true;
}

//═══════════════════════════════════════════════════════════════════
//  ACESSORES PUBLICOS — para o modulo de estrategia
//═══════════════════════════════════════════════════════════════════

int POI_LuxEventCount()           { return luxEventCount; }
int POI_LuxBarsCount()            { return luxBarsCount; }

bool POI_LuxGetEvent(int idx, POI_StructureEvent &out)
{
   if(idx < 0 || idx >= luxEventCount) return false;
   out = luxEvents[idx];
   return true;
}

#endif
