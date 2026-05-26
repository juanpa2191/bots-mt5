//+------------------------------------------------------------------+
//|                        TrendFollower_BTC_EA.mq5                  |
//|   Expert Advisor — BTC/USD 24/7 | EMA+RSI+ATR+Tiempo  v1.0      |
//|   Plataforma: MetaTrader 5 | Instrumento: BTCUSD | M15           |
//+------------------------------------------------------------------+
#property copyright   "TrendFollower BTC EA v1.0"
#property link        ""
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  PARÁMETROS EXTERNOS                                             |
//+------------------------------------------------------------------+

input group              "=== MEDIAS MÓVILES ==="
input int                InpEmaFastPeriod    = 20;
input int                InpEmaSlowPeriod    = 50;
input ENUM_MA_METHOD     InpMaMethod         = MODE_EMA;
input ENUM_APPLIED_PRICE InpAppliedPrice     = PRICE_CLOSE;

input group              "=== RSI — FILTRO DE ENTRADA ==="
input int                InpRsiPeriod        = 14;
input int                InpRsiBuyMin        = 40;           // RSI mínimo para BUY
input int                InpRsiBuyMax        = 65;           // RSI máximo para BUY
input int                InpRsiSellMin       = 35;           // RSI mínimo para SELL
input int                InpRsiSellMax       = 60;           // RSI máximo para SELL
input bool               InpUseRsiFilter     = true;

input group              "=== GESTIÓN DE RIESGO ==="
input double             InpLotSize          = 0.01;         // Lote pequeño para BTC
input int                InpStopLossPips     = 200;          // SL amplio por volatilidad BTC

input group              "=== TP DINÁMICO (ATR) ==="
input bool               InpUseDynamicTP     = true;
input int                InpAtrTpPeriod      = 14;
input double             InpAtrTpMultiplier  = 3.0;          // TP = ATR × 3
input int                InpMinTpPips        = 200;          // TP mínimo 200 pips
input int                InpMaxTpPips        = 1500;         // TP máximo 1500 pips
input int                InpFixedTpPips      = 400;          // TP fijo si no usa dinámico

input group              "=== ATR TRAILING STOP ==="
input bool               InpUseTrailing      = true;
input int                InpAtrTrailPeriod   = 14;
input double             InpAtrMultiplier    = 1.5;          // Trailing = ATR × 1.5
input int                InpMinProfitPips    = 150;          // Ganancia mínima para activar trailing
input int                InpTrailingStep     = 50;           // Step mínimo para mover SL (pips)

input group              "=== CIERRE AUTOMÁTICO POR TIEMPO ==="
input bool               InpUseTimeClose     = true;
input int                InpMaxMinutes       = 240;          // 4 horas para BTC
input int                InpMinProfitToKeep  = 100;          // Ganancia mínima para NO cerrar (pips)

input group              "=== FILTRO DE SPREAD ==="
input int                InpMaxSpreadPips    = 100;          // Spread más amplio para BTC

input group              "=== OPERACIÓN 24/7 ==="
input bool               InpTrade247         = true;         // true = opera todo el día sin filtro horario
input int                InpStartHour        = 0;            // Hora inicio si 24/7 = false
input int                InpEndHour          = 24;           // Hora fin si 24/7 = false

input group              "=== CONFIGURACIÓN GENERAL ==="
input ulong              InpMagicNumber      = 20240202;     // Magic diferente al de EURUSD
input string             InpTradeComment     = "BTC_EA_v1";
input bool               InpAllowBuy         = true;
input bool               InpAllowSell        = true;

//+------------------------------------------------------------------+
//|  VARIABLES GLOBALES                                              |
//+------------------------------------------------------------------+

CTrade        Trade;
CPositionInfo PositionInfo;

int    handleEmaFast;
int    handleEmaSlow;
int    handleRsi;
int    handleAtrTp;
int    handleAtrTrail;

