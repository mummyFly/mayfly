//+------------------------------------------------------------------+
//| Expert Advisor: Mayfly 4.3.1 (Main File)                       |
//| Description: Core Pre-set Stop Order Grid Trading System        |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property link      "https://xai.com"
#property version   "4.3.1"

#include <Trade\Trade.mqh>
#include "Mayfly_Advanced_4_0_7.mqh"

// 网格结构定义
struct GridStructure
{
   double basePrice;          // 网格基准价格
   double upperBound;         // 网格上边界
   double lowerBound;         // 网格下边界
   double upperGrid[];        // 上方网格价格数组
   double lowerGrid[];        // 下方网格价格数组
   double GridStep;           // 当前网格间距
   double originalGridStep;   // 原始网格间距
};

// 输入参数
input double GridSpacing = -1;        // 网格间距（点数），-1 表示使用 ATR
input double LotSize = 0.1;           // 固定手数
input int GridLevels = 20;            // 网格数量
input int StartHour = 1;              // 开始交易时间（小时），默认 1
input int EndHour = 24;               // 结束交易时间（小时，用户期望值，实际提前 10 分钟）
input int ActiveZoneStartHour = 14;   // 活跃时区开始时间
input int ActiveZoneEndHour = 22;     // 活跃时区结束时间
input int ATR_Period = 14;            // ATR 计算周期
input ENUM_TRADE_MODE TradeMode = TRADE_MODE_FIXED; // 开仓模式
input bool IsMiniLot = true;          // 是否使用迷你手
input double PositionPercent = 5.0;   // 百分比开仓占比
input double StopLossPercent = 5.0;   // 止损比例占比
input double InputBasePrice = 0;      // 手动基准价格
input double SlippageTolerance = 0.5; // 滑点容忍范围
input bool EnableMirror = false;      // 镜像逻辑
input bool EnableLogging = false;     // 日志记录
input ENUM_ADD_MODE AddPositionMode = ADD_MODE_UNIFORM; // 加仓模式
input double MaxTotalLots = 100.0;    // 最大总手数
input int AddPositionTimes = -1;      // 最大加仓次数，-1 表示与网格数量一致
input bool EnableDynamicGrid = false; // 动态网格
input double AbnormalStopLossMultiplier = 3.0; // 异常止损倍数
input double StopLossGridMultiplier = 1.0;    // 止损网格倍数（新参数，默认 1）

// 全局变量
GridStructure grid;
CTrade trade;
double atrValue;
ulong lastDealTicket = 0;
int precisionDigits;
const long MAGIC_NUMBER = StringToInteger("Mayfly");
string EXIT_SIGNAL;
string CLEANUP_DONE;
ENUM_POSITION_TYPE lastStopLossType = POSITION_TYPE_BUY;
bool stopEventDetected = false;
bool hasCleanedUpAfterEnd = false;
double lastOrderSLPrice = 0;
double lastPositionSLPrice;
double lastPositionOpenPrice = 0;
double lastBidPrice = 0;
double lastBuyStopLoss = 0;
double lastSellStopLoss = 0;
datetime lastGridUpdateTime = 0;
datetime lastAbnormalCheckTime = 0;
bool lastActiveZoneState = false;
bool isFirstTick = true;
bool positionsChanged = true;
bool ordersChanged = true;
int orderOccupancyMap[];
int positionOccupancyMap[];
bool isWithinTradingHours = false;

// 缓存变量
double cachedContractSize;
double cachedTickValue;
double cachedTickSize;
double cachedMinLot;
double cachedMaxLot;
double cachedLotStep;
double cachedSymbolPoint;
double cachedBidPrice;

//+------------------------------------------------------------------+
//| MQL 自带方法                                                    |
//+------------------------------------------------------------------+

