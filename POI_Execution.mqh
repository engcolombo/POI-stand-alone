//+------------------------------------------------------------------+
//| POI_Execution.mqh — orders, positions, session flat              |
//| Self-contained. Espelho do motor V900, prefixo POI_.             |
//+------------------------------------------------------------------+
#ifndef POI_EXECUTION_MQH
#define POI_EXECUTION_MQH

#include "POI_Config.mqh"
#include "POI_Risk.mqh"
#include "POI_LuxAlgo.mqh"

//═══════════════════════════════════════════════════════════════════
//  ESTADO + PENDING TRACKING
//═══════════════════════════════════════════════════════════════════

bool poi_closedThisSession = false;
POI_PendingLimitOrder poi_pendingOrders[POI_MAX_PENDING];
int  poi_pendingCount = 0;

void POI_ClearPendingTracking()
{
   for(int i = 0; i < POI_MAX_PENDING; i++)
   {
      poi_pendingOrders[i].ticket    = 0;
      poi_pendingOrders[i].zoneTime  = 0;
      poi_pendingOrders[i].zoneBias  = 0;
      poi_pendingOrders[i].barsAlive = 0;
      poi_pendingOrders[i].active    = false;
   }
   poi_pendingCount = 0;
}

//═══════════════════════════════════════════════════════════════════
//  POSITION / PENDING QUERIES
//═══════════════════════════════════════════════════════════════════

bool POI_HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL)  == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber)
         return true;
   }
   return false;
}

bool POI_IsPendingOrderType(ENUM_ORDER_TYPE type)
{
   return (type == ORDER_TYPE_BUY_LIMIT  ||
           type == ORDER_TYPE_SELL_LIMIT ||
           type == ORDER_TYPE_BUY_STOP   ||
           type == ORDER_TYPE_SELL_STOP);
}

bool POI_HasPendingOrderByMagic()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(POI_IsPendingOrderType(orderType)) return true;
   }
   return false;
}

bool POI_HasActiveExposureByMagic()
{
   return (POI_HasOpenPosition() || POI_HasPendingOrderByMagic());
}

//═══════════════════════════════════════════════════════════════════
//  HORÁRIO DE OPERAÇÃO
//═══════════════════════════════════════════════════════════════════

bool POI_IsWithinTradingHours()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int cur = dt.hour * 60 + dt.min;
   int sh, sm, eh, em;
   POI_EnumToHM(StartTime, sh, sm);
   POI_EnumToHM(EndTime,   eh, em);
   int s = sh * 60 + sm, e = eh * 60 + em;
   if(s < e) return (cur >= s && cur < e);
   return (cur >= s || cur < e);
}

//═══════════════════════════════════════════════════════════════════
//  PENDING — LIFECYCLE
//═══════════════════════════════════════════════════════════════════

void POI_TrackPendingOrder(ulong ticket, datetime zoneTime, int zoneBias)
{
   for(int i = 0; i < POI_MAX_PENDING; i++)
   {
      if(!poi_pendingOrders[i].active)
      {
         poi_pendingOrders[i].ticket    = ticket;
         poi_pendingOrders[i].zoneTime  = zoneTime;
         poi_pendingOrders[i].zoneBias  = zoneBias;
         poi_pendingOrders[i].barsAlive = 0;
         poi_pendingOrders[i].active    = true;
         poi_pendingCount++;
         return;
      }
   }
   PrintFormat("POI AVISO: POI_MAX_PENDING (%d) atingido. Ordem %I64u nao rastreada.",
               POI_MAX_PENDING, ticket);
}

void POI_RemovePendingSlot(int index)
{
   if(!poi_pendingOrders[index].active) return;
   poi_pendingOrders[index].active    = false;
   poi_pendingOrders[index].ticket    = 0;
   poi_pendingOrders[index].zoneTime  = 0;
   poi_pendingOrders[index].zoneBias  = 0;
   poi_pendingOrders[index].barsAlive = 0;
   poi_pendingCount--;
}