double pipValue;
double pointMultiplier;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateEnvironment())
      return INIT_FAILED;

   // BTC generalmente tiene 2 decimales → 1 punto = 0.01
   // Pip para BTC = 1 dólar de movimiento = 100 puntos en brokers con 2 decimales
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 2)
      pointMultiplier = 100.0;    // BTCUSD con 2 decimales
   else if(digits == 3)
      pointMultiplier = 10.0;
   else
      pointMultiplier = 1.0;

   pipValue = _Point * pointMultiplier;

   // Crear handles de indicadores en M15
   handleEmaFast  = iMA  (_Symbol, PERIOD_M15, InpEmaFastPeriod, 0, InpMaMethod, InpAppliedPrice);
   handleEmaSlow  = iMA  (_Symbol, PERIOD_M15, InpEmaSlowPeriod, 0, InpMaMethod, InpAppliedPrice);
   handleRsi      = iRSI (_Symbol, PERIOD_M15, InpRsiPeriod, InpAppliedPrice);
   handleAtrTp    = iATR (_Symbol, PERIOD_M15, InpAtrTpPeriod);
   handleAtrTrail = iATR (_Symbol, PERIOD_M15, InpAtrTrailPeriod);

   if(handleEmaFast  == INVALID_HANDLE || handleEmaSlow  == INVALID_HANDLE ||
      handleRsi      == INVALID_HANDLE || handleAtrTp    == INVALID_HANDLE ||
      handleAtrTrail == INVALID_HANDLE)
   {
      Print("[ERROR] No se pudo crear handle de indicadores.");
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(100);   // Mayor slippage permitido para BTC
   Trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("[INFO] BTC EA v1.0 iniciado en ", _Symbol, " M15");
   Print("[INFO] Operación: ", InpTrade247 ? "24/7 SIN filtro horario" : "Con filtro horario");
   Print("[INFO] SL: ", InpStopLossPips, "p | TP din: ATRx", InpAtrTpMultiplier,
         " (", InpMinTpPips, "-", InpMaxTpPips, "p)",
         " | Trailing desde +", InpMinProfitPips, "p",
         " | Tiempo max: ", InpMaxMinutes, "min");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleEmaFast  != INVALID_HANDLE) IndicatorRelease(handleEmaFast);
   if(handleEmaSlow  != INVALID_HANDLE) IndicatorRelease(handleEmaSlow);
   if(handleRsi      != INVALID_HANDLE) IndicatorRelease(handleRsi);
   if(handleAtrTp    != INVALID_HANDLE) IndicatorRelease(handleAtrTp);
   if(handleAtrTrail != INVALID_HANDLE) IndicatorRelease(handleAtrTrail);
   Print("[INFO] BTC EA detenido.");
}

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gestión de posiciones abiertas (cada tick)
   if(HasOpenPosition())
   {
      if(InpUseTimeClose)
         CheckTimeClose();

      if(InpUseTrailing && HasOpenPosition())
         ManageTrailingStop();
   }

   // Lógica de entrada: solo en nueva vela M15 cerrada
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   if(!CheckServerConnection()) return;
   if(!CheckSpread())           return;
   if(!IsSessionActive())       return;   // Siempre true si InpTrade247 = true

   double emaFastCurr, emaFastPrev, emaSlowCurr, emaSlowPrev;
   if(!GetEmaValues(emaFastCurr, emaFastPrev, emaSlowCurr, emaSlowPrev))
      return;

   double rsiValue;
   if(!GetRsiValue(rsiValue))
      return;

   double closePrev = iClose(_Symbol, PERIOD_M15, 1);

   ENUM_ORDER_TYPE signal = GetEntrySignal(closePrev,
                                            emaFastCurr, emaFastPrev,
                                            emaSlowCurr, emaSlowPrev);

   if(InpUseRsiFilter && signal != (ENUM_ORDER_TYPE)-1)
      signal = ApplyRsiFilter(signal, rsiValue);

   if(!HasOpenPosition())
   {
      if(signal == ORDER_TYPE_BUY  && InpAllowBuy)  OpenPosition(ORDER_TYPE_BUY);
      else if(signal == ORDER_TYPE_SELL && InpAllowSell) OpenPosition(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//|  IsSessionActive — 24/7 o con filtro horario opcional           |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   // Si 24/7 está activado, siempre retorna true
   if(InpTrade247)
      return true;

   // Filtro horario opcional (por si se quiere restringir)
   MqlDateTime dt;
   TimeGMT(dt);
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
}

//+------------------------------------------------------------------+
//|  GetEntrySignal — Cruce de EMAs                                 |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal(double closePrev,
                                double emaFast,  double emaFastPrev,
                                double emaSlow,  double emaSlowPrev)
{
   bool emaCrossUp     = (emaFastPrev <= emaSlowPrev) && (emaFast > emaSlow);
   bool priceAboveSlow = (closePrev > emaSlow);
   if(emaCrossUp && priceAboveSlow) return ORDER_TYPE_BUY;

   bool emaCrossDown   = (emaFastPrev >= emaSlowPrev) && (emaFast < emaSlow);
   bool priceBelowSlow = (closePrev < emaSlow);
   if(emaCrossDown && priceBelowSlow) return ORDER_TYPE_SELL;

   return (ENUM_ORDER_TYPE)-1;
}

