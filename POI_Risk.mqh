//+------------------------------------------------------------------+
//| POI_Risk.mqh — sizing, margin checks, realized daily P/L         |
//| Self-contained. Espelho profissional do motor V900, prefixo POI_.|
//+------------------------------------------------------------------+
#ifndef POI_RISK_MQH
#define POI_RISK_MQH

#include "POI_Config.mqh"

//═══════════════════════════════════════════════════════════════════
//  ESTADO GLOBAL
//═══════════════════════════════════════════════════════════════════

double poi_cachedPointValue  = 0.0;
double poi_cachedFixedLots   = 0.0;
double poi_cachedMinLot      = 0.0;
double poi_cachedMaxLot      = 0.0;
double poi_cachedStepLot     = 0.0;
double poi_dailyClosedPL     = 0.0;
int    poi_dailyLossDay      = -1;
bool   poi_dailyLossLimitHit = false;

int    poi_sessionRequests   = 0;
int    poi_sessionFills      = 0;
int    poi_sessionStatsDay   = -1;

//═══════════════════════════════════════════════════════════════════
//  SESSION STATS
//═══════════════════════════════════════════════════════════════════

void POI_ResetSessionStatsIfNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != poi_sessionStatsDay)
   {
      poi_sessionRequests = 0;
      poi_sessionFills    = 0;
      poi_sessionStatsDay = dt.day_of_year;
   }
}

void POI_PrintSessionStats(string trigger)
{
   int    fails = poi_sessionRequests - poi_sessionFills;
   double ratio = (poi_sessionRequests > 0) ? 100.0 * poi_sessionFills / poi_sessionRequests : 0.0;
   PrintFormat("POI SESSION STATS [%s]: requests=%d fills=%d falhas=%d fillRatio=%.1f%%",
               trigger, poi_sessionRequests, poi_sessionFills, fails, ratio);
}

//═══════════════════════════════════════════════════════════════════
//  SIZING — NORMALIZAÇÃO
//═══════════════════════════════════════════════════════════════════

void POI_RefreshLotCacheIfNeeded()
{
   if(poi_cachedMinLot <= 0)
   {
      poi_cachedMinLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      poi_cachedMaxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      poi_cachedStepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   }
}

double POI_NormalizeLot(double volume)
{
   POI_RefreshLotCacheIfNeeded();
   volume = MathMax(poi_cachedMinLot, MathMin(poi_cachedMaxLot, volume));
   volume = MathRound(volume / poi_cachedStepLot) * poi_cachedStepLot;
   return NormalizeDouble(volume, 2);
}

double POI_NormalizeLotDown(double volume)
{
   POI_RefreshLotCacheIfNeeded();
   volume = MathMin(poi_cachedMaxLot, volume);
   volume = MathFloor((volume / poi_cachedStepLot) + 1e-9) * poi_cachedStepLot;
   if(volume < poi_cachedMinLot) return 0.0;
   return NormalizeDouble(volume, 2);
}

// MaxContractsCap declarado nos inputs do POI.mq5
double POI_ApplyMaxContractsCap(double volume, bool doLog = false)
{
   if(MaxContractsCap <= 0.0) return volume;
   double capped = POI_NormalizeLotDown(MathMin(volume, MaxContractsCap));
   if(capped <= 0.0)
   {
      if(doLog)
         PrintFormat("POI Cap: MaxContractsCap=%.2f abaixo do lote minimo. Trade ABORTADO.",
                     MaxContractsCap);
      return 0.0;
   }
   if(doLog && capped + 1e-9 < volume)
      PrintFormat("POI Cap: volume=%.2f limitado para %.2f por MaxContractsCap=%.2f",
                  volume, capped, MaxContractsCap);
   return capped;
}

//═══════════════════════════════════════════════════════════════════
//  CALCULO DE LOTES
//═══════════════════════════════════════════════════════════════════