int OnInit()
{
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Log("OnInit", "初始化失败：账户不允许交易");
      return(INIT_FAILED);
   }

   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Log("OnInit", "初始化失败：市场未开放");
      return(INIT_FAILED);
   }

   if(StopLossGridMultiplier <= 0)
   {
      Log("OnInit", "初始化失败：StopLossGridMultiplier 必须大于 0，当前值=" + DoubleToString(StopLossGridMultiplier));
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(AddPositionTimes < -1)
   {
      Log("OnInit", "初始化失败：AddPositionTimes 必须大于等于 -1，当前值=" + IntegerToString(AddPositionTimes));
      return(INIT_PARAMETERS_INCORRECT);
   }

   long chartId = ChartID();
   string timeframe = EnumToString(_Period);
   EXIT_SIGNAL = "Mayfly_" + _Symbol + "_" + timeframe + "_Exit_" + IntegerToString(chartId);
   CLEANUP_DONE = "Mayfly_" + _Symbol + "_" + timeframe + "_CleanupDone_" + IntegerToString(chartId);

   CleanupOrders();
   GlobalVariableSet(EXIT_SIGNAL, 0);
   if(GlobalVariableCheck(CLEANUP_DONE)) GlobalVariableDel(CLEANUP_DONE);

   cachedSymbolPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   precisionDigits = (int)MathCeil(-MathLog10(cachedSymbolPoint)) - 1;
   cachedBidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lastPositionSLPrice = cachedBidPrice;
   cachedContractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   cachedTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   cachedTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   cachedMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   cachedMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   cachedLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   grid.basePrice = (InputBasePrice == 0) ? 
                    NormalizeDouble(MathFloor(cachedBidPrice * MathPow(10, precisionDigits + 1)) / MathPow(10, precisionDigits + 1), precisionDigits) : 
                    NormalizeDouble(InputBasePrice, precisionDigits);

   grid.GridStep = (GridSpacing > 0) ? NormalizeDouble(GridSpacing * cachedSymbolPoint, precisionDigits) : 
                   NormalizeDouble((atrValue = GetATRValue(_Symbol, _Period, ATR_Period)) > 0 ? atrValue * 2.0 : 0.01, precisionDigits);
   grid.originalGridStep = grid.GridStep;

   if(GridLevels <= 0)
   {
      Log("OnInit", "初始化失败：GridLevels 必须大于 0，当前值=" + IntegerToString(GridLevels));
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(ArrayResize(grid.upperGrid, GridLevels) < 0 || ArrayResize(grid.lowerGrid, GridLevels) < 0)
   {
      Log("OnInit", "初始化失败：网格数组调整大小失败");
      return(INIT_PARAMETERS_INCORRECT);
   }

   UpdateGridLevels();
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   SetupGridOrders();
   DrawBasePriceLine();
   lastDealTicket = GetLastDealTicket();
   lastBidPrice = cachedBidPrice;
   lastGridUpdateTime = TimeCurrent();
   
   isWithinTradingHours = false;

   if(!EventSetTimer(60))
   {
      Log("OnInit", "初始化失败：无法设置定时器");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   cachedBidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!isWithinTradingHours)
   {
      Log("OnTick", "跳过Tick处理：当前不在交易时间内");
      return;
   }

   if(isFirstTick)
   {
      UpdateGridOccupancyMap();
      isFirstTick = false;
      positionsChanged = true;
      ordersChanged = true;
   }

   HandleGridAdjustment();
}

void OnTimer()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   int currentHour = timeStruct.hour;
   int currentMin = timeStruct.min;

   int currentTimeInMinutes = currentHour * 60 + currentMin;
   int effectiveStartHour = StartHour * 60;
   int effectiveEndHour = EndHour * 60 - 10;

   if(currentTimeInMinutes >= effectiveStartHour && currentTimeInMinutes < effectiveEndHour)
   {
      if(!isWithinTradingHours)
      {
         Log("OnTimer", "进入交易时间范围，当前时间=" + IntegerToString(currentHour) + ":" + IntegerToString(currentMin));
         isWithinTradingHours = true;
      }
   }
   else
   {
      if(isWithinTradingHours)
      {
         Log("OnTimer", "超出交易时间范围，当前时间=" + IntegerToString(currentHour) + ":" + IntegerToString(currentMin));
         isWithinTradingHours = false;
      }
      return;
   }
   hasCleanedUpAfterEnd = false;

   if(PositionsTotal() > 0 && lastPositionSLPrice != -1)
      CheckAbnormalStopLoss();

   if(EnableDynamicGrid)
   {
      Log("OnTimer", "每分钟检查动态网格更新");
      UpdateDynamicGrid(currentHour);
      lastGridUpdateTime = currentTime;
   }

   // 检查是否到达活跃时区开始或结束时间
   bool isActiveZone = (currentHour >= ActiveZoneStartHour && currentHour < ActiveZoneEndHour);
   
   // 进入活跃时区（当前小时等于开始时间且分钟为0）
   if(currentHour == ActiveZoneStartHour && currentMin == 0)
   {
      Log("OnTimer", "进入活跃时区 " + IntegerToString(currentHour) + ":00，网格间距放大 2 倍并清理订单");
      grid.GridStep = grid.originalGridStep * 2;
      CleanupOrders();
      UpdateGridLevels();
      AdjustGridOrders();
   }
   // 退出活跃时区（当前小时等于结束时间且分钟为0）
   else if(currentHour == ActiveZoneEndHour && currentMin == 0)
   {
      Log("OnTimer", "退出活跃时区 " + IntegerToString(currentHour) + ":00，恢复网格间距并清理订单");
      grid.GridStep = grid.originalGridStep;
      CleanupOrders();
      UpdateGridLevels();
      AdjustGridOrders();
   }

   lastActiveZoneState = isActiveZone;
}