//+------------------------------------------------------------------+
//|  ApplyRsiFilter                                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE ApplyRsiFilter(ENUM_ORDER_TYPE signal, double rsi)
{
   if(signal == ORDER_TYPE_BUY)
   {
      if(rsi >= InpRsiBuyMin && rsi <= InpRsiBuyMax)
      {
         Print("[RSI] BUY confirmado | RSI: ", NormalizeDouble(rsi, 1));
         return ORDER_TYPE_BUY;
      }
      Print("[RSI] BUY BLOQUEADO | RSI: ", NormalizeDouble(rsi, 1),
            " (rango: ", InpRsiBuyMin, "-", InpRsiBuyMax, ")");
      return (ENUM_ORDER_TYPE)-1;
   }

   if(signal == ORDER_TYPE_SELL)
   {
      if(rsi >= InpRsiSellMin && rsi <= InpRsiSellMax)
      {
         Print("[RSI] SELL confirmado | RSI: ", NormalizeDouble(rsi, 1));
         return ORDER_TYPE_SELL;
      }
      Print("[RSI] SELL BLOQUEADO | RSI: ", NormalizeDouble(rsi, 1),
            " (rango: ", InpRsiSellMin, "-", InpRsiSellMax, ")");
      return (ENUM_ORDER_TYPE)-1;
   }

   return (ENUM_ORDER_TYPE)-1;
}

//+------------------------------------------------------------------+
//|  CalculateDynamicTP — TP basado en ATR × multiplicador          |
//+------------------------------------------------------------------+
double CalculateDynamicTP()
{
   if(!InpUseDynamicTP)
      return InpFixedTpPips * pipValue;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(handleAtrTp, 0, 1, 1, atrBuffer) < 1)
   {
      Print("[WARN] No se pudo leer ATR para TP. Usando TP fijo.");
      return InpFixedTpPips * pipValue;
   }

   double atrPips   = atrBuffer[0] / pipValue;
   double dynamicTp = atrPips * InpAtrTpMultiplier;
   dynamicTp = MathMax(dynamicTp, InpMinTpPips);
   dynamicTp = MathMin(dynamicTp, InpMaxTpPips);

   Print("[ATR-TP] ATR: $", NormalizeDouble(atrBuffer[0], 2),
         " (", NormalizeDouble(atrPips, 1), "p) → TP: ",
         NormalizeDouble(dynamicTp, 1), "p = $",
         NormalizeDouble(dynamicTp * pipValue / _Point * InpLotSize, 2));

   return dynamicTp * pipValue;
}