bool POI_IsPendingOrderAlive(ulong ticket)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) == ticket) return true;
   return false;
}

bool POI_CancelPendingOrder(ulong ticket)
{
   if(trade.OrderDelete(ticket))
   {
      PrintFormat("POI Limit cancelada ticket=%I64u", ticket);
      return true;
   }
   int retCode = (int)trade.ResultRetcode();
   if(retCode == TRADE_RETCODE_INVALID_ORDER)
   {
      PrintFormat("POI Limit ticket=%I64u nao encontrada (ja fechada?). Removendo do rastreio.", ticket);
      return true;
   }
   PrintFormat("POI AVISO: falha ao cancelar limit ticket=%I64u retcode=%d",
               ticket, retCode);
   return false;
}

bool POI_HasPendingForZone(datetime zoneTime, int zoneBias)
{
   for(int i = 0; i < POI_MAX_PENDING; i++)
      if(poi_pendingOrders[i].active &&
         poi_pendingOrders[i].zoneTime == zoneTime &&
         poi_pendingOrders[i].zoneBias == zoneBias)
         return true;
   return false;
}

void POI_UpdatePendingOrders()
{
   for(int i = 0; i < POI_MAX_PENDING; i++)
   {
      if(!poi_pendingOrders[i].active) continue;
      ulong tkt = poi_pendingOrders[i].ticket;
      if(!POI_IsPendingOrderAlive(tkt))
      {
         if(HistoryOrderSelect(tkt))
         {
            ENUM_ORDER_STATE st = (ENUM_ORDER_STATE)HistoryOrderGetInteger(tkt, ORDER_STATE);
            double fillPx = HistoryOrderGetDouble(tkt, ORDER_PRICE_CURRENT);
            if(st == ORDER_STATE_FILLED || st == ORDER_STATE_PARTIAL)
               PrintFormat("POI LIMIT EXECUTADA: tkt=%I64u fillPx=%.2f", tkt, fillPx);
            else
               PrintFormat("POI LIMIT REMOVIDA: tkt=%I64u state=%d (cancel/expired)", tkt, (int)st);
         }
         POI_RemovePendingSlot(i);
         continue;
      }
      if(poi_pendingOrders[i].barsAlive >= LimitMaxBars)
      {
         PrintFormat("POI LIMIT expirada por LimitMaxBars: tkt=%I64u barsAlive=%d/%d cancelando.",
                     tkt, poi_pendingOrders[i].barsAlive, LimitMaxBars);
         POI_CancelPendingOrder(tkt);
         POI_RemovePendingSlot(i);
      }
   }
}

void POI_IncrementPendingBars()
{
   for(int i = 0; i < POI_MAX_PENDING; i++)
      if(poi_pendingOrders[i].active) poi_pendingOrders[i].barsAlive++;
}

void POI_CancelAllPendingOrders()
{
   for(int i = 0; i < POI_MAX_PENDING; i++)
   {
      if(!poi_pendingOrders[i].active) continue;
      if(POI_IsPendingOrderAlive(poi_pendingOrders[i].ticket))
         POI_CancelPendingOrder(poi_pendingOrders[i].ticket);
      POI_RemovePendingSlot(i);
   }
}

//═══════════════════════════════════════════════════════════════════
//  CLOSE ALL + CLOSE TIME
//═══════════════════════════════════════════════════════════════════

string POI_BarStamp()
{
   return "bar=" + TimeToString(timeArr[0], TIME_DATE | TIME_MINUTES);
}