void OnDeinit(const int reason)
{
   if(!GlobalVariableCheck(CLEANUP_DONE) || GlobalVariableGet(CLEANUP_DONE) != 1)
   {
      Log("OnDeinit", "执行清理：未检测到清理完成标志或值为 0");
      CleanupOrders();
   }
   ObjectDelete(0, "BasePriceLine");
   EventKillTimer();
   Log("OnDeinit", "Mayfly 4.3.1 停止运行，原因代码=" + IntegerToString(reason));
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                       const MqlTradeRequest& request,
                       const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_ORDER_ADD && 
      trans.type != TRADE_TRANSACTION_ORDER_UPDATE && 
      trans.type != TRADE_TRANSACTION_ORDER_DELETE && 
      trans.type != TRADE_TRANSACTION_DEAL_ADD && 
      trans.type != TRADE_TRANSACTION_POSITION)
   {
      Log("OnTradeTransaction", "跳过交易事件：未知类型，trans.type=" + EnumToString(trans.type));
      return;
   }

   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      Log("OnTradeTransaction", "订单删除：orderTicket=" + IntegerToString(trans.order));
      ordersChanged = true;
      UpdateGridOccupancyMap();
      ordersChanged = false;
      positionsChanged = false;
      return;
   }

   long magic = GetMagicNumber(trans);
   if(magic == -1)
   {
      Log("OnTradeTransaction", "异常退出：无法获取魔法数，dealTicket=" + IntegerToString(trans.deal) + 
          ", orderTicket=" + IntegerToString(trans.order));
      return;
   }

   if(trans.symbol != _Symbol || magic != MAGIC_NUMBER)
   {
      Log("OnTradeTransaction", "跳过交易事件：符号或魔法数不匹配，symbol=" + trans.symbol + 
          ", magic=" + IntegerToString(magic));
      return;
   }

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(!HistoryDealSelect(trans.deal))
      {
         Log("OnTradeTransaction", "异常退出：无法选择成交历史，dealTicket=" + IntegerToString(trans.deal));
         return;
      }

      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

      if(trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL)
      {
         Log("OnTradeTransaction", "跳过交易事件：无效成交类型，dealType=" + EnumToString(trans.deal_type));
         return;
      }

      if(entry == DEAL_ENTRY_IN && reason != DEAL_REASON_SL && reason != DEAL_REASON_TP)
      {
         Log("OnTradeTransaction", "新订单成交：dealTicket=" + IntegerToString(trans.deal) + 
             ", type=" + EnumToString(trans.deal_type));
         
         double slPrice = HistoryDealGetDouble(trans.deal, DEAL_SL);
         if(slPrice <= 0)
         {
            Log("OnTradeTransaction", "异常退出：无法获取新订单止损价，dealTicket=" + IntegerToString(trans.deal));
            return;
         }

         double openPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
         if(openPrice <= 0)
         {
            Log("OnTradeTransaction", "异常退出：无法获取新订单开仓价，dealTicket=" + IntegerToString(trans.deal));
            return;
         }

         lastPositionOpenPrice = openPrice;
         lastPositionSLPrice = slPrice;

         if(OrderExists(slPrice))
            DeleteOrdersAtPrice(slPrice);

         UpdateStopLossesOnNewOrder(trans, PositionsTotal());
         PlaceGridOrders(PositionsTotal());
         positionsChanged = true;
      }

      if(entry == DEAL_ENTRY_OUT && (reason == DEAL_REASON_SL || reason == DEAL_REASON_TP))
      {
         Log("OnTradeTransaction", "止损/止盈触发：dealTicket=" + IntegerToString(trans.deal) + 
             ", reason=" + EnumToString(reason));
         stopEventDetected = true;
         UpdateStopLossesOnStopTriggered(trans, PositionsTotal());
         stopEventDetected = false;
         
         Log("OnTradeTransaction", "平仓完成，触发挂单行为");
         PlaceGridOrders(PositionsTotal());
         
         positionsChanged = true;
      }

      if(positionsChanged)
      {
         Log("OnTradeTransaction", "检测到持仓变化，更新缓存");
         UpdateGridOccupancyMap();
         positionsChanged = false;
         ordersChanged = false;
      }
      return;
   }

   if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      Log("OnTradeTransaction", "订单添加：orderTicket=" + IntegerToString(trans.order));
      ordersChanged = true;
      UpdateGridOccupancyMap();
      ordersChanged = false;
      positionsChanged = false;
      return;
   }

   if(trans.type == TRADE_TRANSACTION_POSITION)
   {
      Log("OnTradeTransaction", "持仓更新：positionTicket=" + IntegerToString(trans.position));
      ordersChanged = true;
      UpdateGridOccupancyMap();
      ordersChanged = false;
      positionsChanged = false;
      return;
   }
}