//+------------------------------------------------------------------+
//|  OpenPosition                                                    |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   double tpDistance = CalculateDynamicTP();
   double slDistance = InpStopLossPips * pipValue;
   double entryPrice, slPrice, tpPrice;

   if(orderType == ORDER_TYPE_BUY)
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      slPrice    = entryPrice - slDistance;
      tpPrice    = entryPrice + tpDistance;
   }
   else
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      slPrice    = entryPrice + slDistance;
      tpPrice    = entryPrice - tpDistance;
   }

   slPrice    = NormalizeDouble(slPrice,    _Digits);
   tpPrice    = NormalizeDouble(tpPrice,    _Digits);
   entryPrice = NormalizeDouble(entryPrice, _Digits);

   double lotSize = NormalizeLotSize(InpLotSize);
   if(lotSize <= 0) { Print("[ERROR] Lote inválido."); return; }

   double tpPips = tpDistance / pipValue;
   double rratio = tpPips / InpStopLossPips;

   bool result = (orderType == ORDER_TYPE_BUY)
      ? Trade.Buy (lotSize, _Symbol, entryPrice, slPrice, tpPrice, InpTradeComment)
      : Trade.Sell(lotSize, _Symbol, entryPrice, slPrice, tpPrice, InpTradeComment);

   if(result)
      Print("[TRADE] ", EnumToString(orderType),
            " BTC | Entrada: $", entryPrice,
            " | SL: -", InpStopLossPips, "p ($", NormalizeDouble(slDistance, 2), ")",
            " | TP: +", NormalizeDouble(tpPips, 1), "p",
            " | R/R: 1:", NormalizeDouble(rratio, 2),
            " | Lote: ", lotSize);
   else
      Print("[ERROR] Fallo apertura. Código: ", Trade.ResultRetcode(),
            " | ", Trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//|  CheckTimeClose — Cierre automático por tiempo                  |
//+------------------------------------------------------------------+
void CheckTimeClose()
{
   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol) continue;
      if(PositionInfo.Magic()  != InpMagicNumber) continue;

      datetime openTime  = (datetime)PositionGetInteger(POSITION_TIME);
      ulong    ticket    = PositionInfo.Ticket();
      double   openPrice = PositionInfo.PriceOpen();
      ENUM_POSITION_TYPE posType = PositionInfo.PositionType();

      int minutesOpen = (int)((now - openTime) / 60);
      if(minutesOpen < InpMaxMinutes) continue;

      double currentPips = 0;
      if(posType == POSITION_TYPE_BUY)
         currentPips = (SymbolInfoDouble(_Symbol, SYMBOL_BID) - openPrice) / pipValue;
      else
         currentPips = (openPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / pipValue;

      if(currentPips >= InpMinProfitToKeep)
      {
         Print("[TIEMPO] BTC lleva ", minutesOpen, " min | +",
               NormalizeDouble(currentPips, 1), "p → Trailing activo, no cierra.");
         continue;
      }

      string resultado = currentPips >= 0
         ? "+" + DoubleToString(NormalizeDouble(currentPips, 1), 1) + "p (ganancia)"
         : DoubleToString(NormalizeDouble(currentPips, 1), 1) + "p (perdida)";

      if(Trade.PositionClose(ticket))
         Print("[TIEMPO] BTC CERRADO por tiempo | ", minutesOpen, " min | ",
               resultado, " | Limite: ", InpMaxMinutes, "min sin +",
               InpMinProfitToKeep, "p");
      else
         Print("[ERROR] No se pudo cerrar BTC por tiempo. Código: ", Trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//|  ManageTrailingStop                                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(handleAtrTrail, 0, 0, 1, atrBuffer) < 1) return;

   double trailingDistance = atrBuffer[0] * InpAtrMultiplier;
   double trailingStep     = InpTrailingStep * pipValue;
   double minProfitDist    = InpMinProfitPips * pipValue;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol) continue;
      if(PositionInfo.Magic()  != InpMagicNumber) continue;

      double openPrice = PositionInfo.PriceOpen();
      double currentSL = PositionInfo.StopLoss();
      double currentTP = PositionInfo.TakeProfit();
      ulong  ticket    = PositionInfo.Ticket();
      ENUM_POSITION_TYPE posType = PositionInfo.PositionType();

      if(posType == POSITION_TYPE_BUY)
      {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;
         if(profit < minProfitDist) continue;
         double newSL = NormalizeDouble(bid - trailingDistance, _Digits);
         if(newSL > currentSL + trailingStep)
            if(Trade.PositionModify(ticket, newSL, currentTP))
               Print("[TRAIL] BTC BUY SL → $", newSL,
                     " | +$", NormalizeDouble(newSL - openPrice, 2), " protegidos");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;
         if(profit < minProfitDist) continue;
         double newSL = NormalizeDouble(ask + trailingDistance, _Digits);
         if(newSL < currentSL - trailingStep || currentSL == 0)
            if(Trade.PositionModify(ticket, newSL, currentTP))
               Print("[TRAIL] BTC SELL SL → $", newSL,
                     " | +$", NormalizeDouble(openPrice - newSL, 2), " protegidos");
      }
   }
}