bool POI_IsFatalRetcode(int retCode)
{
   return (retCode == TRADE_RETCODE_NO_MONEY              ||
           retCode == TRADE_RETCODE_MARKET_CLOSED         ||
           retCode == TRADE_RETCODE_TRADE_DISABLED        ||
           retCode == TRADE_RETCODE_CLIENT_DISABLES_AT    ||
           retCode == TRADE_RETCODE_LIMIT_VOLUME          ||
           retCode == TRADE_RETCODE_INVALID_VOLUME        ||
           retCode == TRADE_RETCODE_INVALID_STOPS         ||
           retCode == TRADE_RETCODE_INVALID_PRICE);
}

void POI_CloseAllPositions()
{
   int maxTries = 1 + MathMax(0, OrderRetries);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double posVol    = PositionGetDouble(POSITION_VOLUME);
      double posProfit = PositionGetDouble(POSITION_PROFIT);

      bool closed = false;
      for(int attempt = 1; attempt <= maxTries; attempt++)
      {
         if(attempt > 1) Sleep(150);
         if(trade.PositionClose(ticket))
         {
            PrintFormat("POI POSITION CLOSED OK: %s tkt=%I64u fillPx=%.2f vol=%.2f profit=R$%.2f tentativa=%d/%d",
                        POI_BarStamp(), ticket, trade.ResultPrice(), posVol, posProfit, attempt, maxTries);
            closed = true;
            break;
         }
         int retCode = (int)trade.ResultRetcode();
         PrintFormat("POI ClosePosition falhou (%d/%d): tkt=%I64u retcode=%d %s",
                     attempt, maxTries, ticket, retCode, trade.ResultRetcodeDescription());
         if(POI_IsFatalRetcode(retCode))
         {
            PrintFormat("POI ClosePosition ABORT retcode FATAL=%d tkt=%I64u", retCode, ticket);
            break;
         }
      }
      if(!closed)
         PrintFormat("POI AVISO: posicao tkt=%I64u NAO fechada apos %d tentativas.", ticket, maxTries);
   }
}

void POI_CheckCloseHour()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int cur = dt.hour * 60 + dt.min;
   int ch, cm; POI_EnumToHM(CloseTime, ch, cm);
   int closeMin = ch * 60 + cm;

   static int lastCloseDay = -1;
   if(dt.day_of_year != lastCloseDay)
   {
      poi_closedThisSession = false;
      lastCloseDay          = dt.day_of_year;
   }

   if(cur >= closeMin && !poi_closedThisSession)
   {
      if(UseLimitOrder) POI_CancelAllPendingOrders();
      POI_CloseAllPositions();
      if(!POI_HasOpenPosition())
      {
         POI_PrintSessionStats("CloseTime");
         poi_closedThisSession = true;
      }
      else
         PrintFormat("POI AVISO: falha ao fechar posicoes no CloseTime. Retry no proximo tick.");
   }
}

void POI_UpdateDailyPL()
{
   static datetime lastUpdate = 0;
   if(TimeCurrent() == lastUpdate) return;
   lastUpdate = TimeCurrent();

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != poi_dailyLossDay)
   {
      poi_dailyClosedPL     = 0.0;
      poi_dailyLossDay      = dt.day_of_year;
      poi_dailyLossLimitHit = false;
   }

   double floatingPL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt > 0 && PositionSelectByTicket(tkt) &&
         PositionGetString(POSITION_SYMBOL)  == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber)
         floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   double totalDayPL = poi_dailyClosedPL + floatingPL;

   if(MaxDailyLossBRL > 0.0 && totalDayPL <= -MaxDailyLossBRL)
   {
      if(!poi_dailyLossLimitHit)
      {
         PrintFormat("POI ===== LIMITE DIARIO ATIVADO ===== %s",
                     TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS));
         PrintFormat("POI PL realizado=R$%.2f floating=R$%.2f total=R$%.2f limite=-R$%.2f",
                     poi_dailyClosedPL, floatingPL, totalDayPL, MaxDailyLossBRL);

         if(UseLimitOrder) POI_CancelAllPendingOrders();
         POI_CloseAllPositions();

         if(!POI_HasOpenPosition())
         {
            poi_dailyLossLimitHit = true;
            PrintFormat("POI LIMITE DIARIO confirmado, sessao bloqueada ate proxima virada de dia.");
         }
         else
            PrintFormat("POI AVISO: limite atingido mas posicao ainda aberta. Retry proximo tick.");
      }
      else if(POI_HasOpenPosition())
      {
         POI_CloseAllPositions();
         if(!POI_HasOpenPosition())
            PrintFormat("POI Posicao fechada apos limite diario.");
      }
   }
}

