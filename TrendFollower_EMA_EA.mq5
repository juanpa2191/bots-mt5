//+------------------------------------------------------------------+
//|                        TrendFollower_EMA_EA.mq5                  |
//|  Expert Advisor — EMA + RSI + ATR + Cierre por Tiempo  v4.0     |
//|  Plataforma: MetaTrader 5 | Instrumento: EURUSD | M5             |
//+------------------------------------------------------------------+
#property copyright   "TrendFollower EA v4.0"
#property link        ""
#property version     "4.00"
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
input int                InpRsiBuyMin        = 40;
input int                InpRsiBuyMax        = 65;
input int                InpRsiSellMin       = 35;
input int                InpRsiSellMax       = 60;
input bool               InpUseRsiFilter     = true;

input group              "=== GESTIÓN DE RIESGO ==="
input double             InpLotSize          = 0.10;
input int                InpStopLossPips     = 20;

input group              "=== TP DINÁMICO (ATR) ==="
input bool               InpUseDynamicTP     = true;
input int                InpAtrTpPeriod      = 14;
input double             InpAtrTpMultiplier  = 3.0;
input int                InpMinTpPips        = 20;
input int                InpMaxTpPips        = 80;
input int                InpFixedTpPips      = 30;

input group              "=== ATR TRAILING STOP ==="
input bool               InpUseTrailing      = true;
input int                InpAtrTrailPeriod   = 14;
input double             InpAtrMultiplier    = 1.5;
input int                InpMinProfitPips    = 15;
input int                InpTrailingStep     = 5;

input group              "=== CIERRE AUTOMÁTICO POR TIEMPO ==="
input bool               InpUseTimeClose     = true;          // Activar cierre por tiempo
input int                InpMaxMinutes       = 60;            // Tiempo máximo en minutos
input int                InpMinProfitToKeep  = 10;            // Ganancia mínima para NO cerrar por tiempo (pips)

input group              "=== FILTRO DE SPREAD ==="
input int                InpMaxSpreadPips    = 15;

input group              "=== SESIÓN DE LONDRES (GMT) ==="
input int                InpLondonStartHour  = 8;
input int                InpLondonEndHour    = 17;

input group              "=== SESIÓN DE NUEVA YORK (GMT) ==="
input int                InpNewYorkStartHour = 13;
input int                InpNewYorkEndHour   = 22;

input group              "=== CONFIGURACIÓN GENERAL ==="
input ulong              InpMagicNumber      = 20240101;
input string             InpTradeComment     = "TrendEA_v4";
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

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pointMultiplier = (digits == 5 || digits == 3) ? 10.0 : 1.0;
   pipValue = _Point * pointMultiplier;

   handleEmaFast  = iMA  (_Symbol, PERIOD_M5, InpEmaFastPeriod, 0, InpMaMethod, InpAppliedPrice);
   handleEmaSlow  = iMA  (_Symbol, PERIOD_M5, InpEmaSlowPeriod, 0, InpMaMethod, InpAppliedPrice);
   handleRsi      = iRSI (_Symbol, PERIOD_M5, InpRsiPeriod, InpAppliedPrice);
   handleAtrTp    = iATR (_Symbol, PERIOD_M5, InpAtrTpPeriod);
   handleAtrTrail = iATR (_Symbol, PERIOD_M5, InpAtrTrailPeriod);

   if(handleEmaFast  == INVALID_HANDLE || handleEmaSlow  == INVALID_HANDLE ||
      handleRsi      == INVALID_HANDLE || handleAtrTp    == INVALID_HANDLE ||
      handleAtrTrail == INVALID_HANDLE)
   {
      Print("[ERROR] No se pudo crear handle de indicadores.");
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(30);
   Trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("[INFO] EA v4.0 iniciado");
   Print("[INFO] EMA: ", InpEmaFastPeriod, "/", InpEmaSlowPeriod,
         " | RSI: ",     InpUseRsiFilter  ? "ON" : "OFF",
         " | TP din: ",  InpUseDynamicTP  ? "ON (ATRx"+DoubleToString(InpAtrTpMultiplier,1)+")" : "OFF",
         " | Trailing: ",InpUseTrailing   ? "ON" : "OFF",
         " | CierreTiempo: ", InpUseTimeClose ? "ON ("+IntegerToString(InpMaxMinutes)+"min)" : "OFF");

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
   Print("[INFO] EA v4.0 detenido.");
}