//+------------------------------------------------------------------+
//|  GetEmaValues                                                    |
//+------------------------------------------------------------------+
bool GetEmaValues(double &emaFastCurr, double &emaFastPrev,
                  double &emaSlowCurr, double &emaSlowPrev)
{
   double bufferFast[], bufferSlow[];
   ArraySetAsSeries(bufferFast, true);
   ArraySetAsSeries(bufferSlow, true);
   if(CopyBuffer(handleEmaFast, 0, 1, 2, bufferFast) < 2) return false;
   if(CopyBuffer(handleEmaSlow, 0, 1, 2, bufferSlow) < 2) return false;
   emaFastCurr = bufferFast[0]; emaFastPrev = bufferFast[1];
   emaSlowCurr = bufferSlow[0]; emaSlowPrev = bufferSlow[1];
   return true;
}

//+------------------------------------------------------------------+
//|  GetRsiValue                                                     |
//+------------------------------------------------------------------+
bool GetRsiValue(double &rsiValue)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handleRsi, 0, 1, 1, buffer) < 1)
   { Print("[WARN] No se pudo leer RSI."); return false; }
   rsiValue = buffer[0];
   return true;
}

//+------------------------------------------------------------------+
//|  HasOpenPosition                                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionInfo.SelectByIndex(i))
         if(PositionInfo.Symbol() == _Symbol && PositionInfo.Magic() == InpMagicNumber)
            return true;
   return false;
}