//═══════════════════════════════════════════════════════════════════
//  PRIMITIVAS — NORMALIZE / SPREAD / TP / RISK
//═══════════════════════════════════════════════════════════════════

double POI_NormalizePrice(double price)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) return price;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
}

bool POI_IsSpreadOK()
{
   if(MaxSpreadPoints <= 0) return true;
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > (long)MaxSpreadPoints)
   {
      if(DebugMode) PrintFormat("POI Spread filtrado: %I64d > %d pts", sp, MaxSpreadPoints);
      return false;
   }
   return true;
}

// TP: ENTRY usa entrada-stop. LEG_BASE usa modo antigo, ou tamanho do POI se habilitado.
double POI_ComputeBuyTP(double entryPrice, double sl, double legBasePrice, double poiSizePrice, double tpMult)
{
   double tpBase = MathAbs(entryPrice - sl);
   if(TPMode == POI_TP_FROM_LEG_BASE)
      tpBase = UsePOISizeTarget ? poiSizePrice : MathAbs(legBasePrice - sl);
   return POI_NormalizePrice(entryPrice + tpBase * tpMult);
}

double POI_ComputeSellTP(double entryPrice, double sl, double legBasePrice, double poiSizePrice, double tpMult)
{
   double tpBase = MathAbs(entryPrice - sl);
   if(TPMode == POI_TP_FROM_LEG_BASE)
      tpBase = UsePOISizeTarget ? poiSizePrice : MathAbs(legBasePrice - sl);
   return POI_NormalizePrice(entryPrice - tpBase * tpMult);
}

double POI_RiskForSizing(double actualRisk, double sl, double legBasePrice)
{
   if(RiskMode == POI_RISCO_FINANCEIRO &&
      TPMode == POI_TP_FROM_LEG_BASE &&
      !UsePOISizeTarget)
      return MathAbs(legBasePrice - sl);
   return actualRisk;
}

//═══════════════════════════════════════════════════════════════════
//  PLACEMENT — LIMIT (BUY/SELL) com retry e fallback Limit->Market
//═══════════════════════════════════════════════════════════════════

bool POI_BuyWithRetry (double sl, double legBasePrice, double poiSizePrice, double tpMult, string comment);
bool POI_SellWithRetry(double sl, double legBasePrice, double poiSizePrice, double tpMult, string comment);