//+------------------------------------------------------------------+
//| 按 OnTick 调用顺序排列的其他方法                                 |
//+------------------------------------------------------------------+

void UpdateGridOccupancyMap()
{
   ArrayResize(orderOccupancyMap, GridLevels * 2);
   ArrayInitialize(orderOccupancyMap, 0);
   ArrayResize(positionOccupancyMap, GridLevels * 2);
   ArrayInitialize(positionOccupancyMap, 0);

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("UpdateGridOccupancyMap", "警告：无法选择订单以更新占用映射，票号=" + IntegerToString(ticket));
         continue;
      }

      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
      {
         Log("UpdateGridOccupancyMap", "跳过占用映射更新：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      int index = GetGridIndex(OrderGetDouble(ORDER_PRICE_OPEN));
      if(index < 0 || index >= ArraySize(orderOccupancyMap))
      {
         Log("UpdateGridOccupancyMap", "跳过占用映射更新：订单价格超出网格范围，票号=" + IntegerToString(ticket));
         continue;
      }
      orderOccupancyMap[index] = 1;
   }

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("UpdateGridOccupancyMap", "警告：无法选择持仓以更新占用映射，票号=" + IntegerToString(ticket));
         continue;
      }

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
      {
         Log("UpdateGridOccupancyMap", "跳过占用映射更新：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      int index = GetGridIndex(PositionGetDouble(POSITION_PRICE_OPEN));
      if(index < 0 || index >= ArraySize(positionOccupancyMap))
      {
         Log("UpdateGridOccupancyMap", "跳过占用映射更新：持仓价格超出网格范围，票号=" + IntegerToString(ticket));
         continue;
      }
      positionOccupancyMap[index] = 1;
   }
}

int GetGridIndex(double price)
{
   double shift = MathRound((price - grid.basePrice) / grid.GridStep);
   if(shift > 0 && shift <= GridLevels) return (int)(shift - 1);
   if(shift < 0 && -shift <= GridLevels) return (int)(GridLevels - shift - 1);
   return -1;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("CloseAllPositions", "警告：无法选择持仓以平仓，票号=" + IntegerToString(ticket));
         continue;
      }

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
      {
         Log("CloseAllPositions", "跳过平仓：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      trade.PositionClose(ticket);
   }
}

void CleanupOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("CleanupOrders", "警告：无法选择订单以清理，票号=" + IntegerToString(ticket));
         continue;
      }

      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
      {
         Log("CleanupOrders", "跳过订单清理：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      trade.OrderDelete(ticket);
   }
   GlobalVariableSet(CLEANUP_DONE, 1);
   GlobalVariableSet(EXIT_SIGNAL, 0);
   Log("CleanupOrders", "清理完成！");
}