//+------------------------------------------------------------------+
//|  CheckSpread                                                     |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   double spreadPips = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / pointMultiplier;
   if(spreadPips > InpMaxSpreadPips)
   {
      Print("[SPREAD] Spread elevado: ", NormalizeDouble(spreadPips, 1),
            "p > máx ", InpMaxSpreadPips, "p");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//|  CheckServerConnection                                           |
//+------------------------------------------------------------------+
bool CheckServerConnection()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   { Print("[ERROR] Sin conexión."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   { Print("[ERROR] Trading no permitido."); return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   { Print("[ERROR] Activa Algo Trading."); return false; }
   return true;
}

//+------------------------------------------------------------------+
//|  ValidateEnvironment                                             |
//+------------------------------------------------------------------+
bool ValidateEnvironment()
{
   if(InpEmaFastPeriod <= 0 || InpEmaSlowPeriod <= 0)
   { Print("[ERROR] Períodos EMA inválidos."); return false; }
   if(InpEmaFastPeriod >= InpEmaSlowPeriod)
   { Print("[ERROR] EMA rápida debe ser < EMA lenta."); return false; }
   if(InpRsiPeriod <= 0)
   { Print("[ERROR] Período RSI inválido."); return false; }
   if(InpStopLossPips <= 0)
   { Print("[ERROR] SL debe ser > 0."); return false; }
   if(InpMinTpPips >= InpMaxTpPips)
   { Print("[ERROR] TP mínimo debe ser < TP máximo."); return false; }
   if(InpMaxMinutes <= 0)
   { Print("[ERROR] Tiempo máximo debe ser > 0."); return false; }
   if(InpLotSize <= 0)
   { Print("[ERROR] Lote debe ser > 0."); return false; }
   return true;
}

//+------------------------------------------------------------------+
//|  NormalizeLotSize                                                |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| FIN DEL CÓDIGO                                                  |
//+------------------------------------------------------------------+


/*
==================================================================
  TrendFollower BTC EA v1.0 — GUÍA COMPLETA
==================================================================

  DIFERENCIAS CLAVE vs el bot de EURUSD:
  ┌─────────────────────────────────────────────────────────┐
  │  Característica      EURUSD EA       BTC EA             │
  │  ─────────────────────────────────────────────────────  │
  │  Timeframe           M5              M15                 │
  │  Operación           Lun-Vie         24/7 365 días       │
  │  Filtro de sesión    Londres+NY      Desactivado         │
  │  Stop Loss           20 pips         200 pips            │
  │  TP mínimo           20 pips         200 pips            │
  │  TP máximo           80 pips         1500 pips           │
  │  Trailing activa     +15 pips        +150 pips           │
  │  Tiempo máximo       60 min          4 horas (240 min)   │
  │  Ganancia p/quedar   10 pips         100 pips            │
  │  Spread máximo       15 pips         100 pips            │
  │  Slippage permitido  3 pips          10 pips             │
  │  Lote sugerido       0.10            0.01                │
  │  Magic Number        20240101        20240202            │
  └─────────────────────────────────────────────────────────┘

  VENTAJA DE OPERAR BTC 24/7:
  - Mercado abierto domingos, feriados y madrugadas
  - Movimientos de $500-$3000 en un solo día
  - El robot captura tendencias nocturnas que EURUSD no puede
  - Puedes correr AMBOS bots simultáneamente sin conflicto
    (Magic Numbers diferentes: 20240101 vs 20240202)

==================================================================
  INSTALACIÓN PASO A PASO
==================================================================

  1. Copia TrendFollower_BTC_EA.mq5 en MQL5\Experts\
  2. Abre MetaEditor (F4) → compila con F7 → 0 errors, 0 warnings
  3. En MT5 abre un gráfico de BTCUSD en temporalidad M15
  4. Arrastra el EA al gráfico
  5. En "Parámetros de entrada" verifica:
     - Operación 24/7: true
     - Lote: 0.01 (para empezar en demo)
     - SL: 200 pips
  6. Activa "Permitir comercio algorítmico"
  7. Activa el botón "Trading algorítmico" en la barra de MT5

  IMPORTANTE: Aplica el bot en el gráfico BTCUSD M15
  NO en el mismo gráfico del EURUSD M5

==================================================================
  CORRER AMBOS BOTS AL MISMO TIEMPO
==================================================================

  Sí es posible y recomendado para diversificar:

  Gráfico 1: EURUSD M5  → TrendFollower_EMA_EA  (Magic: 20240101)
  Gráfico 2: BTCUSD M15 → TrendFollower_BTC_EA  (Magic: 20240202)

  Los Magic Numbers diferentes aseguran que cada bot
  gestione SOLO sus propias operaciones sin interferencia.

==================================================================
  SOBRE EL CÁLCULO DE PIPS EN BTC
==================================================================

  BTC en Deriv con 2 decimales:
    1 pip = $1.00 de movimiento en precio
    pipValue = _Point × 100 = 0.01 × 100 = $1.00

  Ejemplo con SL de 200 pips y lote 0.01:
    Pérdida máxima = 200 pips × $1.00 × 0.01 lote = $2.00

  Ejemplo con TP de 600 pips y lote 0.01:
    Ganancia potencial = 600 pips × $1.00 × 0.01 lote = $6.00

  SIEMPRE verifica el valor del pip en tu broker específico
  antes de operar en cuenta real.

==================================================================
  PARÁMETROS RECOMENDADOS BTC
==================================================================

  EMA rápida              : 20
  EMA lenta               : 50
  RSI período             : 14
  RSI rango BUY           : 40 – 65
  RSI rango SELL          : 35 – 60
  Stop Loss               : 200 pips
  TP dinámico             : ON (ATR × 3.0)
  TP mínimo               : 200 pips
  TP máximo               : 1500 pips
  Trailing                : ON (ATR × 1.5, activa desde +150p)
  Cierre por tiempo       : ON (240 min / 4 horas)
  Ganancia mín para quedar: 100 pips
  Operación 24/7          : true
  Lote                    : 0.01 (demo) / ajustar para real
  Spread máximo           : 100 pips

==================================================================
  ADVERTENCIAS ESPECÍFICAS PARA BTC
==================================================================

  1. VOLATILIDAD EXTREMA:
     BTC puede moverse $2000-$5000 en horas durante noticias.
     El SL de 200 pips puede activarse rápidamente.
     Considera reducir el lote al mínimo en cuenta demo primero.

  2. SPREADS VARIABLES:
     En momentos de alta volatilidad el spread puede superar
     100 pips. El robot pausará entradas automáticamente.

  3. LIQUIDEZ FINES DE SEMANA:
     BTC opera 24/7 pero los fines de semana hay menos liquidez.
     Considera activar InpTrade247 = false y ajustar horas
     si prefieres evitar fines de semana.

  4. LOTE MÍNIMO:
     En Deriv, BTC puede tener lote mínimo de 0.01.
     Verifica con: SymbolInfoDouble("BTCUSD", SYMBOL_VOLUME_MIN)

  5. ERROR 10030:
     Si el broker retorna error 10030 al abrir operaciones,
     cambia ORDER_FILLING_FOK por ORDER_FILLING_IOC en OnInit()

==================================================================
*/
