//+------------------------------------------------------------------+
//| POI.mq5 — Estrategia POI (BOS + CHoCH + CHoCH @ 50%)             |
//| LuxAlgo SMC engine embarcado (sem dependencia externa).           |
//| Motor operacional profissional independente do V900.              |
//+------------------------------------------------------------------+
#property copyright "Felipe"
#property version   "1.00"
#property strict

//═══════════════════════════════════════════════════════════════════
//  TIPOS / ENUMS
//═══════════════════════════════════════════════════════════════════

#include "POI_Config.mqh"

//═══════════════════════════════════════════════════════════════════
//  INPUTS
//═══════════════════════════════════════════════════════════════════

input group "═══════════════════════════════════════════"
input group "═══════════ 01 · ATIVACAO GERAL ═══════════"
input group "═══════════════════════════════════════════"
input bool EnableTrading = true;        // Ativar envio de ordens reais
input int  MagicNumber   = 20260430;    // Magic Number (POI EA)
input bool DebugMode     = true;        // Logs detalhados (aba Experts)

input group "══════════════════════════════════════════════"
input group "═══════════ 02 · SESSAO E HORARIOS ═══════════"
input group "══════════════════════════════════════════════"
input POI_ENUM_TRADE_TIME StartTime = POI_TT_0905;  // Inicio da sessao
input POI_ENUM_TRADE_TIME EndTime   = POI_TT_1730;  // Fim da sessao (sem novas entradas)
input POI_ENUM_TRADE_TIME CloseTime = POI_TT_1800;  // Fechamento forcado a mercado

input group "════════════════════════════════════════════"
input group "═══════════ 03 · RISCO E TAMANHO ═══════════"
input group "════════════════════════════════════════════"
input POI_ENUM_RISK_MODE RiskMode        = POI_RISCO_CONTRATOS; // Tipo de risco
input double             Contracts       = 1.0;                 // Contratos por trade (modo fixo)
input double             FinancialRisk   = 100.0;               // Risco por trade em R$
input double             MaxContractsCap = 0.0;                 // Teto maximo de contratos (0=off)
input double             MaxDailyLossBRL = 500.0;               // Perda diaria max em R$ (0=off)
input bool               UseMarginCheck  = false;               // Checar margem livre

input group "═════════════════════════════════════════════════"
input group "═══════════ 04 · ESTRATEGIA POI (50%) ═══════════"
input group "═════════════════════════════════════════════════"
input bool   UpdatePOIEveryM1Bar = true;              // true=M1; false=barra do timeframe do grafico
input int    BosToChoch1MaxBars  = 8;                 // Max candles M1 entre BOS e CHoCH 1 (0=off)
input int    Choch1ToChoch2MaxBars = 6;               // Max candles M1 entre CHoCH 1 e CHoCH 2 (0=off)
input int    ChochLeg1MinPoints  = 100;               // Tamanho minimo POI (pts; 0=off)
input int    ChochLeg1MaxPoints  = 500;               // Tamanho maximo POI (pts; 0=off)
input int    ChochLeg2MinPoints  = 0;                 // Tamanho min. da perna do CHoCH 2 (pts; 0=off)

input group "=== 05. VISUAL - GRAFICO E CORES ==="
input bool  ShowInternalStructure      = true;              // Show Internal Structure
input bool  ShowSwingStructure         = false;             // Show Swing Structure
input int   POIBlendAlpha              = 70;                // Transparencia visual do POI (0 a 255)
input color InternalBullColor          = clrLimeGreen;      // Internal Bullish Structure
input color InternalBearColor          = clrTomato;         // Internal Bearish Structure
input color SwingBullColor             = clrDodgerBlue;     // Swing Bullish Structure
input color SwingBearColor             = clrFireBrick;      // Swing Bearish Structure
input bool  ShowPOIsOnChart            = false;             // Desenhar caixas POI no grafico
input bool  ShowMitigatedPOIs          = false;             // Exibir POIs ja mitigados
input color POIBullZoneColor           = C'0,180,80';       // Cor da Zona POI Bullish
input color POIBearZoneColor           = C'200,40,40';      // Cor da Zona POI Bearish