//+------------------------------------------------------------------+
//|  OnTick — Lógica principal                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Gestión de posiciones abiertas (cada tick) ---
   if(HasOpenPosition())
   {
      // 1. Verificar cierre por tiempo (prioridad alta)
      if(InpUseTimeClose)
         CheckTimeClose();

      // 2. Gestionar trailing stop (si sigue abierta)
      if(InpUseTrailing && HasOpenPosition())
         ManageTrailingStop();
   }

   // --- Lógica de entrada: solo en nueva vela cerrada ---
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   if(!CheckServerConnection()) return;
   if(!CheckSpread())           return;
   if(!IsSessionActive())       return;

   double emaFastCurr, emaFastPrev, emaSlowCurr, emaSlowPrev;
   if(!GetEmaValues(emaFastCurr, emaFastPrev, emaSlowCurr, emaSlowPrev))
      return;

   double rsiValue;
   if(!GetRsiValue(rsiValue))
      return;

   double closePrev = iClose(_Symbol, PERIOD_M5, 1);
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
//|  CheckTimeClose — Cierre automático por tiempo                  |
//|                                                                  |
//|  Evalúa cada posición abierta del EA:                           |
//|  - Si lleva más de InpMaxMinutes abierta                        |
//|    Y la ganancia es menor a InpMinProfitToKeep pips             |
//|    → Cierra la posición inmediatamente                          |
//|  - Si la ganancia supera InpMinProfitToKeep pips                |
//|    → No cierra, deja actuar al trailing stop                    |
//+------------------------------------------------------------------+
void CheckTimeClose()
{
   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol) continue;
      if(PositionInfo.Magic()  != InpMagicNumber) continue;

      datetime openTime    = (datetime)PositionGetInteger(POSITION_TIME);
      ulong    ticket      = PositionInfo.Ticket();
      double   openPrice   = PositionInfo.PriceOpen();
      ENUM_POSITION_TYPE posType = PositionInfo.PositionType();

      // Calcular minutos transcurridos
      int minutesOpen = (int)((now - openTime) / 60);

      // Aún no cumple el tiempo mínimo
      if(minutesOpen < InpMaxMinutes)
         continue;

      // Calcular ganancia actual en pips
      double currentPips = 0;
      if(posType == POSITION_TYPE_BUY)
         currentPips = (SymbolInfoDouble(_Symbol, SYMBOL_BID) - openPrice) / pipValue;
      else
         currentPips = (openPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / pipValue;

      // Si la ganancia supera el mínimo → dejar que el trailing lo gestione
      if(currentPips >= InpMinProfitToKeep)
      {
         Print("[TIEMPO] Operación lleva ", minutesOpen, " min | +",
               NormalizeDouble(currentPips, 1), " pips → Ganancia suficiente, trailing activo.");
         continue;
      }

      // Cerrar la posición
      string resultado = currentPips >= 0
         ? "+" + DoubleToString(NormalizeDouble(currentPips, 1), 1) + " pips (ganancia)"
         : DoubleToString(NormalizeDouble(currentPips, 1), 1) + " pips (perdida)";

      if(Trade.PositionClose(ticket))
         Print("[TIEMPO] Operación CERRADA por tiempo | Duración: ", minutesOpen, " min",
               " | Resultado: ", resultado,
               " | Motivo: ", minutesOpen, " min sin alcanzar +", InpMinProfitToKeep, " pips");
      else
         Print("[ERROR] No se pudo cerrar por tiempo. Código: ", Trade.ResultRetcode());
   }
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
//|  ApplyRsiFilter — Confirma o cancela la señal según RSI         |
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

   Print("[ATR-TP] ATR: ", NormalizeDouble(atrPips, 1), "p → TP: ",
         NormalizeDouble(dynamicTp, 1), "p (ATRx", InpAtrTpMultiplier, ")");

   return dynamicTp * pipValue;
}

//+------------------------------------------------------------------+
//|  OpenPosition — Abre orden con SL fijo y TP dinámico            |
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
            " | Entrada: ",  entryPrice,
            " | SL: -",      InpStopLossPips, "p",
            " | TP: +",      NormalizeDouble(tpPips, 1), "p",
            " | R/R: 1:",    NormalizeDouble(rratio, 2),
            " | Tiempo max: ", InpMaxMinutes, "min",
            " | Trailing: +", InpMinProfitPips, "p");
   else
      Print("[ERROR] Fallo apertura. Código: ", Trade.ResultRetcode(),
            " | ", Trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//|  ManageTrailingStop — ATR Trailing dinámico                     |
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
               Print("[TRAIL] BUY SL → ", newSL,
                     " | +", NormalizeDouble((newSL-openPrice)/pipValue, 1), "p protegidos");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;
         if(profit < minProfitDist) continue;
         double newSL = NormalizeDouble(ask + trailingDistance, _Digits);
         if(newSL < currentSL - trailingStep || currentSL == 0)
            if(Trade.PositionModify(ticket, newSL, currentTP))
               Print("[TRAIL] SELL SL → ", newSL,
                     " | +", NormalizeDouble((openPrice-newSL)/pipValue, 1), "p protegidos");
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
//|  IsSessionActive                                                 |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeGMT(dt);
   int h = dt.hour;
   return (h >= InpLondonStartHour  && h < InpLondonEndHour) ||
          (h >= InpNewYorkStartHour && h < InpNewYorkEndHour);
}

