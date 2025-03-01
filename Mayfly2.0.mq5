//+------------------------------------------------------------------+
//| Expert Advisor: Mayfly 2.0 System                                |
//| Description: Pre-set Stop Order Grid Trading System with Dynamic Base Price |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property link      "https://xai.com"
#property version   "2.8.5.4"

#include <Trade\Trade.mqh>

// 开仓模式枚举
enum ENUM_TRADE_MODE
{
   TRADE_MODE_FIXED = 0,  // 固定手数模式
   TRADE_MODE_PERCENT = 1 // 资金百分比模式
};

// 网格结构
struct GridStructure
{
   double basePrice;          // 基准价格
   double upperBound;         // 上边界
   double lowerBound;         // 下边界
   double upperGrid[];        // 上方网格价格数组
   double lowerGrid[];        // 下方网格价格数组
};

// 输入参数
input double GridSpacing = -1;        // 网格间距（点数），-1表示使用ATR
input double LotSize = 0.1;           // 固定手数（TradeMode = 0时启用）
input int GridLevels = 20;            // 网格数量（上下各多少格），默认20
input int StartHour = 15;             // 开始交易时间（小时，0-23），默认15点
input int EndHour = 20;               // 结束交易时间（小时，0-23），默认20点
input int ATR_Period = 14;            // ATR周期
input ENUM_TRADE_MODE TradeMode = TRADE_MODE_FIXED; // 开仓模式
input double StopLossPercent = 5.0;   // 每笔订单最大损失占账户余额的百分比，默认5%
input double InputBasePrice = 0;      // 用户手动输入的基准价格，默认0表示未输入
input bool EnableMirror = false;      // 是否开启镜像逻辑，默认关闭