bool POI_PlaceBuyLimit(double limitPrice, double sl, double legBasePrice, double poiSizePrice,
                       datetime zoneTime, int zoneBias, double tpMult, string comment)
{
   if(POI_HasActiveExposureByMagic()) return false;
   if(!POI_IsSpreadOK()) return false;

   limitPrice = POI_NormalizePrice(limitPrice);
   sl         = POI_NormalizePrice(sl);

   double actualRisk = MathAbs(limitPrice - sl);
   if(actualRisk <= 0 || limitPrice <= sl)
   {
      PrintFormat("POI BUY LIMIT ABORT risco invalido: lim=%.2f sl=%.2f cmt=%s",
                  limitPrice, sl, comment);
      return false;
   }

   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stopLevel > 0 && actualRisk < stopLevel)
   {
      PrintFormat("POI BUY LIMIT ABORT STOP_LEVEL: dist=%.0fpts < min=%.0fpts cmt=%s",
                  actualRisk / _Point, stopLevel / _Point, comment);
      return false;
   }

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(limitPrice >= currentAsk)
   {
      double gapPts = (currentAsk - limitPrice) / _Point;
      if(MaxSlippagePoints > 0 && MathAbs(gapPts) > MaxSlippagePoints)
      {
         PrintFormat("POI BUY LIMIT->MKT ABORT gap excede slippage: req=%.2f ask=%.2f gap=%.0fpts > max=%d cmt=%s",
                     limitPrice, currentAsk, gapPts, MaxSlippagePoints, comment);
         return false;
      }
      PrintFormat("POI BUY LIMIT->MKT: req=%.2f ask=%.2f gap=%.0fpts (dentro slippage), executando market cmt=%s",
                  limitPrice, currentAsk, gapPts, comment);
      return POI_BuyWithRetry(sl, legBasePrice, poiSizePrice, tpMult, comment + "_MKT");
   }

   double lots = POI_CalculateLots(POI_RiskForSizing(actualRisk, sl, legBasePrice), true);
   if(lots <= 0)
   {
      PrintFormat("POI BUY LIMIT ABORT lots=0: riskPts=%.0f cmt=%s", actualRisk / _Point, comment);
      return false;
   }
   if(!POI_CheckMargin(ORDER_TYPE_BUY_LIMIT, lots, limitPrice)) return false;

   double tp = POI_ComputeBuyTP(limitPrice, sl, legBasePrice, poiSizePrice, tpMult);
   if(POI_HasActiveExposureByMagic()) return false;

   POI_ResetSessionStatsIfNewDay();
   poi_sessionRequests++;

   int maxTries = 1 + MathMax(0, OrderRetries);
   for(int attempt = 1; attempt <= maxTries; attempt++)
   {
      if(attempt > 1) Sleep(150);
      if(trade.BuyLimit(lots, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment))
      {
         ulong ticket = trade.ResultOrder();
         PrintFormat("POI BUY LIMIT OK: %s price=%.2f sl=%.2f tp=%.2f lots=%.2f tkt=%I64u tpMult=%.1f tentativa=%d/%d cmt=%s",
                     POI_BarStamp(), limitPrice, sl, tp, lots, ticket, tpMult, attempt, maxTries, comment);
         POI_TrackPendingOrder(ticket, zoneTime, zoneBias);
         poi_sessionFills++;
         return true;
      }
      int retCode = (int)trade.ResultRetcode();
      PrintFormat("POI BUY LIMIT falhou (%d/%d): retcode=%d %s price=%.2f cmt=%s",
                  attempt, maxTries, retCode, trade.ResultRetcodeDescription(), limitPrice, comment);
      if(POI_IsFatalRetcode(retCode))
      {
         PrintFormat("POI BUY LIMIT ABORT retcode FATAL=%d cmt=%s", retCode, comment);
         return false;
      }
   }
   return false;
}

