//+------------------------------------------------------------------+
//| Mayfly_Advanced_4_0_7.mqh                                       |
//| Description: Advanced Features for Mayfly 4.0.7                 |
//| Includes: Percent/Stoploss Trade Modes, Dynamic Grid, Pyramid Add Modes |
//+------------------------------------------------------------------+
#ifndef MAYFLY_ADVANCED_4_0_7_MQH
#define MAYFLY_ADVANCED_4_0_7_MQH

// 开仓模式枚举
enum ENUM_TRADE_MODE
{
   TRADE_MODE_FIXED = 0,           // 固定手数模式
   TRADE_MODE_PERCENT = 1,         // 资金百分比模式
   TRADE_MODE_STOPLOSS_PERCENT = 2 // 止损比例开仓模式
};

// 加仓模式枚举
enum ENUM_ADD_MODE
{
   ADD_MODE_UNIFORM = 0,    // 匀速加仓（默认）
   ADD_MODE_PYRAMID = 1,    // 正金字塔加仓
   ADD_MODE_INV_PYRAMID = 2 // 倒金字塔加仓
};

// 高级开仓模式的手数计算
double CalculateLotSizeAdvanced(double stopLossDistance, double price, ENUM_TRADE_MODE tradeMode)
{
   if(tradeMode == TRADE_MODE_FIXED)
      return NormalizeDouble(LotSize, 2);

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(accountBalance <= 0)
   {
      Log("跳过手数计算：账户余额为 0");
      return 0;
   }

   double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   if(leverage <= 0) leverage = 100;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginPerLot = (cachedContractSize * price) / leverage;
   double lotSize = 0.0;

   if(tradeMode == TRADE_MODE_PERCENT)
   {
      lotSize = (accountBalance * (PositionPercent / 100.0) * leverage) / marginPerLot;
   }
   else if(tradeMode == TRADE_MODE_STOPLOSS_PERCENT)
   {
      double maxLossAmount = accountBalance * (StopLossPercent / 100.0);
      double points = stopLossDistance / cachedTickSize;
      double lossPerLot = points * cachedTickValue;
      if(lossPerLot <= 0)
      {
         Log("跳过止损比例手数计算：lossPerLot=" + DoubleToString(lossPerLot, 2) + " 无效");
         return 0;
      }
      lotSize = maxLossAmount / lossPerLot;
   }
   else
   {
      Log("错误：未知的 TradeMode=" + EnumToString(tradeMode));
      return 0;
   }

   lotSize = MathMin(lotSize, freeMargin / marginPerLot);
   lotSize = MathMax(cachedMinLot, MathMin(cachedMaxLot, lotSize));
   lotSize = MathRound(lotSize / cachedLotStep) * cachedLotStep;
   lotSize = NormalizeDouble(lotSize, 2);

   return (tradeMode == TRADE_MODE_STOPLOSS_PERCENT && IsMiniLot) ? lotSize * 10.0 : lotSize;
}

//+------------------------------------------------------------------+
//| 高级加仓模式的手数调整                                           |
//+------------------------------------------------------------------+
double AdjustLotSizeByModeAdvanced(double baseLotSize, int addCount, double totalLots, ENUM_ADD_MODE addMode)
{
   if(totalLots + baseLotSize > MaxTotalLots)
   {
      Log("跳过手数调整：总手数 " + DoubleToString(totalLots + baseLotSize, 2) + 
          " 超过 MaxTotalLots=" + DoubleToString(MaxTotalLots, 2));
      return 0;
   }

   if(addMode == ADD_MODE_UNIFORM)
      return baseLotSize;

   if(addMode == ADD_MODE_PYRAMID)
   {
      double minLotSize = 0.01;
      double decrement = (AddPositionTimes > 1) ? (baseLotSize - minLotSize) / (AddPositionTimes - 1) : 0;
      return MathMax(minLotSize, baseLotSize - (decrement * addCount));
   }

   if(addMode == ADD_MODE_INV_PYRAMID)
   {
      int currentAddIndex = addCount + 1;
      double totalAddTimes = MathMin(AddPositionTimes, (int)(MaxTotalLots / baseLotSize));
      if(totalAddTimes <= 0)
      {
         Log("跳过倒金字塔手数调整：totalAddTimes=" + DoubleToString(totalAddTimes, 2) + " 无效");
         return 0;
      }
      return (baseLotSize / (totalAddTimes * (totalAddTimes + 1) / 2)) * currentAddIndex;
   }

   Log("错误：未知的 AddPositionMode=" + EnumToString(addMode));
   return 0;
}

//+------------------------------------------------------------------+
//| 动态网格更新                                                     |
//+------------------------------------------------------------------+
void UpdateDynamicGridAdvanced(int currentHour)
{
   bool isActiveZone = (currentHour >= ActiveZoneStartHour && currentHour < ActiveZoneEndHour);
   if(isActiveZone != lastActiveZoneState)
   {
      grid.GridStep = isActiveZone ? grid.originalGridStep * 2.0 : grid.originalGridStep;
      UpdateGridLevels();
      CleanupOrders();
      lastActiveZoneState = isActiveZone;
      Log("时区调整：isActiveZone=" + (isActiveZone ? "true" : "false") + 
          ", 新 GridStep=" + DoubleToString(grid.GridStep, precisionDigits));
   }

   if(!EnableDynamicGrid || GridSpacing > 0)
   {
      Log("跳过动态网格更新：EnableDynamicGrid=" + (EnableDynamicGrid ? "true" : "false") + 
          ", GridSpacing=" + DoubleToString(GridSpacing, precisionDigits));
      return;
   }

   double newAtrValue = GetATRValue(_Symbol, _Period, ATR_Period);
   if(newAtrValue <= 0 || newAtrValue == atrValue)
   {
      Log("跳过动态网格更新：newAtrValue=" + DoubleToString(newAtrValue, precisionDigits) + 
          " 未变化或无效");
      return;
   }

   grid.originalGridStep = NormalizeDouble(newAtrValue * 2.0, precisionDigits);
   grid.GridStep = isActiveZone ? grid.originalGridStep * 2.0 : grid.originalGridStep;
   UpdateGridLevels();
   CleanupOrders();
   atrValue = newAtrValue;
   Log("动态网格更新：新 GridStep=" + DoubleToString(grid.GridStep, precisionDigits));
}

#endif
//+------------------------------------------------------------------+