// 全局变量
GridStructure grid;                   // 网格对象
double GridStep;                      // 网格间距
CTrade trade;                         // 交易对象
double atrValue;                      // 当前ATR值
ulong lastDealTicket = 0;             // 最后处理的成交票号
int precisionDigits;                  // 计算精度（比市场精度多一位）
const long MAGIC_NUMBER = StringToInteger("Mayfly2.0");  // 魔术号
string EXIT_SIGNAL;                   // 退出信号全局变量名称（图表特定）
string CLEANUP_DONE;                  // 清理完成标志全局变量名称（图表特定）
ENUM_POSITION_TYPE lastStopLossType = POSITION_TYPE_BUY;  // 最近止损的订单类型
bool stopLossDetected = false;        // 当前循环是否检测到止损
bool hasCleanedUpAfterEnd = false;    // 是否已执行过超出结束时间的清理
double lastStopLossPrice = 0;         // 最新止损/止盈价格

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("账户不允许交易");
      return(INIT_FAILED);
   }
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("市场未开放");
      return(INIT_FAILED);
   }
   
   long chartId = ChartID();
   string timeframe = EnumToString(_Period);
   EXIT_SIGNAL = "Mayfly2.0_" + _Symbol + "_" + timeframe + "_Exit_" + IntegerToString(chartId);
   CLEANUP_DONE = "Mayfly2.0_" + _Symbol + "_" + timeframe + "_CleanupDone_" + IntegerToString(chartId);
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            trade.OrderDelete(ticket);
         }
      }
   }
   
   GlobalVariableSet(EXIT_SIGNAL, 0);
   if(GlobalVariableCheck(CLEANUP_DONE))
      GlobalVariableDel(CLEANUP_DONE);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   precisionDigits = (int)MathCeil(-MathLog10(point)) - 1;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(InputBasePrice == 0)
   {
      double multiplier = MathPow(10, precisionDigits + 1);
      grid.basePrice = NormalizeDouble(MathFloor(currentPrice * multiplier) / multiplier, precisionDigits);
   }
   else
   {
      grid.basePrice = NormalizeDouble(InputBasePrice, precisionDigits);
   }
   
   if(GridSpacing > 0)
   {
      GridStep = NormalizeDouble(GridSpacing * point, precisionDigits);
   }
   else
   {
      atrValue = GetATRValue(_Symbol, PERIOD_H1, ATR_Period);
      GridStep = NormalizeDouble(atrValue > 0 ? atrValue * 2.0 : 0.01, precisionDigits);
   }
   
   // 初始化网格对象
   ArrayResize(grid.upperGrid, GridLevels);
   ArrayResize(grid.lowerGrid, GridLevels);
   for(int i = 0; i < GridLevels; i++)
   {
      grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * GridStep, precisionDigits);
      grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * GridStep, precisionDigits);
   }
   grid.upperBound = grid.upperGrid[GridLevels - 1];
   grid.lowerBound = grid.lowerGrid[GridLevels - 1];
   Print("网格初始化完成，上边界=", grid.upperBound, "，下边界=", grid.lowerBound);
   
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   Print("Mayfly 2.0 初始化完成，主人，准备好啦！镜像模式=", EnableMirror ? "开启" : "关闭");
   
   SetupGridOrders();
   DrawBasePriceLine();
   lastDealTicket = GetLastDealTicket();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(!GlobalVariableCheck(CLEANUP_DONE) || GlobalVariableGet(CLEANUP_DONE) != 1)
   {
      CleanupOrders();
   }
   ObjectDelete(0, "BasePriceLine");
   Print("Mayfly 2.0 停止运行，主人，下次见哦！原因代码=", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   int currentHour = timeStruct.hour;

   // 检查是否超过交易结束时间，只执行一次清理
   if(currentHour >= EndHour && !hasCleanedUpAfterEnd)
   {
      Print("嘿，主人！超过交易结束时间 (", EndHour, "点) 啦，赶紧平仓所有订单并取消所有挂单！");
      CloseAllPositions();
      CleanupOrders();
      hasCleanedUpAfterEnd = true;
      return;
   }

   // 如果在交易时间范围内，重置清理标志并正常运行
   if(currentHour >= StartHour && currentHour < EndHour)
   {
      hasCleanedUpAfterEnd = false;
   }
   else
   {
      return;  // 不在交易时间内，跳过后续逻辑
   }

   stopLossDetected = false;

   if(GlobalVariableGet(EXIT_SIGNAL) == 1)
   {
      Print("主人，检测到退出信号，清理订单并撤退啦！");
      CleanupOrders();
      ExpertRemove();
      return;
   }

   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   ulong currentDealTicket = GetLastDealTicket();
   if(currentDealTicket > lastDealTicket)
   {
      UpdateStopLosses();
      lastDealTicket = currentDealTicket;
   }

   int shift = 0;
   if(bidPrice >= grid.basePrice + GridStep)
      shift = (int)MathFloor((bidPrice - grid.basePrice) / GridStep);
   else if(bidPrice <= grid.basePrice - GridStep)
      shift = (int)MathCeil((bidPrice - grid.basePrice) / GridStep);

   if(shift != 0)
   {
      grid.basePrice = NormalizeDouble(grid.basePrice + shift * GridStep, precisionDigits);
      for(int i = 0; i < GridLevels; i++)
      {
         grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * GridStep, precisionDigits);
         grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * GridStep, precisionDigits);
      }
      grid.upperBound = grid.upperGrid[GridLevels - 1];
      grid.lowerBound = grid.lowerGrid[GridLevels - 1];
      AdjustGridOrders();
      DrawBasePriceLine();
   }

   CancelOrdersMatchingStopLoss();

   // 检查并补齐挂单
   CheckAndReplenishOrders();
}

