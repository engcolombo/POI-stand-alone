//+------------------------------------------------------------------+
//| POI_Config.mqh — types, constants, enums for POI EA              |
//| Self-contained. Does not reference V900 or LUXALGO.              |
//+------------------------------------------------------------------+
#ifndef POI_CONFIG_MQH
#define POI_CONFIG_MQH

//═══════════════════════════════════════════════════════════════════
//  CONSTANTES
//═══════════════════════════════════════════════════════════════════

#define POI_BULLISH        1
#define POI_BEARISH       -1
#define POI_BULLISH_LEG    1
#define POI_BEARISH_LEG    0
#define POI_MAX_BARS       10000
#define POI_MAX_OBS        100
#define POI_MAX_EVENTS     2000
#define POI_MAX_PENDING    20
#define POI_MAX_SAMPLES    1000
#define POI_MAX_SAMPLED    500

//═══════════════════════════════════════════════════════════════════
//  STRUCTS — LuxAlgo-style structure detection
//═══════════════════════════════════════════════════════════════════

struct POI_Pivot
{
   double   currentLevel;
   double   lastLevel;
   bool     crossed;
   datetime barTime;
   int      barIndex;
};

struct POI_StructureEvent
{
   datetime pivotTime;
   datetime breakTime;
   double   level;
   bool     bullish;
   bool     internal;
   bool     choch;
   int      pivotBarIndex;
   int      breakBarIndex;
};

struct POI_OrderBlock
{
   double   high;
   double   low;
   datetime time;
   int      bias;
   double   ob_volume_ratio;
   double   impulse_volume_ratio;
   double   volume_per_range_ob;
   double   volume_per_range_impulse;
   double   ob_raw_volume;
};

//═══════════════════════════════════════════════════════════════════
//  STRUCTS — POI strategy state
//═══════════════════════════════════════════════════════════════════

struct POI_Zone
{
   bool     active;
   int      id;
   int      bias;            // POI_BULLISH = compra @ 50% / POI_BEARISH = venda @ 50%
   double   legHigh;         // topo da perna que gerou o primeiro CHoCH
   double   legLow;          // fundo da perna que gerou o primeiro CHoCH
   double   midPrice;        // 50% retrace
   datetime createdTime;     // confirmacao do segundo CHoCH
   datetime visualStartTime; // inicio visual da perna do primeiro CHoCH
   int      createdBarIndex;
   int      barsAlive;
   double   legSizePoints;   // tamanho da perna do CHoCH 1 (pts)
   double   poiSizePoints;   // tamanho da zona POI desenhada (pts)
   bool     sampled;         // dataset: ja criou sample para esta zona
   bool     firstTouchSeen;  // dataset: preco ja entrou na zona
   datetime firstTouchTime;
   datetime firstTouchBarTime;

   datetime tA; double pA;
   datetime tB; double pB;
   datetime tC; double pC;
   datetime tD; double pD;
   datetime tE; double pE;
   datetime tF; double pF;
   double   eCandleHigh;
   double   eCandleLow;
};

struct POI_PendingLimitOrder
{
   ulong    ticket;
   datetime zoneTime;
   int      zoneBias;
   int      barsAlive;
   bool     active;
};

//═══════════════════════════════════════════════════════════════════
//  ENUMS
//═══════════════════════════════════════════════════════════════════

enum POI_ENUM_TRADE_TIME
{
   POI_TT_0800 = 0,    // 08:00
   POI_TT_0830 = 30,   // 08:30
   POI_TT_0900 = 60,   // 09:00
   POI_TT_0905 = 65,   // 09:05
   POI_TT_0910 = 70,   // 09:10
   POI_TT_0915 = 75,   // 09:15
   POI_TT_0920 = 80,   // 09:20
   POI_TT_0925 = 85,   // 09:25
   POI_TT_0930 = 90,   // 09:30
   POI_TT_0935 = 95,   // 09:35
   POI_TT_0940 = 100,  // 09:40
   POI_TT_0945 = 105,  // 09:45
   POI_TT_0950 = 110,  // 09:50
   POI_TT_0955 = 115,  // 09:55
   POI_TT_1000 = 120,  // 10:00
   POI_TT_1030 = 150,  // 10:30
   POI_TT_1100 = 180,  // 11:00
   POI_TT_1130 = 210,  // 11:30
   POI_TT_1200 = 240,  // 12:00
   POI_TT_1230 = 270,  // 12:30
   POI_TT_1300 = 300,  // 13:00
   POI_TT_1330 = 330,  // 13:30
   POI_TT_1400 = 360,  // 14:00
   POI_TT_1430 = 390,  // 14:30
   POI_TT_1500 = 420,  // 15:00
   POI_TT_1530 = 450,  // 15:30
   POI_TT_1600 = 480,  // 16:00
   POI_TT_1630 = 510,  // 16:30
   POI_TT_1700 = 540,  // 17:00
   POI_TT_1730 = 570,  // 17:30
   POI_TT_1800 = 600   // 18:00
};

enum POI_ENUM_RISK_MODE
{
   POI_RISCO_CONTRATOS,    // Contratos fixos
   POI_RISCO_FINANCEIRO    // Risco em R$
};

enum POI_ENUM_TP_MODE
{
   POI_TP_FROM_ENTRY,      // TP pela distancia entrada -> stop
   POI_TP_FROM_LEG_BASE    // TP pela base da perna (modo antigo)
};

//═══════════════════════════════════════════════════════════════════
//  HELPERS
//═══════════════════════════════════════════════════════════════════

void POI_EnumToHM(POI_ENUM_TRADE_TIME t, int &h, int &m)
{
   int totalMinutes = 480 + (int)t;
   h = totalMinutes / 60;
   m = totalMinutes % 60;
}

#endif