input group "═══════════════════════════════════════════════"
input group "═══════════ 05 · EXECUCAO DE ORDENS ═══════════"
input group "═══════════════════════════════════════════════"
input bool             UseLimitOrder     = false;               // true=LIMIT no 50%; false=mercado no gatilho
input bool             MarketEntryOnPOITouch = false;          // UseLimitOrder=false: true=toque na caixa; false=toque no 50%
input int              LimitMaxBars      = 5;                   // Validade da LIMIT (barras)
input int              StopOffsetPoints  = 16;                  // Offset do SL (pontos)
input double           TPMultiplier      = 3.0;                 // Multiplicador do TP
input POI_ENUM_TP_MODE TPMode            = POI_TP_FROM_LEG_BASE; // ENTRY=entrada-stop; LEG_BASE=modo antigo
input bool             UsePOISizeTarget  = false;               // true=alvo pelo tamanho do POI
input int              MaxSlippagePoints = 30;                  // Slippage max (pts)
input int              MaxSpreadPoints   = 0;                   // Spread max (pts, 0=off)
input int              OrderRetries      = 5;                   // Reenvios em caso de rejeicao
input bool             OneTradePerBar    = true;                // Max 1 tentativa por barra

input group "=== 06. DATASET POI / ML ==="
input bool             EnablePOICSVLogging = false;             // Ativar geracao do dataset POI
input string           CsvPathPOI          = "NOVOML\\dataset_poi_standalone.csv"; // CSV do POI standalone em Common\\Files
input int              MaxBarsTracking    = 30;                 // Max barras acompanhando MFE/MAE
input double           MaxRTracking       = 5.5;                // Max R antes de encerrar sample
input double           POIEntryPercent    = 0.5;                // Entrada do dataset no POI (0.5=50%)
input int              POIDatasetMaxBarsAfterFirstTouch = 8;    // Max barras M1 apos primeiro toque (0=off)
input int              POIDatasetLookbackN = 20;                // Lookback das features de contexto
input int              POIDatasetVelocityN = 5;                 // Janela da feature velocity

input group "═══════════════════════════════════════════════════════"
input group "═══════════ 06 · MOTOR LUXALGO — NAO ALTERAR ═════════"
input group "═══════════════════════════════════════════════════════"
input int  InternalLength           = 1;     // Periodo interno (BOS/CHoCH curto)
input int  SwingLength              = 10;    // Periodo swing (BOS/CHoCH longo) — usado p/ POI
input bool InternalFilterConfluence = true;  // Confluencia em internos

input group "=== 99. CONTEXTO ML - OB/FVG (PORT V2000) ==="
input bool            POIContextBuildOrderBlocks = true;           // Construir OBs para features do dataset
input bool            POIContextBuildFVG         = true;           // Construir FVGs para features do dataset
input ENUM_TIMEFRAMES POIContextOrderBlockTimeframe = PERIOD_CURRENT; // TF dos OBs (CURRENT=grafico, ex: M5)
input int             POIContextInternalLength   = 5;              // Internal Length do contexto OB V2000
input int             POIContextSwingLength      = 50;             // Swing Length do contexto OB V2000
input bool            POIContextUseAtrFilter     = true;           // Filtro ATR LuxAlgo para OBs
input bool            POIContextFilterContainedOBs = true;         // Remover OBs contidos nos arrays
input bool            POIContextUseCloseForOBMitigation = false;   // Mitigar OB por close em vez de high/low
input int             POIContextInternalOBCount  = 12;             // Qtd. Internal OBs nas features
input int             POIContextSwingOBCount     = 16;             // Qtd. Swing OBs nas features
input bool            POIContextFVGAutoThreshold = true;           // Auto threshold dos FVGs LuxAlgo
input ENUM_TIMEFRAMES POIContextFVGTimeframe     = PERIOD_CURRENT; // TF dos FVGs (CURRENT=TF do contexto)
input int             POIContextFVGExtend        = 16;             // Extend usado no estado FVG V2000