bool POI_PlaceSellLimit(double limitPrice, double sl, double legBasePrice, double poiSizePrice,
                        datetime zoneTime, int zoneBias, double tpMult, string comment)
{
   if(POI_HasActiveExposureByMagic()) return false;
   if(!POI_IsSpreadOK()) return false;

   limitPrice = POI_NormalizePrice(limitPrice);
   sl         = POI_NormalizePrice(sl);

   double actualRisk = MathAbs(limitPrice - sl);
   if(actualRisk <= 0 || limitPrice >= sl)
   {
      PrintFormat("POI SELL LIMIT ABORT risco invalido: lim=%.2f sl=%.2f cmt=%s",
                  limitPrice, sl, comment);
      return false;
   }

   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stopLevel > 0 && actualRisk < stopLevel)
   {
      PrintFormat("POI SELL LIMIT ABORT STOP_LEVEL: dist=%.0fpts < min=%.0fpts cmt=%s",
                  actualRisk / _Point, stopLevel / _Point, comment);
      return false;
   }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(limitPrice <= currentBid)
   {
      double gapPts = (limitPrice - currentBid) / _Point;
      if(MaxSlippagePoints > 0 && MathAbs(gapPts) > MaxSlippagePoints)
      {
         PrintFormat("POI SELL LIMIT->MKT ABORT gap excede slippage: req=%.2f bid=%.2f gap=%.0fpts > max=%d cmt=%s",
                     limitPrice, currentBid, gapPts, MaxSlippagePoints, comment);
         return false;
      }
      PrintFormat("POI SELL LIMIT->MKT: req=%.2f bid=%.2f gap=%.0fpts (dentro slippage), executando market cmt=%s",
                  limitPrice, currentBid, gapPts, comment);
      return POI_SellWithRetry(sl, legBasePrice, poiSizePrice, tpMult, comment + "_MKT");
   }

   double lots = POI_CalculateLots(POI_RiskForSizing(actualRisk, sl, legBasePrice), true);
   if(lots <= 0)
   {
      PrintFormat("POI SELL LIMIT ABORT lots=0: riskPts=%.0f cmt=%s", actualRisk / _Point, comment);
      return false;
   }
   if(!POI_CheckMargin(ORDER_TYPE_SELL_LIMIT, lots, limitPrice)) return false;

   double tp = POI_ComputeSellTP(limitPrice, sl, legBasePrice, poiSizePrice, tpMult);
   if(POI_HasActiveExposureByMagic()) return false;

   POI_ResetSessionStatsIfNewDay();
   poi_sessionRequests++;

   int maxTries = 1 + MathMax(0, OrderRetries);
   for(int attempt = 1; attempt <= maxTries; attempt++)
   {
      if(attempt > 1) Sleep(150);
      if(trade.SellLimit(lots, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment))
      {
         ulong ticket = trade.ResultOrder();
         PrintFormat("POI SELL LIMIT OK: %s price=%.2f sl=%.2f tp=%.2f lots=%.2f tkt=%I64u tpMult=%.1f tentativa=%d/%d cmt=%s",
                     POI_BarStamp(), limitPrice, sl, tp, lots, ticket, tpMult, attempt, maxTries, comment);
         POI_TrackPendingOrder(ticket, zoneTime, zoneBias);
         poi_sessionFills++;
         return true;
      }
      int retCode = (int)trade.ResultRetcode();
      PrintFormat("POI SELL LIMIT falhou (%d/%d): retcode=%d %s price=%.2f cmt=%s",
                  attempt, maxTries, retCode, trade.ResultRetcodeDescription(), limitPrice, comment);
      if(POI_IsFatalRetcode(retCode))
      {
         PrintFormat("POI SELL LIMIT ABORT retcode FATAL=%d cmt=%s", retCode, comment);
         return false;
      }
   }
   return false;
}