void HandleGridAdjustment()
{
   if(!stopEventDetected && MathAbs(cachedBidPrice - grid.basePrice) < grid.GridStep)
      return;

   int shift = 0;
   if(cachedBidPrice >= grid.basePrice + grid.GridStep)
      shift = (int)MathFloor((cachedBidPrice - grid.basePrice) / grid.GridStep);
   else if(cachedBidPrice <= grid.basePrice - grid.GridStep)
      shift = (int)MathCeil((cachedBidPrice - grid.basePrice) / grid.GridStep);

   if(shift != 0)
   {
      grid.basePrice = NormalizeDouble(grid.basePrice + shift * grid.GridStep, precisionDigits);
      UpdateGridLevels();
   }
   else if(stopEventDetected)
   {
      double nearestGridPrice = grid.basePrice + MathRound((lastOrderSLPrice - grid.basePrice) / grid.GridStep) * grid.GridStep;
      if(MathAbs(lastOrderSLPrice - nearestGridPrice) > SlippageTolerance * grid.GridStep)
      {
         Log("HandleGridAdjustment", "跳过止损后网格调整：lastOrderSLPrice=" + DoubleToString(lastOrderSLPrice, precisionDigits) + 
             " 与 nearestGridPrice=" + DoubleToString(nearestGridPrice, precisionDigits) + " 差异超出容忍范围");
         return;
      }
      grid.basePrice = nearestGridPrice;
      UpdateGridLevels();
      Log("HandleGridAdjustment", "止损后强制调整：新 basePrice=" + DoubleToString(grid.basePrice, precisionDigits));
   }

   AdjustGridOrders();
   DrawBasePriceLine();
}

void UpdateGridLevels()
{
   for(int i = 0; i < GridLevels; i++)
   {
      grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * grid.GridStep, precisionDigits);
      grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * grid.GridStep, precisionDigits);
   }
   grid.upperBound = grid.upperGrid[GridLevels - 1];
   grid.lowerBound = grid.lowerGrid[GridLevels - 1];
}

void AdjustGridOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("AdjustGridOrders", "警告：无法选择订单以调整，票号=" + IntegerToString(ticket));
         continue;
      }

      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
      {
         Log("AdjustGridOrders", "跳过订单调整：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      
      if(orderPrice > grid.upperBound || orderPrice < grid.lowerBound)
      {
         trade.OrderDelete(ticket);
         Log("AdjustGridOrders", "删除订单：价格 " + DoubleToString(orderPrice, precisionDigits) + 
             " 超出网格范围 [" + DoubleToString(grid.lowerBound, precisionDigits) + ", " + 
             DoubleToString(grid.upperBound, precisionDigits) + "]");
         continue;
      }

      double shift = (orderPrice - grid.basePrice) / grid.GridStep;
      double roundedShift = MathRound(shift);
      if(MathAbs(shift - roundedShift) > cachedSymbolPoint / grid.GridStep)
      {
         trade.OrderDelete(ticket);
         Log("AdjustGridOrders", "删除订单：价格 " + DoubleToString(orderPrice, precisionDigits) + 
             " 不匹配当前网格，shift=" + DoubleToString(shift, 4));
         continue;
      }

      int gridLevel = (int)MathAbs(roundedShift);
      if(gridLevel > GridLevels || gridLevel == 0)
      {
         trade.OrderDelete(ticket);
         Log("AdjustGridOrders", "删除订单：价格 " + DoubleToString(orderPrice, precisionDigits) + 
             " 网格层级 " + IntegerToString(gridLevel) + " 超出范围或无效");
         continue;
      }
   }
   PlaceGridOrders(PositionsTotal());
}