//+------------------------------------------------------------------+
//|  CheckSpread                                                     |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   double spreadPips = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / pointMultiplier;
   return (spreadPips <= InpMaxSpreadPips);
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
   if(InpMinProfitToKeep < 0)
   { Print("[ERROR] Ganancia mínima para no cerrar debe ser >= 0."); return false; }
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
  NOVEDADES v4.0 — CIERRE AUTOMÁTICO POR TIEMPO
==================================================================

  NUEVO — CheckTimeClose():
    Se evalúa en cada tick mientras hay una posición abierta.

    Lógica completa:

    ¿La operación lleva más de InpMaxMinutes (60 min)?
         │
        NO  → No hace nada, sigue esperando
         │
        SÍ
         │
         ├── ¿Ganancia >= InpMinProfitToKeep (10 pips)?
         │        → NO CERRAR
         │          El trailing stop tomará el control
         │          Log: [TIEMPO] Ganancia suficiente, trailing activo
         │
         └── ¿Ganancia < 10 pips?  (incluso si es negativo)
                  → CERRAR AHORA
                    Log: [TIEMPO] Operación CERRADA por tiempo
                         Resultado: X pips (ganancia/perdida)

  ESCENARIOS REALES:

    Operación lleva 60 min, va en -8 pips
    → CIERRA con -8 pips (ahorra hasta 12 pips vs esperar SL)

    Operación lleva 60 min, va en +4 pips
    → CIERRA con +4 pips (capital libre para nueva señal)

    Operación lleva 60 min, va en +18 pips
    → NO CIERRA, trailing activo protege los +18 pips

    Operación lleva 45 min, va en -15 pips
    → NO CIERRA aún (no cumple 60 min), SL fijo protege

==================================================================
  FLUJO COMPLETO v4.0 POR CADA TICK
==================================================================

  OnTick()
    │
    ├── ¿Hay posición abierta?
    │       │
    │       ├── CheckTimeClose()   ← NUEVO v4.0
    │       │     ¿>60 min y <10p? → cierra
    │       │
    │       └── ManageTrailingStop()
    │             ¿>15p ganancia?  → mueve SL
    │
    └── ¿Nueva vela M5?
            │
            ├── Validaciones (conexión, spread, sesión)
            ├── GetEntrySignal()   ← cruce EMA
            ├── ApplyRsiFilter()   ← confirma con RSI
            └── ¿Sin posición? → OpenPosition()
                  TP = ATR × 3.0 (dinámico)
                  SL = 20 pips (fijo)

==================================================================
  PARÁMETROS RECOMENDADOS v4.0
==================================================================

  EMA rápida              : 20
  EMA lenta               : 50
  RSI período             : 14
  RSI rango BUY           : 40 – 65
  RSI rango SELL          : 35 – 60
  Stop Loss               : 20 pips
  TP dinámico             : ON  (ATR x 3.0)
  TP mínimo               : 20 pips
  TP máximo               : 80 pips
  Trailing                : ON  (ATR x 1.5, activa desde +15p)
  Cierre por tiempo       : ON
  Tiempo máximo           : 60 minutos
  Ganancia mín para quedar: 10 pips
  Lote                    : 0.01 demo / calcular para real
  Spread máximo           : 15 pips

==================================================================
  LECTURA DE LOGS EN PESTAÑA "EXPERTOS"
==================================================================

  [INFO]   → inicio del EA y configuración
  [RSI]    → señal confirmada o bloqueada
  [ATR-TP] → TP calculado dinámicamente
  [TRADE]  → operación abierta
  [TRAIL]  → SL movido por trailing
  [TIEMPO] → cierre por tiempo o notificación de ganancia suficiente
  [WARN]   → advertencia no crítica
  [ERROR]  → error que impide operar

==================================================================
  INSTALACIÓN
==================================================================

  1. Elimina archivos anteriores (.mq5 y .ex5) de MQL5\Experts\
  2. Copia este archivo en MQL5\Experts\
  3. MetaEditor (F4) → compilar F7 → 0 errors, 0 warnings
  4. Arrastra al gráfico EURUSD M5
  5. Activa "Permitir comercio algorítmico"
  6. Activa botón "Trading algorítmico" en barra de MT5

  Si el broker retorna error 10030:
    Cambia ORDER_FILLING_FOK por ORDER_FILLING_IOC en OnInit()

==================================================================
*/