bool POI_BuyWithRetry(double sl, double legBasePrice, double poiSizePrice, double tpMult, string comment)
{
   if(POI_HasActiveExposureByMagic()) return false;
   if(!POI_IsSpreadOK()) return false;

   sl = POI_NormalizePrice(sl);
   double stopLevel  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double initialAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(stopLevel > 0 && MathAbs(initialAsk - sl) < stopLevel)
   {
      PrintFormat("POI BUY ABORT STOP_LEVEL: dist=%.0fpts < min=%.0fpts ask=%.2f sl=%.2f cmt=%s",
                  MathAbs(initialAsk - sl) / _Point, stopLevel / _Point, initialAsk, sl, comment);
      return false;
   }

   int maxTries = 1 + MathMax(0, OrderRetries);
   PrintFormat("POI BUY MKT INIT: %s refAsk=%.2f sl=%.2f tpMult=%.1f maxTries=%d cmt=%s",
               POI_BarStamp(), initialAsk, sl, tpMult, maxTries, comment);

   POI_ResetSessionStatsIfNewDay();
   poi_sessionRequests++;

   double prevLots   = -1.0;
   double currentAsk = initialAsk;

   for(int attempt = 1; attempt <= maxTries; attempt++)
   {
      if(attempt > 1) Sleep(150);
      currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(!POI_IsSpreadOK())
      {
         PrintFormat("POI BUY ABORT spread alargou: tentativa=%d ask=%.2f", attempt, currentAsk);
         return false;
      }

      double actualRisk = MathAbs(currentAsk - sl);
      if(actualRisk <= 0 || currentAsk <= sl)
      {
         PrintFormat("POI BUY ABORT preco passou SL: ask=%.2f sl=%.2f tentativa=%d", currentAsk, sl, attempt);
         return false;
      }
      if(stopLevel > 0 && actualRisk < stopLevel)
      {
         PrintFormat("POI BUY ABORT stopLevel mid-retry: dist=%.0f min=%.0f tentativa=%d",
                     actualRisk / _Point, stopLevel / _Point, attempt);
         return false;
      }

      double tp          = POI_ComputeBuyTP(currentAsk, sl, legBasePrice, poiSizePrice, tpMult);
      double currentLots = POI_CalculateLots(POI_RiskForSizing(actualRisk, sl, legBasePrice), attempt == 1);

      if(currentLots <= 0)
      {
         PrintFormat("POI BUY ABORT lots=0 mid-retry: riskPts=%.0f ask=%.2f tentativa=%d",
                     actualRisk / _Point, currentAsk, attempt);
         return false;
      }
      if(attempt > 1 && prevLots > 0 && MathAbs(currentLots - prevLots) > 0.001)
         PrintFormat("POI BUY lots ajustado mid-retry: %.2f -> %.2f tentativa=%d",
                     prevLots, currentLots, attempt);
      prevLots = currentLots;

      if(!POI_CheckMargin(ORDER_TYPE_BUY, currentLots, currentAsk)) return false;
      if(POI_HasActiveExposureByMagic())
      {
         PrintFormat("POI BUY ABORT exposure mid-retry (race): tentativa=%d", attempt);
         return false;
      }

      if(trade.Buy(currentLots, _Symbol, currentAsk, sl, tp, comment))
      {
         double fillPx = trade.ResultPrice();
         double filled = trade.ResultVolume();
         ulong  ordTkt = trade.ResultOrder();
         PrintFormat("POI BUY MKT OK: %s req=%.2f fill=%.2f sl=%.2f tp=%.2f lots=%.2f order=%I64u tpMult=%.1f tentativa=%d/%d cmt=%s",
                     POI_BarStamp(), currentAsk, fillPx, sl, tp, filled, ordTkt, tpMult, attempt, maxTries, comment);
         if(filled < currentLots - 0.001)
            PrintFormat("POI BUY MKT PARCIAL: pediu=%.2f preencheu=%.2f cmt=%s",
                        currentLots, filled, comment);
         poi_sessionFills++;
         return true;
      }
      int retCode = (int)trade.ResultRetcode();
      PrintFormat("POI BUY falhou (%d/%d): retcode=%d %s ask=%.2f cmt=%s",
                  attempt, maxTries, retCode, trade.ResultRetcodeDescription(), currentAsk, comment);
      if(POI_IsFatalRetcode(retCode))
      {
         PrintFormat("POI BUY ABORT retcode FATAL=%d cmt=%s", retCode, comment);
         return false;
      }
   }
   return false;
}