//═══════════════════════════════════════════════════════════════════
//  TRADE OBJECT — referenciado por POI_Execution.mqh
//═══════════════════════════════════════════════════════════════════

#include <Trade\Trade.mqh>
CTrade trade;

//═══════════════════════════════════════════════════════════════════
//  MODULOS
//═══════════════════════════════════════════════════════════════════

#include "POI_LuxAlgo.mqh"
#include "POI_ContextSMC.mqh"
#include "POI_FVG_LuxAlgo.mqh"
#include "POI_Risk.mqh"
#include "POI_Execution.mqh"
#include "POI_Strategy.mqh"
#include "POI_FeaturesML.mqh"
#include "POI_DatasetPOI.mqh"

//═══════════════════════════════════════════════════════════════════
//  ESTADO GLOBAL
//═══════════════════════════════════════════════════════════════════

int             prevBars      = 0; // barras do timeframe de atualizacao do motor POI
int             prevChartBars = 0; // barras do timeframe operacional do grafico
ENUM_TIMEFRAMES prevPeriod    = PERIOD_CURRENT;
int             prevContextBars = 0;
ENUM_TIMEFRAMES prevContextTf   = PERIOD_CURRENT;

ENUM_TIMEFRAMES POI_UpdateTriggerTimeframe()
{
   return UpdatePOIEveryM1Bar ? POI_DETECTION_TIMEFRAME : (ENUM_TIMEFRAMES)_Period;
}

int POI_UpdateTriggerBars()
{
   return Bars(_Symbol, POI_UpdateTriggerTimeframe());
}

bool POI_UpdateOBFVGContext(const bool force = false)
{
   if(!POI_ContextEnabled())
   {
      POI_ContextSMCReset();
      POI_LuxFVGReset();
      prevContextBars = 0;
      return true;
   }

   ENUM_TIMEFRAMES ctxTf = POI_ContextBaseTimeframe();
   int ctxBars = Bars(_Symbol, ctxTf);
   if(!force && poi_ctxBarsCount > 0 && ctxBars == prevContextBars && ctxTf == prevContextTf)
      return true;

   bool ok = POI_ContextSMCRun(POIContextSwingLength, POIContextInternalLength, InternalFilterConfluence);
   if(ok && POIContextBuildFVG)
      POI_LuxFVGContextRun(POIContextFVGAutoThreshold, POIContextFVGTimeframe, POIContextFVGExtend);
   else
      POI_LuxFVGReset();

   if(!ok)
      POI_ContextSMCReset();

   prevContextBars = ctxBars;
   prevContextTf = ctxTf;
   POI_ResetMLFeatureCaches();
   return ok;
}

//═══════════════════════════════════════════════════════════════════
//  CICLO DE VIDA
//═══════════════════════════════════════════════════════════════════