//+------------------------------------------------------------------+
//| 检查并补齐挂单                                                    |
//+------------------------------------------------------------------+
void CheckAndReplenishOrders()
{
   int totalPositions = PositionsTotal();
   if(totalPositions >= GridLevels)
   {
      Print("主人，持仓已达上限=", GridLevels, "，不补挂单啦！");
      return;
   }

   bool allowBuy = !stopLossDetected || lastStopLossType != POSITION_TYPE_SELL;
   bool allowSell = !stopLossDetected || lastStopLossType != POSITION_TYPE_BUY;

   for(int i = 0; i < GridLevels; i++)
   {
      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(GridStep, sellPrice);

      if(EnableMirror)
      {
         // 镜像模式：在 sellPrice 挂 BuyLimit，在 buyPrice 挂 SellLimit
         double buyLimitTpPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
         if(lotSizeSell > 0 && allowBuy && !OrderExists(sellPrice, ORDER_TYPE_BUY_LIMIT) && 
            !PositionExists(sellPrice) && sellPrice != lastStopLossPrice)
         {
            trade.BuyLimit(lotSizeSell, sellPrice, _Symbol, 0, buyLimitTpPrice, ORDER_TIME_GTC, 0, "Buy Limit Grid (Mirror - Replenish)");
            Print("补挂 BuyLimit，价格=", sellPrice);
         }

         double sellLimitTpPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
         if(lotSizeBuy > 0 && allowSell && !OrderExists(buyPrice, ORDER_TYPE_SELL_LIMIT) && 
            !PositionExists(buyPrice) && buyPrice != lastStopLossPrice)
         {
            trade.SellLimit(lotSizeBuy, buyPrice, _Symbol, 0, sellLimitTpPrice, ORDER_TIME_GTC, 0, "Sell Limit Grid (Mirror - Replenish)");
            Print("补挂 SellLimit，价格=", buyPrice);
         }
      }
      else
      {
         // 非镜像模式：挂 BuyStop 和 SellStop
         double buySlPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
         if(lotSizeBuy > 0 && allowBuy && !OrderExists(buyPrice, ORDER_TYPE_BUY_STOP) && 
            !PositionExists(buyPrice) && buyPrice != lastStopLossPrice)
         {
            trade.BuyStop(lotSizeBuy, buyPrice, _Symbol, buySlPrice, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid (Replenish)");
            Print("补挂 BuyStop，价格=", buyPrice);
         }

         double sellSlPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
         if(lotSizeSell > 0 && allowSell && !OrderExists(sellPrice, ORDER_TYPE_SELL_STOP) && 
            !PositionExists(sellPrice) && sellPrice != lastStopLossPrice)
         {
            trade.SellStop(lotSizeSell, sellPrice, _Symbol, sellSlPrice, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid (Replenish)");
            Print("补挂 SellStop，价格=", sellPrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 平仓所有持仓订单                                                  |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int totalPositions = PositionsTotal();
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            if(!trade.PositionClose(ticket))
               Print("哎呀，平仓失败啦，票号=", ticket, "，错误代码=", GetLastError());
            else
               Print("顺利平仓，票号=", ticket, "，主人好棒！");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 清理所有挂单                                                      |
//+------------------------------------------------------------------+
void CleanupOrders()
{
   Print("主人，我在清理挂单啦，马上搞定！");
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            if(trade.OrderDelete(ticket))
               Print("挂单删除成功，票号=", ticket);
            else
               Print("挂单删除失败，票号=", ticket, "，错误代码=", GetLastError());
         }
      }
   }
   GlobalVariableSet(CLEANUP_DONE, 1);
   GlobalVariableSet(EXIT_SIGNAL, 0);
   Print("清理完成，主人，干得漂亮吧！");
}

//+------------------------------------------------------------------+
//| 绘制基准价格线                                                    |
//+------------------------------------------------------------------+
void DrawBasePriceLine()
{
   ObjectDelete(0, "BasePriceLine");
   
   ObjectCreate(0, "BasePriceLine", OBJ_HLINE, 0, 0, grid.basePrice);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
//| 获取最新成交票号                                                  |
//+------------------------------------------------------------------+
ulong GetLastDealTicket()
{
   if(!HistorySelect(TimeCurrent() - 3600, TimeCurrent()))
      return lastDealTicket;

   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0 && HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol && 
         HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MAGIC_NUMBER &&
         HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
      {
         return dealTicket;
      }
   }
   return lastDealTicket;
}

//+------------------------------------------------------------------+
//| 设置初始网格订单                                                  |
//+------------------------------------------------------------------+
void SetupGridOrders()
{
   int totalPositions = PositionsTotal();

   if(totalPositions >= GridLevels)
   {
      Print("主人，持仓已达上限=", GridLevels, "，先歇一歇吧！");
      return;
   }

   bool allowBuy = !stopLossDetected || lastStopLossType != POSITION_TYPE_SELL;
   bool allowSell = !stopLossDetected || lastStopLossType != POSITION_TYPE_BUY;

   for(int i = 0; i < GridLevels; i++)
   {
      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(GridStep, sellPrice);

      if(EnableMirror)
      {
         // 镜像模式：在 sellPrice 挂 BuyLimit，在 buyPrice 挂 SellLimit，止损改为止盈
         double buyLimitTpPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
         if(lotSizeSell > 0 && allowBuy && !OrderExists(sellPrice, ORDER_TYPE_BUY_LIMIT))
         {
            trade.BuyLimit(lotSizeSell, sellPrice, _Symbol, 0, buyLimitTpPrice, ORDER_TIME_GTC, 0, "Buy Limit Grid (Mirror)");
         }

         double sellLimitTpPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
         if(lotSizeBuy > 0 && allowSell && !OrderExists(buyPrice, ORDER_TYPE_SELL_LIMIT))
         {
            trade.SellLimit(lotSizeBuy, buyPrice, _Symbol, 0, sellLimitTpPrice, ORDER_TIME_GTC, 0, "Sell Limit Grid (Mirror)");
         }
      }
      else
      {
         // 非镜像模式：挂 BuyStop 和 SellStop，设置止损
         double buySlPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
         if(lotSizeBuy > 0 && allowBuy && !OrderExists(buyPrice, ORDER_TYPE_BUY_STOP))
         {
            trade.BuyStop(lotSizeBuy, buyPrice, _Symbol, buySlPrice, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid");
         }

         double sellSlPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
         if(lotSizeSell > 0 && allowSell && !OrderExists(sellPrice, ORDER_TYPE_SELL_STOP))
         {
            trade.SellStop(lotSizeSell, sellPrice, _Symbol, sellSlPrice, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 调整网格订单                                                      |
//+------------------------------------------------------------------+
void AdjustGridOrders()
{
   int totalPositions = PositionsTotal();

   if(totalPositions >= GridLevels)
   {
      Print("主人，持仓已达上限=", GridLevels, "，暂时不调整网格啦！");
      return;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            if(orderPrice > grid.upperBound || orderPrice < grid.lowerBound)
            {
               trade.OrderDelete(ticket);
            }
         }
      }
   }

   bool allowBuy = !stopLossDetected || lastStopLossType != POSITION_TYPE_SELL;
   bool allowSell = !stopLossDetected || lastStopLossType != POSITION_TYPE_BUY;

   for(int i = 0; i < GridLevels; i++)
   {
      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(GridStep, sellPrice);

      if(EnableMirror)
      {
         // 镜像模式：在 sellPrice 挂 BuyLimit，在 buyPrice 挂 SellLimit，止损改为止盈
         double buyLimitTpPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
         if(lotSizeSell > 0 && allowBuy && !OrderExists(sellPrice, ORDER_TYPE_BUY_LIMIT) && !PositionExists(sellPrice))
         {
            trade.BuyLimit(lotSizeSell, sellPrice, _Symbol, 0, buyLimitTpPrice, ORDER_TIME_GTC, 0, "Buy Limit Grid (Mirror)");
         }

         double sellLimitTpPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
         if(lotSizeBuy > 0 && allowSell && !OrderExists(buyPrice, ORDER_TYPE_SELL_LIMIT) && !PositionExists(buyPrice))
         {
            trade.SellLimit(lotSizeBuy, buyPrice, _Symbol, 0, sellLimitTpPrice, ORDER_TIME_GTC, 0, "Sell Limit Grid (Mirror)");
         }
      }
      else
      {
         // 非镜像模式：挂 BuyStop 和 SellStop，设置止损
         double buySlPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
         if(lotSizeBuy > 0 && allowBuy && !OrderExists(buyPrice, ORDER_TYPE_BUY_STOP) && !PositionExists(buyPrice))
         {
            trade.BuyStop(lotSizeBuy, buyPrice, _Symbol, buySlPrice, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid");
         }

         double sellSlPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
         if(lotSizeSell > 0 && allowSell && !OrderExists(sellPrice, ORDER_TYPE_SELL_STOP) && !PositionExists(sellPrice))
         {
            trade.SellStop(lotSizeSell, sellPrice, _Symbol, sellSlPrice, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 更新所有持仓止损（原有逻辑，镜像时改为止盈）                     |
//+------------------------------------------------------------------+
void UpdateStopLosses()
{
   int updated = 0;
   double lastBuyLimit = 0;
   double lastSellLimit = 0;
   datetime latestTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if(openTime > latestTime)
            {
               latestTime = openTime;
               if(EnableMirror)
               {
                  double tpPrice = PositionGetDouble(POSITION_TP);
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                     lastBuyLimit = tpPrice;
                  else
                     lastSellLimit = tpPrice;
                  lastStopLossPrice = tpPrice;  // 更新最新止盈价
               }
               else
               {
                  double slPrice = PositionGetDouble(POSITION_SL);
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                     lastBuyLimit = slPrice;
                  else
                     lastSellLimit = slPrice;
                  lastStopLossPrice = slPrice;  // 更新最新止损价
               }
            }
         }
      }
   }

   if(lastBuyLimit > 0 || lastSellLimit > 0)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
            {
               if(EnableMirror)
               {
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && lastBuyLimit > 0)
                  {
                     double newTpPrice = NormalizeDouble(lastBuyLimit, precisionDigits);
                     if(newTpPrice != PositionGetDouble(POSITION_TP))
                     {
                        if(trade.PositionModify(PositionGetTicket(i), 0, newTpPrice))
                           updated++;
                     }
                  }
                  else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && lastSellLimit > 0)
                  {
                     double newTpPrice = NormalizeDouble(lastSellLimit, precisionDigits);
                     if(newTpPrice != PositionGetDouble(POSITION_TP))
                     {
                        if(trade.PositionModify(PositionGetTicket(i), 0, newTpPrice))
                           updated++;
                     }
                  }
               }
               else
               {
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && lastBuyLimit > 0)
                  {
                     double newSlPrice = NormalizeDouble(lastBuyLimit, precisionDigits);
                     if(newSlPrice != PositionGetDouble(POSITION_SL))
                     {
                        if(trade.PositionModify(PositionGetTicket(i), newSlPrice, 0))
                           updated++;
                     }
                  }
                  else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && lastSellLimit > 0)
                  {
                     double newSlPrice = NormalizeDouble(lastSellLimit, precisionDigits);
                     if(newSlPrice != PositionGetDouble(POSITION_SL))
                     {
                        if(trade.PositionModify(PositionGetTicket(i), newSlPrice, 0))
                           updated++;
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 取消与持仓止损/止盈重合的挂单并记录类型                          |
//+------------------------------------------------------------------+
void CancelOrdersMatchingStopLoss()
{
   if(PositionsTotal() == 0) return;

   double stopLosses[];
   ArrayResize(stopLosses, PositionsTotal());
   int stopLossCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            if(EnableMirror)
               stopLosses[stopLossCount] = NormalizeDouble(PositionGetDouble(POSITION_TP), precisionDigits);
            else
               stopLosses[stopLossCount] = NormalizeDouble(PositionGetDouble(POSITION_SL), precisionDigits);
            stopLossCount++;
         }
      }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            for(int j = 0; j < stopLossCount; j++)
            {
               if(orderPrice == stopLosses[j])
               {
                  ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
                  if((EnableMirror && (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)) ||
                     (!EnableMirror && (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)))
                  {
                     stopLossDetected = true;
                     lastStopLossType = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_LIMIT) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
                     lastStopLossPrice = orderPrice;  // 记录触发止损/止盈的价格
                     Print("检测到", EnableMirror ? "止盈" : "止损", "，类型=", EnumToString(lastStopLossType), "，价格=", orderPrice);
                  }
                  trade.OrderDelete(ticket);
                  break;
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 检查订单是否已存在                                                |
//+------------------------------------------------------------------+
bool OrderExists(double price, ENUM_ORDER_TYPE orderType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_TYPE) == orderType && 
            NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), precisionDigits) == NormalizeDouble(price, precisionDigits))
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 检查持仓是否已存在                                                |
//+------------------------------------------------------------------+
bool PositionExists(double price)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER && 
            NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN), precisionDigits) == NormalizeDouble(price, precisionDigits))
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 计算手数函数                                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossDistance, double price)
{
   if(TradeMode == TRADE_MODE_FIXED)
      return NormalizeDouble(LotSize, 2);

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(accountBalance <= 0)
      return 0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue == 0 || tickSize == 0)
      return 0;

   double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   if(leverage <= 0) leverage = 100;
   
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double marginPerLot = (contractSize * price) / leverage;
   double maxLotByMargin = freeMargin / marginPerLot;

   double riskAmount = accountBalance * (StopLossPercent / 100.0);
   double lotSize = riskAmount / (stopLossDistance / tickSize * tickValue);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathMin(lotSize, maxLotByMargin);
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   lotSize = MathRound(lotSize / lotStep) * lotStep;
   lotSize = NormalizeDouble(lotSize, 2);

   if(lotSize <= 0 || lotSize * marginPerLot > freeMargin)
      return 0;

   return lotSize;
}

//+------------------------------------------------------------------+
//| 获取ATR值函数                                                     |
//+------------------------------------------------------------------+
double GetATRValue(string symbol, ENUM_TIMEFRAMES timeframe, int period)
{
   MqlRates rates[];
   if(CopyRates(symbol, timeframe, 0, period + 1, rates) < period + 1)
      return 0;

   double atrArray[];
   ArraySetAsSeries(atrArray, true);
   int atrHandle = iATR(symbol, timeframe, period);
   if(atrHandle == INVALID_HANDLE)
      return 0;

   int retries = 3;
   for(int i = 0; i < retries; i++)
   {
      if(CopyBuffer(atrHandle, 0, 0, 1, atrArray) > 0)
      {
         IndicatorRelease(atrHandle);
         return atrArray[0];
      }
      Sleep(100);
   }

   IndicatorRelease(atrHandle);
   return 0;
}
//+------------------------------------------------------------------+