double POI_GetPointValue()
{
   if(poi_cachedPointValue > 0) return poi_cachedPointValue;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return 0.0;
   poi_cachedPointValue = tickValue * (_Point / tickSize);
   return poi_cachedPointValue;
}

double POI_CalculateLots(double riskDist, bool doLog = false)
{
   if(RiskMode == POI_RISCO_FINANCEIRO)
   {
      double pointValue = POI_GetPointValue();
      if(pointValue <= 0.0)
      {
         Print("POI CalculateLots: erro ao obter valor do ponto. Trade abortado.");
         return 0.0;
      }
      double riskPoints = riskDist / _Point;
      double riskPerLot = riskPoints * pointValue;
      if(riskPerLot <= 0.0) return 0.0;

      POI_RefreshLotCacheIfNeeded();
      double exactVolume = FinancialRisk / riskPerLot;
      double safeVolume  = MathFloor(exactVolume / poi_cachedStepLot) * poi_cachedStepLot;
      if(safeVolume < poi_cachedMinLot)
      {
         if(doLog)
            PrintFormat("POI Sizing: Risco/lote=R$%.2f. Req=%.2f < min=%.2f para limite R$%.2f. ABORTADO.",
                        riskPerLot, exactVolume, poi_cachedMinLot, FinancialRisk);
         return 0.0;
      }
      if(doLog)
         PrintFormat("POI Sizing: dist=%.0fpts val/pt=R$%.2f risco/lote=R$%.2f calc=%.2f -> envio=%.2f (max R$%.2f)",
                     riskPoints, pointValue, riskPerLot, exactVolume, safeVolume, FinancialRisk);
      return POI_ApplyMaxContractsCap(POI_NormalizeLotDown(safeVolume), doLog);
   }

   if(poi_cachedFixedLots <= 0.0)
   {
      Print("POI ERRO: cachedFixedLots invalido. Recalculando...");
      POI_RefreshLotCacheIfNeeded();
      poi_cachedFixedLots = POI_NormalizeLot(Contracts);
      if(poi_cachedFixedLots <= 0.0) return 0.0;
   }
   return POI_ApplyMaxContractsCap(poi_cachedFixedLots, false);
}

//═══════════════════════════════════════════════════════════════════
//  MARGEM
//═══════════════════════════════════════════════════════════════════

bool POI_CheckMargin(ENUM_ORDER_TYPE orderType, double lots, double price)
{
   if(!UseMarginCheck) return true;
   double margin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lots, price, margin))
   {
      PrintFormat("POI MARGIN ERRO calc: type=%s lots=%.2f price=%.2f errCode=%d",
                  EnumToString(orderType), lots, price, GetLastError());
      return false;
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
   {
      PrintFormat("POI MARGIN FAIL: req=R$%.2f free=R$%.2f equity=R$%.2f balance=R$%.2f lots=%.2f type=%s price=%.2f",
                  margin, freeMargin,
                  AccountInfoDouble(ACCOUNT_EQUITY),
                  AccountInfoDouble(ACCOUNT_BALANCE),
                  lots, EnumToString(orderType), price);
      return false;
   }
   return true;
}

//═══════════════════════════════════════════════════════════════════
//  TRADE TRANSACTIONS — daily P/L
//═══════════════════════════════════════════════════════════════════

void POI_OnTradeTransaction(const MqlTradeTransaction &trans,
                            const MqlTradeRequest     &request,
                            const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong ticket = trans.deal;
   if(ticket == 0 || !HistoryDealSelect(ticket)) return;
   if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) return;
   if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)     return;

   long dealEntry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != poi_dailyLossDay)
   {
      poi_dailyClosedPL     = 0.0;
      poi_dailyLossDay      = dt.day_of_year;
      poi_dailyLossLimitHit = false;
   }
   poi_dailyClosedPL += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                      + HistoryDealGetDouble(ticket, DEAL_SWAP);
}

#endif