int OnInit()
{
   //──── 1/5 · Validacao de parametros ──────────────────────────────
   if(InternalLength < 1)
      { Print("ERRO: InternalLength deve ser >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(SwingLength < 1)
      { Print("ERRO: SwingLength deve ser >= 1");    return INIT_PARAMETERS_INCORRECT; }
   if(POIContextInternalLength < 1)
      { Print("ERRO: POIContextInternalLength deve ser >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(POIContextSwingLength < 1)
      { Print("ERRO: POIContextSwingLength deve ser >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(POIContextInternalOBCount < 0)
      { Print("ERRO: POIContextInternalOBCount deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(POIContextSwingOBCount < 0)
      { Print("ERRO: POIContextSwingOBCount deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(POIContextFVGExtend < 0)
      { Print("ERRO: POIContextFVGExtend deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(StopOffsetPoints < 0)
      { Print("ERRO: StopOffsetPoints deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(Contracts <= 0)
      { Print("ERRO: Contracts deve ser > 0");        return INIT_PARAMETERS_INCORRECT; }
   if(TPMultiplier <= 0)
      { Print("ERRO: TPMultiplier deve ser > 0");     return INIT_PARAMETERS_INCORRECT; }
   if(RiskMode == POI_RISCO_FINANCEIRO && FinancialRisk <= 0)
      { Print("ERRO: FinancialRisk deve ser > 0");    return INIT_PARAMETERS_INCORRECT; }
   if(MaxContractsCap < 0)
      { Print("ERRO: MaxContractsCap deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(MaxDailyLossBRL < 0)
      { Print("ERRO: MaxDailyLossBRL deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(UseLimitOrder && LimitMaxBars < 1)
      { Print("ERRO: LimitMaxBars deve ser >= 1 quando UseLimitOrder=true"); return INIT_PARAMETERS_INCORRECT; }
   if(BosToChoch1MaxBars < 0)
      { Print("ERRO: BosToChoch1MaxBars deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(Choch1ToChoch2MaxBars < 0)
      { Print("ERRO: Choch1ToChoch2MaxBars deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(ChochLeg1MinPoints < 0)
      { Print("ERRO: ChochLeg1MinPoints deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(ChochLeg1MaxPoints < 0)
      { Print("ERRO: ChochLeg1MaxPoints deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(ChochLeg1MinPoints > 0 && ChochLeg1MaxPoints > 0 && ChochLeg1MaxPoints < ChochLeg1MinPoints)
      { Print("ERRO: ChochLeg1MaxPoints deve ser >= ChochLeg1MinPoints"); return INIT_PARAMETERS_INCORRECT; }
   if(POIEntryPercent < 0.0 || POIEntryPercent > 1.0)
      { Print("ERRO: POIEntryPercent deve estar entre 0.0 e 1.0"); return INIT_PARAMETERS_INCORRECT; }
   if(MaxBarsTracking < 1)
      { Print("ERRO: MaxBarsTracking deve ser >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(MaxRTracking <= 0.0)
      { Print("ERRO: MaxRTracking deve ser > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(POIDatasetMaxBarsAfterFirstTouch < 0)
      { Print("ERRO: POIDatasetMaxBarsAfterFirstTouch deve ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(POIDatasetLookbackN < 2)
      { Print("ERRO: POIDatasetLookbackN deve ser >= 2"); return INIT_PARAMETERS_INCORRECT; }
   if(POIDatasetVelocityN < 1)
      { Print("ERRO: POIDatasetVelocityN deve ser >= 1"); return INIT_PARAMETERS_INCORRECT; }

   //──── 2/5 · Avisos de configuracao ───────────────────────────────
   if(EnableTrading && MaxDailyLossBRL == 0.0)
      Print("POI AVISO: MaxDailyLossBRL=0 - limite de perda diaria DESATIVADO. Configure para producao.");
   if(EnableTrading && MaxDailyLossBRL > 0.0 && RiskMode == POI_RISCO_FINANCEIRO && FinancialRisk >= MaxDailyLossBRL)
      PrintFormat("POI AVISO: FinancialRisk (%.2f) >= MaxDailyLossBRL (%.2f). Um trade pode exceder o limite diario.",
                  FinancialRisk, MaxDailyLossBRL);
   if(EnableTrading && MaxSlippagePoints == 0)
      Print("POI AVISO: MaxSlippagePoints=0 - controles de slippage DESATIVADOS. Em conta real recomenda-se 30+.");

   //──── 3/5 · Identificacao symbol/tick ────────────────────────────
   PrintFormat("POI INIT: Magic=%d Symbol=%s Period=%s ServerTime=%s",
               MagicNumber, _Symbol, EnumToString(_Period),
               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS));
   PrintFormat("POI DETECTION: timeframe=%s (fixo para padrao POI)",
               EnumToString(POI_DETECTION_TIMEFRAME));
   PrintFormat("POI UPDATE: timeframe=%s (%s)",
               EnumToString(POI_UpdateTriggerTimeframe()),
               UpdatePOIEveryM1Bar ? "a cada barra M1" : "a cada barra do grafico");
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double pointVal  = (tickSize > 0) ? tickValue * (_Point / tickSize) : 0.0;
   PrintFormat("POI SYMBOL: Point=%.5f TickSize=%.5f TickValue=R$%.4f PointValue=R$%.4f Digits=%d StopLevel=%I64d",
               _Point, tickSize, tickValue, pointVal, _Digits,
               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
   if(EnableTrading && pointVal <= 0)
      Print("POI ERRO CRITICO: PointValue=0 - sizing financeiro vai falhar. Revise tickValue/tickSize.");

   //──── 4/5 · LuxAlgo + Trade setup + cache de lotes ───────────────
   if(!POI_LuxAlgoInit())
   {
      Print("POI ERRO: falha ao inicializar engine LuxAlgo.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   if(MaxSlippagePoints > 0) trade.SetDeviationInPoints(MaxSlippagePoints);

   POI_RefreshLotCacheIfNeeded();
   poi_cachedFixedLots = POI_NormalizeLot(Contracts);
   PrintFormat("POI Lot cache: min=%.2f max=%.2f step=%.2f fixedLots=%.2f",
               poi_cachedMinLot, poi_cachedMaxLot, poi_cachedStepLot, poi_cachedFixedLots);
   if(MaxContractsCap > 0.0)
      PrintFormat("POI Protecao de volume ativa - MaxContractsCap=%.2f", MaxContractsCap);

   //──── 5/5 · Estado inicial ───────────────────────────────────────
   POI_ClearPendingTracking();
   POI_StrategyReset();
   POI_DatasetReset();
   poi_closedThisSession = false;
   if(EnablePOICSVLogging)
      Print("POI Dataset ativo - arquivo: ", CsvPathPOI);

   if(!POI_LuxAlgoRun(SwingLength, InternalLength, InternalFilterConfluence))
      Print("POI AVISO: primeira execucao de POI_LuxAlgoRun retornou false (poucos dados?).");

   if(!POI_UpdateOBFVGContext(true))
      Print("POI AVISO: primeira execucao do contexto OB/FVG retornou false (poucos dados?).");

   POI_StrategyOnNewBar(false);

   prevBars   = POI_UpdateTriggerBars();
   prevChartBars = Bars(_Symbol, _Period);
   prevPeriod = Period();

   if(DebugMode)
   {
      int sh, sm, eh, em, clh, clm;
      POI_EnumToHM(StartTime, sh, sm);
      POI_EnumToHM(EndTime,   eh, em);
      POI_EnumToHM(CloseTime, clh, clm);
      Print("POI ===== DEBUG CONFIG =====");
      PrintFormat("POI DBG | EnableTrading=%s RiskMode=%s Contracts=%.2f FinancialRisk=%.2f MaxDailyLoss=%.2f",
         (EnableTrading ? "true" : "false"),
         (RiskMode == POI_RISCO_FINANCEIRO ? "FINANCEIRO" : "CONTRATOS"),
         Contracts, FinancialRisk, MaxDailyLossBRL);
      PrintFormat("POI DBG | TPMultiplier=%.1f TPMode=%s UsePOISizeTarget=%s UseLimitOrder=%s MarketEntryOnPOITouch=%s LimitMaxBars=%d StopOffset=%dpts",
         TPMultiplier,
         (TPMode == POI_TP_FROM_LEG_BASE ? (UsePOISizeTarget ? "POI_SIZE" : "LEG_BASE") : "ENTRY"),
         (UsePOISizeTarget ? "true" : "false"),
         (UseLimitOrder ? "true" : "false"),
         (MarketEntryOnPOITouch ? "true" : "false"),
         LimitMaxBars, StopOffsetPoints);
      PrintFormat("POI DBG | POI min=%dpts max=%dpts ChochLeg2=%dpts BosToChoch1Max=%d Choch1ToChoch2Max=%d",
         ChochLeg1MinPoints, ChochLeg1MaxPoints, ChochLeg2MinPoints,
         BosToChoch1MaxBars, Choch1ToChoch2MaxBars);
      PrintFormat("POI DBG | Session=%02d:%02d-%02d:%02d Close=%02d:%02d",
         sh, sm, eh, em, clh, clm);
      PrintFormat("POI DBG | InternalLength=%d SwingLength=%d",
         InternalLength, SwingLength);
      PrintFormat("POI DBG | Dataset=%s EntryPercent=%.2f MaxBarsTracking=%d MaxR=%.1f Csv=%s",
         (EnablePOICSVLogging ? "true" : "false"),
         POIEntryPercent, MaxBarsTracking, MaxRTracking, CsvPathPOI);
      PrintFormat("POI DBG | Context OB=%s FVG=%s TF=%s IntLen=%d SwingLen=%d OBs=%d/%d FVGTF=%s",
         (POIContextBuildOrderBlocks ? "true" : "false"),
         (POIContextBuildFVG ? "true" : "false"),
         EnumToString(POI_ContextBaseTimeframe()),
         POIContextInternalLength, POIContextSwingLength,
         poi_internalOBSize, poi_swingOBSize,
         EnumToString(POIContextFVGTimeframe));
      Print("POI ============================");
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   POI_PrintSessionStats("OnDeinit");
   if(EnablePOICSVLogging)
      POI_FinalizePOIDataset();
   POI_CancelAllPendingOrders();
   POI_ClearStrategyVisualObjects(false);
   POI_ClearLuxVisualObjects(false);
   POI_LuxFVGReset();
   POI_ContextSMCDeinit();
   POI_LuxAlgoDeinit();
}

void OnTick()
{
   int currentBars = POI_UpdateTriggerBars();

   if(currentBars != prevBars)
   {
      // Recalcula engine M1 + reconstroi zonas no ritmo definido pelo input.
      POI_LuxAlgoRun(SwingLength, InternalLength, InternalFilterConfluence);
      POI_UpdateOBFVGContext(false);
      POI_StrategyOnNewBar(false);

      prevBars = currentBars;
   }

   int currentChartBars = Bars(_Symbol, _Period);
   if(currentChartBars != prevChartBars)
   {
      if(EnableTrading && UseLimitOrder)
      {
         POI_IncrementPendingBars();
         POI_UpdatePendingOrders();
      }

      if(EnablePOICSVLogging && poiSampleCount > 0)
         POI_UpdatePOISamplesOnBarClose();
      if(EnablePOICSVLogging && poiCsvBufferCount > 0)
         POI_FlushPOICSVBuffer();

      prevChartBars = currentChartBars;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(EnableTrading)
   {
      if(MaxDailyLossBRL > 0.0) POI_UpdateDailyPL();
      POI_CheckCloseHour();
   }

   if(EnablePOICSVLogging)
   {
      POI_CheckPOIEntryTouches(ask, bid);
      if(poiSampleCount > 0)
         POI_UpdatePOIMFEMAE_OnTick(ask, bid);
   }

   POI_StrategyOnTick(ask, bid);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   POI_OnTradeTransaction(trans, request, result);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      ENUM_TIMEFRAMES currentPeriod = Period();
      if(currentPeriod != prevPeriod)
      {
         prevPeriod = currentPeriod;
         POI_LuxAlgoRun(SwingLength, InternalLength, InternalFilterConfluence);
         POI_UpdateOBFVGContext(true);
         POI_StrategyOnNewBar(false);
         prevBars = POI_UpdateTriggerBars();
         prevChartBars = Bars(_Symbol, _Period);
      }
   }
}