void PlaceGridOrders(int totalPositions)
{
   UpdateGridOccupancyMap();
   int effectiveAddPositionTimes = (AddPositionTimes == -1) ? GridLevels : AddPositionTimes;

   if(totalPositions >= GridLevels)
   {
      Log("PlaceGridOrders", "跳过挂单：持仓数量 " + IntegerToString(totalPositions) + " 已达 GridLevels=" + IntegerToString(GridLevels));
      return;
   }

   if(totalPositions >= effectiveAddPositionTimes)
   {
      Log("PlaceGridOrders", "跳过挂单：持仓数量 " + IntegerToString(totalPositions) + " 已达 AddPositionTimes=" + IntegerToString(effectiveAddPositionTimes));
      return;
   }

   double totalLots = CalculateTotalLots();
   if(totalLots >= MaxTotalLots)
   {
      Log("PlaceGridOrders", "跳过挂单：总手数 " + DoubleToString(totalLots, 2) + " 已达 MaxTotalLots=" + DoubleToString(MaxTotalLots, 2));
      return;
   }

   ENUM_POSITION_TYPE currentPositionType;
   if(totalPositions > 0)
   {
      ulong ticket = PositionGetTicket(0);
      if(PositionSelectByTicket(ticket) && 
         PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
      {
         currentPositionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
   }

   int addCount = 0;

   for(int i = 0; i < GridLevels && addCount < effectiveAddPositionTimes && totalLots < MaxTotalLots; i++)
   {
      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(grid.GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(grid.GridStep, sellPrice);
      double currentBuyLotSize = AdjustLotSizeByMode(lotSizeBuy, addCount, totalLots);
      double currentSellLotSize = AdjustLotSizeByMode(lotSizeSell, addCount, totalLots);

      if(!EnableMirror)
      {
         if(currentBuyLotSize > 0 && !OrderExists(buyPrice) && 
            NormalizeDouble(buyPrice, precisionDigits) != NormalizeDouble(lastPositionSLPrice, precisionDigits) && 
            NormalizeDouble(buyPrice, precisionDigits) != NormalizeDouble(lastPositionOpenPrice, precisionDigits))
         {
            double buyStopLoss = NormalizeDouble(buyPrice - StopLossGridMultiplier * grid.GridStep, precisionDigits);
            trade.BuyStop(currentBuyLotSize, buyPrice, _Symbol, buyStopLoss, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid");
            totalLots += currentBuyLotSize;
            addCount++;
            Log("PlaceGridOrders", "挂单：Buy Stop @ " + DoubleToString(buyPrice, precisionDigits) + 
                ", 止损=" + DoubleToString(buyStopLoss, precisionDigits) + 
                ", 手数=" + DoubleToString(currentBuyLotSize, 2));
         }
         else
         {
            Log("PlaceGridOrders", "跳过 Buy Stop @ " + DoubleToString(buyPrice, precisionDigits) + 
                ": lotSize=" + DoubleToString(currentBuyLotSize, 2) + 
                ", orderExists=" + (OrderExists(buyPrice) ? "true" : "false") + 
                ", atLastSLPrice=" + (NormalizeDouble(buyPrice, precisionDigits) == NormalizeDouble(lastPositionSLPrice, precisionDigits) ? "true" : "false") + 
                ", atLastOpenPrice=" + (NormalizeDouble(buyPrice, precisionDigits) == NormalizeDouble(lastPositionOpenPrice, precisionDigits) ? "true" : "false"));
         }

         if(currentSellLotSize > 0 && !OrderExists(sellPrice) && 
            NormalizeDouble(sellPrice, precisionDigits) != NormalizeDouble(lastPositionSLPrice, precisionDigits) && 
            NormalizeDouble(sellPrice, precisionDigits) != NormalizeDouble(lastPositionOpenPrice, precisionDigits))
         {
            double sellStopLoss = NormalizeDouble(sellPrice + StopLossGridMultiplier * grid.GridStep, precisionDigits);
            trade.SellStop(currentSellLotSize, sellPrice, _Symbol, sellStopLoss, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid");
            totalLots += currentSellLotSize;
            addCount++;
            Log("PlaceGridOrders", "挂单：Sell Stop @ " + DoubleToString(sellPrice, precisionDigits) + 
                ", 止损=" + DoubleToString(sellStopLoss, precisionDigits) + 
                ", 手数=" + DoubleToString(currentSellLotSize, 2));
         }
         else
         {
            Log("PlaceGridOrders", "跳过 Sell Stop @ " + DoubleToString(sellPrice, precisionDigits) + 
                ": lotSize=" + DoubleToString(currentSellLotSize, 2) + 
                ", orderExists=" + (OrderExists(sellPrice) ? "true" : "false") + 
                ", atLastSLPrice=" + (NormalizeDouble(sellPrice, precisionDigits) == NormalizeDouble(lastPositionSLPrice, precisionDigits) ? "true" : "false") + 
                ", atLastOpenPrice=" + (NormalizeDouble(sellPrice, precisionDigits) == NormalizeDouble(lastPositionOpenPrice, precisionDigits) ? "true" : "false"));
         }
      }
   }
}

double CalculateTotalLots()
{
   double totalLots = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("CalculateTotalLots", "警告：无法选择持仓以计算总手数，票号=" + IntegerToString(ticket));
         continue;
      }

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
      {
         Log("CalculateTotalLots", "跳过手数计算：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      totalLots += PositionGetDouble(POSITION_VOLUME);
   }
   return totalLots;
}

double CalculateLotSize(double stopLossDistance, double price)
{
   if(TradeMode == TRADE_MODE_FIXED)
      return NormalizeDouble(LotSize, 2);

   return CalculateLotSizeAdvanced(stopLossDistance, price, TradeMode);
}

double AdjustLotSizeByMode(double baseLotSize, int addCount, double totalLots)
{
   if(totalLots + baseLotSize > MaxTotalLots)
   {
      Log("AdjustLotSizeByMode", "跳过手数调整：总手数 " + DoubleToString(totalLots + baseLotSize, 2) + 
          " 超过 MaxTotalLots=" + DoubleToString(MaxTotalLots, 2));
      return 0;
   }

   if(AddPositionMode == ADD_MODE_UNIFORM)
      return baseLotSize;

   return AdjustLotSizeByModeAdvanced(baseLotSize, addCount, totalLots, AddPositionMode);
}

bool OrderExists(double price)
{
   int index = GetGridIndex(price);
   if(index < 0 || index >= ArraySize(orderOccupancyMap))
   {
      Log("OrderExists", "跳过挂单检查：价格 " + DoubleToString(price, precisionDigits) + " 超出网格范围");
      return false;
   }
   return orderOccupancyMap[index] == 1;
}

bool PositionExists(double price)
{
   int index = GetGridIndex(price);
   if(index < 0 || index >= ArraySize(positionOccupancyMap))
   {
      Log("PositionExists", "跳过持仓检查：价格 " + DoubleToString(price, precisionDigits) + " 超出网格范围");
      return false;
   }
   return positionOccupancyMap[index] == 1;
}

void DrawBasePriceLine()
{
   ObjectDelete(0, "BasePriceLine");
   ObjectCreate(0, "BasePriceLine", OBJ_HLINE, 0, 0, grid.basePrice);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_WIDTH, 1);
}

void CheckAbnormalStopLoss()
{
   double priceDiff = (lastStopLossType == POSITION_TYPE_BUY) ? 
                      (lastPositionSLPrice - cachedBidPrice) : (cachedBidPrice - lastPositionSLPrice);
   if(priceDiff <= AbnormalStopLossMultiplier * grid.GridStep)
   {
      Log("CheckAbnormalStopLoss", "跳过异常止损处理：价格差异 " + DoubleToString(priceDiff, precisionDigits) + 
          " 未超过阈值 " + DoubleToString(AbnormalStopLossMultiplier * grid.GridStep, precisionDigits));
      return;
   }

   Log("CheckAbnormalStopLoss", "检测到异常止损情况！平掉全部订单！当前价格=" + DoubleToString(cachedBidPrice, precisionDigits) + 
       ", 最新持仓止损价=" + DoubleToString(lastPositionSLPrice, precisionDigits) + 
       ", 价格差异=" + DoubleToString(priceDiff, precisionDigits) + 
       ", 阈值=" + DoubleToString(AbnormalStopLossMultiplier * grid.GridStep, precisionDigits));
   CloseAllPositions();
}

void UpdateDynamicGrid(int currentHour)
{
   if(!EnableDynamicGrid)
   {
      Log("UpdateDynamicGrid", "跳过动态网格更新：EnableDynamicGrid 未启用");
      return;
   }
   UpdateDynamicGridAdvanced(currentHour);
}

//+------------------------------------------------------------------+
//| 剩余方法                                                       |
//+------------------------------------------------------------------+

void Log(string methodName, string message) // 双参数版本
{
   if(EnableLogging && methodName == "PlaceGridOrders")
   {
      Print(methodName + ": " + message);
   }
}

void Log(string message) // 单参数版本，兼容旧代码
{
   if(EnableLogging)
   {
      Print("Unknown: " + message);
   }
}

void SetupGridOrders()
{
   PlaceGridOrders(PositionsTotal());
}

ulong GetLastDealTicket()
{
   if(!HistorySelect(TimeCurrent() - 3600, TimeCurrent()))
   {
      Log("GetLastDealTicket", "警告：无法选择历史记录，返回上次的 lastDealTicket=" + IntegerToString(lastDealTicket));
      return lastDealTicket;
   }

   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= 0 || HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol || 
         HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MAGIC_NUMBER || 
         HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN)
      {
         continue;
      }
      return dealTicket;
   }
   Log("GetLastDealTicket", "未找到符合条件的最新成交，返回 lastDealTicket=" + IntegerToString(lastDealTicket));
   return lastDealTicket;
}

double GetATRValue(string symbol, ENUM_TIMEFRAMES timeframe, int period)
{
   double atrArray[];
   ArraySetAsSeries(atrArray, true);
   int atrHandle = iATR(symbol, timeframe, period);
   if(atrHandle == INVALID_HANDLE)
   {
      Log("GetATRValue", "警告：无法创建 ATR 指标句柄");
      return 0;
   }

   if(CopyBuffer(atrHandle, 0, 0, 1, atrArray) <= 0)
   {
      Log("GetATRValue", "警告：无法复制 ATR 数据");
      IndicatorRelease(atrHandle);
      return 0;
   }

   IndicatorRelease(atrHandle);
   return atrArray[0];
}

void UpdateStopLossesOnNewOrder(const MqlTradeTransaction& trans, int totalPositions)
{
   if(trans.price_sl <= 0)
   {
      Log("UpdateStopLossesOnNewOrder", "错误：trans.price_sl 不可用，dealTicket=" + IntegerToString(trans.deal) + 
          ", 请检查订单是否正确设置止损");
      return;
   }

   lastDealTicket = trans.deal;
   lastOrderSLPrice = trans.price_sl;
   lastPositionSLPrice = trans.price_sl;

   if(!EnableMirror)
   {
      ENUM_POSITION_TYPE positionType = (trans.deal_type == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("UpdateStopLossesOnNewOrder", "警告：无法选择持仓以修改止损，票号=" + IntegerToString(ticket));
            continue;
         }
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
            continue;

         double currentSL = PositionGetDouble(POSITION_SL);
         if(MathAbs(currentSL - lastOrderSLPrice) < cachedSymbolPoint)
            continue;

         trade.PositionModify(ticket, NormalizeDouble(lastOrderSLPrice, precisionDigits), 0);
         Log("UpdateStopLossesOnNewOrder", "更新持仓止损：票号=" + IntegerToString(ticket) + ", 新止损=" + DoubleToString(lastOrderSLPrice, precisionDigits));
      }
      if(positionType == POSITION_TYPE_BUY)
         lastBuyStopLoss = lastOrderSLPrice;
      else
         lastSellStopLoss = lastOrderSLPrice;
   }

   Log("UpdateStopLossesOnNewOrder", "新订单成交处理完成：dealTicket=" + IntegerToString(trans.deal));
}

void UpdateStopLossesOnStopTriggered(const MqlTradeTransaction& trans, int totalPositions)
{
   if(trans.price <= 0)
   {
      Log("UpdateStopLossesOnStopTriggered", "错误：trans.price 不可用，dealTicket=" + IntegerToString(trans.deal) + 
          ", 止损/止盈触发价格无效");
      return;
   }

   lastOrderSLPrice = trans.price;
   lastStopLossType = (trans.deal_type == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   lastDealTicket = trans.deal;

   Log("UpdateStopLossesOnStopTriggered", "止损/止盈触发处理完成：dealTicket=" + IntegerToString(trans.deal) + 
       ", symbol=" + _Symbol + ", price=" + DoubleToString(lastOrderSLPrice, precisionDigits) + 
       ", type=" + EnumToString(lastStopLossType));
}

long GetMagicNumber(const MqlTradeTransaction& trans)
{
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD || 
      trans.type == TRADE_TRANSACTION_ORDER_UPDATE || 
      trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      if(!OrderSelect(trans.order))
      {
         Log("GetMagicNumber", "警告：无法选择订单，orderTicket=" + IntegerToString(trans.order) + 
             ", trans.type=" + EnumToString(trans.type) + 
             ", error=" + IntegerToString(GetLastError()));
         return -1;
      }
      return OrderGetInteger(ORDER_MAGIC);
   }

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || 
      trans.type == TRADE_TRANSACTION_POSITION)
   {
      if(PositionSelectByTicket(trans.position))
         return PositionGetInteger(POSITION_MAGIC);
      
      if(!HistoryDealSelect(trans.deal))
      {
         Log("GetMagicNumber", "警告：无法选择持仓或成交，dealTicket=" + IntegerToString(trans.deal));
         return -1;
      }
      return HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   }

   Log("GetMagicNumber", "异常退出：未知交易类型，trans.type=" + EnumToString(trans.type));
   return -1;
}

void DeleteOrdersAtPrice(double price)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("DeleteOrdersAtPrice", "警告：无法选择订单以删除，票号=" + IntegerToString(ticket));
         continue;
      }
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
         continue;

      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      if(NormalizeDouble(orderPrice, precisionDigits) != NormalizeDouble(price, precisionDigits))
         continue;

      trade.OrderDelete(ticket);
      Log("DeleteOrdersAtPrice", "删除止损位置挂单：票号=" + IntegerToString(ticket) + 
          ", 价格=" + DoubleToString(orderPrice, precisionDigits));
   }
}

//+------------------------------------------------------------------+