bool POI_SellWithRetry(double sl, double legBasePrice, double poiSizePrice, double tpMult, string comment)
{
   if(POI_HasActiveExposureByMagic()) return false;
   if(!POI_IsSpreadOK()) return false;

   sl = POI_NormalizePrice(sl);
   double stopLevel  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double initialBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(stopLevel > 0 && MathAbs(initialBid - sl) < stopLevel)
   {
      PrintFormat("POI SELL ABORT STOP_LEVEL: dist=%.0fpts < min=%.0fpts bid=%.2f sl=%.2f cmt=%s",
                  MathAbs(initialBid - sl) / _Point, stopLevel / _Point, initialBid, sl, comment);
      return false;
   }

   int maxTries = 1 + MathMax(0, OrderRetries);
   PrintFormat("POI SELL MKT INIT: %s refBid=%.2f sl=%.2f tpMult=%.1f maxTries=%d cmt=%s",
               POI_BarStamp(), initialBid, sl, tpMult, maxTries, comment);

   POI_ResetSessionStatsIfNewDay();
   poi_sessionRequests++;

   double prevLots   = -1.0;
   double currentBid = initialBid;

   for(int attempt = 1; attempt <= maxTries; attempt++)
   {
      if(attempt > 1) Sleep(150);
      currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(!POI_IsSpreadOK())
      {
         PrintFormat("POI SELL ABORT spread alargou: tentativa=%d bid=%.2f", attempt, currentBid);
         return false;
      }

      double actualRisk = MathAbs(currentBid - sl);
      if(actualRisk <= 0 || currentBid >= sl)
      {
         PrintFormat("POI SELL ABORT preco passou SL: bid=%.2f sl=%.2f tentativa=%d", currentBid, sl, attempt);
         return false;
      }
      if(stopLevel > 0 && actualRisk < stopLevel)
      {
         PrintFormat("POI SELL ABORT stopLevel mid-retry: dist=%.0f min=%.0f tentativa=%d",
                     actualRisk / _Point, stopLevel / _Point, attempt);
         return false;
      }

      double tp          = POI_ComputeSellTP(currentBid, sl, legBasePrice, poiSizePrice, tpMult);
      double currentLots = POI_CalculateLots(POI_RiskForSizing(actualRisk, sl, legBasePrice), attempt == 1);

      if(currentLots <= 0)
      {
         PrintFormat("POI SELL ABORT lots=0 mid-retry: riskPts=%.0f bid=%.2f tentativa=%d",
                     actualRisk / _Point, currentBid, attempt);
         return false;
      }
      if(attempt > 1 && prevLots > 0 && MathAbs(currentLots - prevLots) > 0.001)
         PrintFormat("POI SELL lots ajustado mid-retry: %.2f -> %.2f tentativa=%d",
                     prevLots, currentLots, attempt);
      prevLots = currentLots;

      if(!POI_CheckMargin(ORDER_TYPE_SELL, currentLots, currentBid)) return false;
      if(POI_HasActiveExposureByMagic())
      {
         PrintFormat("POI SELL ABORT exposure mid-retry (race): tentativa=%d", attempt);
         return false;
      }

      if(trade.Sell(currentLots, _Symbol, currentBid, sl, tp, comment))
      {
         double fillPx = trade.ResultPrice();
         double filled = trade.ResultVolume();
         ulong  ordTkt = trade.ResultOrder();
         PrintFormat("POI SELL MKT OK: %s req=%.2f fill=%.2f sl=%.2f tp=%.2f lots=%.2f order=%I64u tpMult=%.1f tentativa=%d/%d cmt=%s",
                     POI_BarStamp(), currentBid, fillPx, sl, tp, filled, ordTkt, tpMult, attempt, maxTries, comment);
         if(filled < currentLots - 0.001)
            PrintFormat("POI SELL MKT PARCIAL: pediu=%.2f preencheu=%.2f cmt=%s",
                        currentLots, filled, comment);
         poi_sessionFills++;
         return true;
      }
      int retCode = (int)trade.ResultRetcode();
      PrintFormat("POI SELL falhou (%d/%d): retcode=%d %s bid=%.2f cmt=%s",
                  attempt, maxTries, retCode, trade.ResultRetcodeDescription(), currentBid, comment);
      if(POI_IsFatalRetcode(retCode))
      {
         PrintFormat("POI SELL ABORT retcode FATAL=%d cmt=%s", retCode, comment);
         return false;
      }
   }
   return false;
}

#endif
