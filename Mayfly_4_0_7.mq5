//+------------------------------------------------------------------+
//| Expert Advisor: Mayfly 4.0.7 (Main File)                        |
//| Description: Core Pre-set Stop Order Grid Trading System        |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property link      "https://xai.com"
#property version   "4.0.7"

#include <Trade\Trade.mqh>
#include "Mayfly_Advanced_4_0_7.mqh"

// 开仓模式枚举（仅保留固定手数模式）
enum ENUM_TRADE_MODE
{
   TRADE_MODE_FIXED = 0 // 固定手数模式
};

// 加仓模式枚举（仅保留均匀加仓模式）
enum ENUM_ADD_MODE
{
   ADD_MODE_UNIFORM = 0 // 匀速加仓（默认）
};

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

// 订单信息结构体
struct PositionInfo
{
   string symbol;             // 交易品种
   double openPrice;          // 开仓价格
   double gridPrice;          // 所属网格价格
   double stopLossPrice;      // 止损/止盈价格
   int gridLevel;             // 网格层级
};

// 输入参数
input double GridSpacing = -1;        // 网格间距（点数），-1 表示使用 ATR
input double LotSize = 0.1;           // 固定手数
input int GridLevels = 20;            // 网格数量
input int StartHour = 0;              // 开始交易时间（小时）
input int EndHour = 23;               // 结束交易时间（小时）
input int ActiveZoneStartHour = 14;   // 活跃时区开始时间
input int ActiveZoneEndHour = 22;     // 活跃时区结束时间
input int ATR_Period = 14;            // ATR 计算周期
input ENUM_TRADE_MODE TradeMode = TRADE_MODE_FIXED; // 开仓模式
input bool IsMiniLot = true;          // 是否使用迷你手
input double InputBasePrice = 0;      // 手动基准价格
input double SlippageTolerance = 0.5; // 滑点容忍范围
input bool EnableMirror = false;      // 镜像逻辑
input bool EnableLogging = false;     // 日志记录
input ENUM_ADD_MODE AddPositionMode = ADD_MODE_UNIFORM; // 加仓模式
input double MaxTotalLots = 100.0;    // 最大总手数
input int AddPositionTimes = 10;      // 最大加仓次数
input double AbnormalStopLossMultiplier = 3.0; // 异常止损倍数

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
double lastStopLossPrice = 0;
double lastBidPrice = 0;
double lastBuyStopLoss = 0;
double lastSellStopLoss = 0;
PositionInfo positionsInfo[];
datetime lastGridUpdateTime = 0;
bool lastActiveZoneState = false;
bool isFirstTick = true;
bool positionsChanged = true;
bool ordersChanged = true;
double lastProcessedBidPrice = 0;
int gridOccupancyMap[];

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
//| 自定义日志函数                                                    |
//+------------------------------------------------------------------+
void Log(string message)
{
   if(EnableLogging) Print(message);
}

//+------------------------------------------------------------------+
//| 判断价格是否与最新止损/止盈重合                                  |
//+------------------------------------------------------------------+
bool IsPriceAtStopLoss(double price)
{
   double normalizedPrice = NormalizeDouble(price, precisionDigits);
   return (normalizedPrice == NormalizeDouble(lastBuyStopLoss, precisionDigits) || 
           normalizedPrice == NormalizeDouble(lastSellStopLoss, precisionDigits));
}

//+------------------------------------------------------------------+
//| 检查异常止损情况                                                  |
//+------------------------------------------------------------------+
void CheckAbnormalStopLoss()
{
   if(lastStopLossPrice == 0)
   {
      Log("跳过异常止损检查：lastStopLossPrice 未设置");
      return;
   }

   double priceDiff = (lastStopLossType == POSITION_TYPE_BUY) ? 
                      (lastStopLossPrice - cachedBidPrice) : (cachedBidPrice - lastStopLossPrice);
   if(priceDiff <= AbnormalStopLossMultiplier * grid.GridStep)
   {
      Log("跳过异常止损处理：价格差异 " + DoubleToString(priceDiff, precisionDigits) + 
          " 未超过阈值 " + DoubleToString(AbnormalStopLossMultiplier * grid.GridStep, precisionDigits));
      return;
   }

   Log("检测到异常止损情况！平掉全部订单！");
   CloseAllPositions();
}

//+------------------------------------------------------------------+
//| 缓存持仓信息                                                     |
//+------------------------------------------------------------------+
void CachePositionGridPrices()
{
   int totalPositions = PositionsTotal();
   static int lastTotalPositions = 0;

   if(totalPositions != lastTotalPositions)
   {
      if(ArrayResize(positionsInfo, totalPositions) < 0)
      {
         Log("错误：缓存数组调整大小失败，totalPositions=" + IntegerToString(totalPositions));
         return;
      }
      lastTotalPositions = totalPositions;
   }

   if(totalPositions == 0)
   {
      Log("跳过持仓缓存：当前无持仓");
      return;
   }

   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("警告：无法选择持仓，票号=" + IntegerToString(ticket));
         continue;
      }

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(symbol != _Symbol || magic != MAGIC_NUMBER)
      {
         Log("跳过持仓缓存：品种或魔术号不匹配，symbol=" + symbol + ", magic=" + IntegerToString(magic));
         continue;
      }

      double positionPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double shift = MathRound((positionPrice - grid.basePrice) / grid.GridStep);
      positionsInfo[i].symbol = symbol;
      positionsInfo[i].openPrice = positionPrice;
      positionsInfo[i].gridPrice = NormalizeDouble(grid.basePrice + shift * grid.GridStep, precisionDigits);
      positionsInfo[i].stopLossPrice = EnableMirror ? PositionGetDouble(POSITION_TP) : PositionGetDouble(POSITION_SL);
      positionsInfo[i].gridLevel = (int)shift;
   }
   UpdateGridOccupancyMap();
}

//+------------------------------------------------------------------+
//| 检查价格是否在止损/止盈列表中                                    |
//+------------------------------------------------------------------+
bool IsPriceInStopLossList(double price)
{
   double normalizedPrice = NormalizeDouble(price, precisionDigits);
   for(int i = 0; i < ArraySize(positionsInfo); i++)
   {
      if(normalizedPrice == NormalizeDouble(positionsInfo[i].stopLossPrice, precisionDigits))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 初始化函数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Log("初始化失败：账户不允许交易");
      return(INIT_FAILED);
   }

   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Log("初始化失败：市场未开放");
      return(INIT_FAILED);
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
      Log("初始化失败：GridLevels 必须大于 0，当前值=" + IntegerToString(GridLevels));
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(ArrayResize(grid.upperGrid, GridLevels) < 0 || ArrayResize(grid.lowerGrid, GridLevels) < 0)
   {
      Log("初始化失败：网格数组调整大小失败");
      return(INIT_PARAMETERS_INCORRECT);
   }

   UpdateGridLevels();
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   SetupGridOrders();
   DrawBasePriceLine();
   lastDealTicket = GetLastDealTicket();
   lastBidPrice = cachedBidPrice;
   lastGridUpdateTime = TimeCurrent();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 反初始化函数                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(!GlobalVariableCheck(CLEANUP_DONE) || GlobalVariableGet(CLEANUP_DONE) != 1)
   {
      Log("执行清理：未检测到清理完成标志或值为 0");
      CleanupOrders();
   }
   ObjectDelete(0, "BasePriceLine");
   Log("Mayfly 4.0.7 停止运行，原因代码=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| Tick 函数                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   cachedBidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isFirstTick)
   {
      CachePositionGridPrices();
      isFirstTick = false;
      lastProcessedBidPrice = cachedBidPrice;
   }

   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   int currentHour = timeStruct.hour;

   if(currentHour >= EndHour && !hasCleanedUpAfterEnd)
   {
      Log("超出交易时间范围，执行清理并退出");
      CloseAllPositions();
      CleanupOrders();
      hasCleanedUpAfterEnd = true;
      return;
   }

   if(currentHour < StartHour || currentHour >= EndHour)
   {
      Log("跳过 Tick 处理：当前时间 " + IntegerToString(currentHour) + 
          " 不在交易时间范围 [" + IntegerToString(StartHour) + "-" + IntegerToString(EndHour) + "] 内");
      return;
   }
   hasCleanedUpAfterEnd = false;

   int currentPositions = PositionsTotal();
   int currentOrders = OrdersTotal();
   static int lastPositions = 0;
   static int lastOrders = 0;
   positionsChanged = (currentPositions != lastPositions);
   ordersChanged = (currentOrders != lastOrders);
   lastPositions = currentPositions;
   lastOrders = currentOrders;

   if(MathAbs(cachedBidPrice - lastProcessedBidPrice) < grid.GridStep && 
      !positionsChanged && !ordersChanged)
   {
      Log("跳过 Tick 处理：价格变化未达 GridStep=" + DoubleToString(grid.GridStep, precisionDigits) + 
          " 且无持仓/订单变化");
      return;
   }

   if(positionsChanged || ordersChanged)
   {
      Log("检测到持仓或订单变化，更新缓存");
      CachePositionGridPrices();
   }

   HandleGridAdjustment();
   lastProcessedBidPrice = cachedBidPrice;

   if(currentTime - lastGridUpdateTime >= 60)
   {
      Log("每分钟检查动态网格更新");
      UpdateDynamicGrid(currentHour);
   }

   if(!HistorySelect(TimeCurrent() - 3600, TimeCurrent()))
   {
      Log("警告：无法选择历史记录，跳过订单处理");
      return;
   }

   int totalDeals = HistoryDealsTotal();
   if(totalDeals <= 0)
   {
      Log("跳过订单处理：无历史成交记录");
      return;
   }

   ulong latestDealTicket = HistoryDealGetTicket(totalDeals - 1);
   if(latestDealTicket <= lastDealTicket)
   {
      Log("跳过订单处理：最新成交票号 " + IntegerToString(latestDealTicket) + 
          " 未超过 lastDealTicket=" + IntegerToString(lastDealTicket));
      return;
   }

   if(HistoryDealGetInteger(latestDealTicket, DEAL_MAGIC) != MAGIC_NUMBER || 
      HistoryDealGetString(latestDealTicket, DEAL_SYMBOL) != _Symbol)
   {
      Log("跳过订单处理：魔术号或品种不匹配，dealTicket=" + IntegerToString(latestDealTicket));
      return;
   }

   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(latestDealTicket, DEAL_REASON);
   if(reason == DEAL_REASON_SL || reason == DEAL_REASON_TP)
   {
      UpdateStopLossesOnStopTriggered(latestDealTicket, currentPositions);
   }
   if(HistoryDealGetInteger(latestDealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
   {
      UpdateStopLossesOnNewOrder(latestDealTicket, currentPositions);
   }
}

//+------------------------------------------------------------------+
//| 处理网格调整                                                     |
//+------------------------------------------------------------------+
void HandleGridAdjustment()
{
   int shift = 0;
   if(cachedBidPrice >= grid.basePrice + grid.GridStep)
      shift = (int)MathFloor((cachedBidPrice - grid.basePrice) / grid.GridStep);
   else if(cachedBidPrice <= grid.basePrice - grid.GridStep)
      shift = (int)MathCeil((cachedBidPrice - grid.basePrice) / grid.GridStep);

   if(shift == 0 && (!stopEventDetected || lastStopLossPrice == 0))
   {
      Log("跳过网格调整：shift=0 且无止损事件或 lastStopLossPrice 未设置");
      return;
   }

   if(shift != 0)
   {
      grid.basePrice = NormalizeDouble(grid.basePrice + shift * grid.GridStep, precisionDigits);
      UpdateGridLevels();
      Log("常规网格移动：shift=" + IntegerToString(shift) + ", 新 basePrice=" + DoubleToString(grid.basePrice, precisionDigits));
   }
   else if(stopEventDetected && lastStopLossPrice != 0)
   {
      double nearestGridPrice = grid.basePrice + MathRound((lastStopLossPrice - grid.basePrice) / grid.GridStep) * grid.GridStep;
      if(MathAbs(lastStopLossPrice - nearestGridPrice) > SlippageTolerance * grid.GridStep)
      {
         Log("跳过止损后网格调整：lastStopLossPrice=" + DoubleToString(lastStopLossPrice, precisionDigits) + 
             " 与 nearestGridPrice=" + DoubleToString(nearestGridPrice, precisionDigits) + " 差异超出容忍范围");
         return;
      }
      grid.basePrice = nearestGridPrice;
      UpdateGridLevels();
      Log("止损后强制调整：新 basePrice=" + DoubleToString(grid.basePrice, precisionDigits));
   }

   AdjustGridOrders();
   DrawBasePriceLine();
}

//+------------------------------------------------------------------+
//| 更新网格层级                                                     |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| 更新动态网格（默认实现为空，高级功能在 .mqh 文件中）             |
//+------------------------------------------------------------------+
void UpdateDynamicGrid(int currentHour)
{
   // 默认实现为空，动态网格功能移至 Mayfly_Advanced_4_0_7.mqh
   Log("跳过动态网格更新：默认实现不支持动态网格");
}

//+------------------------------------------------------------------+
//| 挂单逻辑                                                         |
//+------------------------------------------------------------------+
void PlaceGridOrders(int totalPositions)
{
   if(totalPositions >= GridLevels)
   {
      Log("跳过挂单：持仓数量 " + IntegerToString(totalPositions) + " 已达 GridLevels=" + IntegerToString(GridLevels));
      return;
   }

   if(totalPositions >= AddPositionTimes)
   {
      Log("跳过挂单：持仓数量 " + IntegerToString(totalPositions) + " 已达 AddPositionTimes=" + IntegerToString(AddPositionTimes));
      return;
   }

   double totalLots = CalculateTotalLots();
   if(totalLots >= MaxTotalLots)
   {
      Log("跳过挂单：总手数 " + DoubleToString(totalLots, 2) + " 已达 MaxTotalLots=" + DoubleToString(MaxTotalLots, 2));
      return;
   }

   bool allowBuy = !stopEventDetected || lastStopLossType != POSITION_TYPE_SELL;
   bool allowSell = !stopEventDetected || lastStopLossType != POSITION_TYPE_BUY;
   int addCount = 0;

   for(int i = 0; i < GridLevels && addCount < AddPositionTimes && totalLots < MaxTotalLots; i++)
   {
      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(grid.GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(grid.GridStep, sellPrice);
      double currentBuyLotSize = AdjustLotSizeByMode(lotSizeBuy, addCount, totalLots);
      double currentSellLotSize = AdjustLotSizeByMode(lotSizeSell, addCount, totalLots);

      if(EnableMirror)
      {
         if(currentSellLotSize > 0 && allowBuy && !OrderExists(buyPrice) && !PositionExists(buyPrice) && 
            !IsPriceInStopLossList(buyPrice) && !IsPriceAtStopLoss(buyPrice))
         {
            trade.BuyLimit(currentSellLotSize, buyPrice, _Symbol, 0, buyPrice + grid.GridStep, ORDER_TIME_GTC, 0, "Buy Limit Grid");
            totalLots += currentSellLotSize;
            addCount++;
            Log("挂单：Buy Limit @ " + DoubleToString(buyPrice, precisionDigits) + 
                ", 手数=" + DoubleToString(currentSellLotSize, 2));
         }
         if(currentBuyLotSize > 0 && allowSell && !OrderExists(sellPrice) && !PositionExists(sellPrice) && 
            !IsPriceInStopLossList(sellPrice) && !IsPriceAtStopLoss(sellPrice))
         {
            trade.SellLimit(currentBuyLotSize, sellPrice, _Symbol, 0, sellPrice - grid.GridStep, ORDER_TIME_GTC, 0, "Sell Limit Grid");
            totalLots += currentBuyLotSize;
            addCount++;
            Log("挂单：Sell Limit @ " + DoubleToString(sellPrice, precisionDigits) + 
                ", 手数=" + DoubleToString(currentBuyLotSize, 2));
         }
      }
      else
      {
         if(currentBuyLotSize > 0 && allowBuy && !OrderExists(buyPrice) && !PositionExists(buyPrice) && 
            !IsPriceInStopLossList(buyPrice) && !IsPriceAtStopLoss(buyPrice))
         {
            trade.BuyStop(currentBuyLotSize, buyPrice, _Symbol, buyPrice - grid.GridStep, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid");
            totalLots += currentBuyLotSize;
            addCount++;
            Log("挂单：Buy Stop @ " + DoubleToString(buyPrice, precisionDigits) + 
                ", 手数=" + DoubleToString(currentBuyLotSize, 2));
         }
         if(currentSellLotSize > 0 && allowSell && !OrderExists(sellPrice) && !PositionExists(sellPrice) && 
            !IsPriceInStopLossList(sellPrice) && !IsPriceAtStopLoss(sellPrice))
         {
            trade.SellStop(currentSellLotSize, sellPrice, _Symbol, sellPrice + grid.GridStep, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid");
            totalLots += currentSellLotSize;
            addCount++;
            Log("挂单：Sell Stop @ " + DoubleToString(sellPrice, precisionDigits) + 
                ", 手数=" + DoubleToString(currentSellLotSize, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 平仓所有持仓                                                     |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("警告：无法选择持仓以平仓，票号=" + IntegerToString(ticket));
         continue;
      }

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
      {
         Log("跳过平仓：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| 清理所有挂单                                                     |
//+------------------------------------------------------------------+
void CleanupOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("警告：无法选择订单以清理，票号=" + IntegerToString(ticket));
         continue;
      }

      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
      {
         Log("跳过订单清理：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      trade.OrderDelete(ticket);
   }
   GlobalVariableSet(CLEANUP_DONE, 1);
   GlobalVariableSet(EXIT_SIGNAL, 0);
   Log("清理完成！");
}

//+------------------------------------------------------------------+
//| 绘制基准价格线                                                   |
//+------------------------------------------------------------------+
void DrawBasePriceLine()
{
   ObjectDelete(0, "BasePriceLine");
   ObjectCreate(0, "BasePriceLine", OBJ_HLINE, 0, 0, grid.basePrice);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, "BasePriceLine", OBJPROP_WIDTH, 1);
}

//+------------------------------------------------------------------+
//| 获取最新成交票号                                                 |
//+------------------------------------------------------------------+
ulong GetLastDealTicket()
{
   if(!HistorySelect(TimeCurrent() - 3600, TimeCurrent()))
   {
      Log("警告：无法选择历史记录，返回上次的 lastDealTicket=" + IntegerToString(lastDealTicket));
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
   Log("未找到符合条件的最新成交，返回 lastDealTicket=" + IntegerToString(lastDealTicket));
   return lastDealTicket;
}

//+------------------------------------------------------------------+
//| 设置初始网格订单                                                 |
//+------------------------------------------------------------------+
void SetupGridOrders()
{
   PlaceGridOrders(PositionsTotal());
}

//+------------------------------------------------------------------+
//| 调整网格订单                                                     |
//+------------------------------------------------------------------+
void AdjustGridOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("警告：无法选择订单以调整，票号=" + IntegerToString(ticket));
         continue;
      }

      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
      {
         Log("跳过订单调整：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      if(orderPrice > grid.upperBound || orderPrice < grid.lowerBound)
      {
         trade.OrderDelete(ticket);
         Log("删除订单：价格 " + DoubleToString(orderPrice, precisionDigits) + 
             " 超出网格范围 [" + DoubleToString(grid.lowerBound, precisionDigits) + ", " + 
             DoubleToString(grid.upperBound, precisionDigits) + "]");
      }
   }
   PlaceGridOrders(PositionsTotal());
}

//+------------------------------------------------------------------+
//| 当止损/止盈触发时更新止损                                        |
//+------------------------------------------------------------------+
void UpdateStopLossesOnStopTriggered(ulong dealTicket, int totalPositions)
{
   stopEventDetected = true;
   lastStopLossPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   lastStopLossType = (HistoryDealGetInteger(dealTicket, DEAL_TYPE) == DEAL_TYPE_BUY) ? 
                      POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   lastDealTicket = dealTicket;

   CheckAbnormalStopLoss();
   PlaceGridOrders(totalPositions);

   Log("止损/止盈触发处理完成：dealTicket=" + IntegerToString(dealTicket) + 
       ", symbol=" + _Symbol + ", price=" + DoubleToString(lastStopLossPrice, precisionDigits) + 
       ", type=" + EnumToString(lastStopLossType));

   if(EnableMirror)
   {
      double newBuyStopLoss = 0;
      double newSellStopLoss = 0;
      datetime latestTime = 0;

      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("警告：无法选择持仓以更新止盈，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
         {
            Log("跳过止盈更新：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
            continue;
         }

         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime <= latestTime)
         {
            continue;
         }

         latestTime = openTime;
         double price = PositionGetDouble(POSITION_TP);
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            newBuyStopLoss = price;
         else
            newSellStopLoss = price;
         lastStopLossPrice = price;
      }

      if(newBuyStopLoss <= 0 && newSellStopLoss <= 0)
      {
         Log("跳过止盈更新：未检测到新的止盈价格");
         return;
      }

      if(newBuyStopLoss == lastBuyStopLoss && newSellStopLoss == lastSellStopLoss)
      {
         Log("跳过止盈更新：新止盈价格未变化，newBuyStopLoss=" + DoubleToString(newBuyStopLoss, precisionDigits) + 
             ", newSellStopLoss=" + DoubleToString(newSellStopLoss, precisionDigits));
         return;
      }

      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("警告：无法选择持仓以修改止盈，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
         {
            Log("跳过止盈修改：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newBuyStopLoss > 0)
            trade.PositionModify(ticket, 0, NormalizeDouble(newBuyStopLoss, precisionDigits));
         else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && newSellStopLoss > 0)
            trade.PositionModify(ticket, 0, NormalizeDouble(newSellStopLoss, precisionDigits));
      }
      lastBuyStopLoss = newBuyStopLoss;
      lastSellStopLoss = newSellStopLoss;
      Log("止盈更新完成（镜像模式）：lastBuyStopLoss=" + DoubleToString(lastBuyStopLoss, precisionDigits) + 
          ", lastSellStopLoss=" + DoubleToString(lastSellStopLoss, precisionDigits));
   }
}

//+------------------------------------------------------------------+
//| 当新订单成交时更新止损                                           |
//+------------------------------------------------------------------+
void UpdateStopLossesOnNewOrder(ulong dealTicket, int totalPositions)
{
   lastDealTicket = dealTicket;

   if(!EnableMirror)
   {
      ulong latestPositionTicket = 0;
      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("警告：无法选择持仓以查找最新成交，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
         {
            Log("跳过持仓检查：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetInteger(POSITION_TICKET) == dealTicket)
         {
            latestPositionTicket = ticket;
            break;
         }
      }

      if(latestPositionTicket == 0)
      {
         Log("跳过止损更新：未找到最新成交对应的持仓，dealTicket=" + IntegerToString(dealTicket));
         return;
      }

      if(!PositionSelectByTicket(latestPositionTicket))
      {
         Log("错误：无法选择最新持仓以获取止损，票号=" + IntegerToString(latestPositionTicket));
         return;
      }

      double newStopLoss = PositionGetDouble(POSITION_SL);
      if(newStopLoss <= 0)
      {
         Log("跳过止损更新：最新持仓止损无效，newStopLoss=" + DoubleToString(newStopLoss, precisionDigits));
         return;
      }

      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("警告：无法选择持仓以修改止损，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
         {
            Log("跳过止损修改：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
            continue;
         }

         double currentSL = PositionGetDouble(POSITION_SL);
         if(MathAbs(currentSL - newStopLoss) < cachedSymbolPoint)
         {
            Log("跳过止损修改：当前止损与新止损差异过小，票号=" + IntegerToString(ticket));
            continue;
         }

         trade.PositionModify(ticket, NormalizeDouble(newStopLoss, precisionDigits), 0);
         Log("更新持仓止损：票号=" + IntegerToString(ticket) + ", 新止损=" + DoubleToString(newStopLoss, precisionDigits));
      }

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         lastBuyStopLoss = newStopLoss;
      else
         lastSellStopLoss = newStopLoss;
   }
   else
   {
      double newBuyStopLoss = 0;
      double newSellStopLoss = 0;
      datetime latestTime = 0;

      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("警告：无法选择持仓以更新止盈，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
         {
            Log("跳过止盈更新：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
            continue;
         }

         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime <= latestTime)
         {
            continue;
         }

         latestTime = openTime;
         double price = PositionGetDouble(POSITION_TP);
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            newBuyStopLoss = price;
         else
            newSellStopLoss = price;
         lastStopLossPrice = price;
      }

      if(newBuyStopLoss <= 0 && newSellStopLoss <= 0)
      {
         Log("跳过止盈更新：未检测到新的止盈价格");
         return;
      }

      if(newBuyStopLoss == lastBuyStopLoss && newSellStopLoss == lastSellStopLoss)
      {
         Log("跳过止盈更新：新止盈价格未变化，newBuyStopLoss=" + DoubleToString(newBuyStopLoss, precisionDigits) + 
             ", newSellStopLoss=" + DoubleToString(newSellStopLoss, precisionDigits));
         return;
      }

      for(int i = totalPositions - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
         {
            Log("警告：无法选择持仓以修改止盈，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
         {
            Log("跳过止盈修改：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
            continue;
         }

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newBuyStopLoss > 0)
            trade.PositionModify(ticket, 0, NormalizeDouble(newBuyStopLoss, precisionDigits));
         else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && newSellStopLoss > 0)
            trade.PositionModify(ticket, 0, NormalizeDouble(newSellStopLoss, precisionDigits));
      }
      lastBuyStopLoss = newBuyStopLoss;
      lastSellStopLoss = newSellStopLoss;
      Log("止盈更新完成（镜像模式）：lastBuyStopLoss=" + DoubleToString(lastBuyStopLoss, precisionDigits) + 
          ", lastSellStopLoss=" + DoubleToString(lastSellStopLoss, precisionDigits));
   }

   CheckAbnormalStopLoss();
   PlaceGridOrders(totalPositions);
   Log("新订单成交处理完成：dealTicket=" + IntegerToString(dealTicket));
}

//+------------------------------------------------------------------+
//| 更新网格占用映射                                                 |
//+------------------------------------------------------------------+
void UpdateGridOccupancyMap()
{
   ArrayResize(gridOccupancyMap, GridLevels * 2);
   ArrayInitialize(gridOccupancyMap, 0);

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
      {
         Log("警告：无法选择订单以更新占用映射，票号=" + IntegerToString(ticket));
         continue;
      }

      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER)
      {
         Log("跳过占用映射更新：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      int index = GetGridIndex(OrderGetDouble(ORDER_PRICE_OPEN));
      if(index < 0 || index >= ArraySize(gridOccupancyMap))
      {
         Log("跳过占用映射更新：订单价格超出网格范围，票号=" + IntegerToString(ticket));
         continue;
      }
      gridOccupancyMap[index] = 1;
   }

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("警告：无法选择持仓以更新占用映射，票号=" + IntegerToString(ticket));
         continue;
      }

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
      {
         Log("跳过占用映射更新：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      int index = GetGridIndex(PositionGetDouble(POSITION_PRICE_OPEN));
      if(index < 0 || index >= ArraySize(gridOccupancyMap))
      {
         Log("跳过占用映射更新：持仓价格超出网格范围，票号=" + IntegerToString(ticket));
         continue;
      }
      gridOccupancyMap[index] = 2;
   }
}

//+------------------------------------------------------------------+
//| 获取网格索引                                                     |
//+------------------------------------------------------------------+
int GetGridIndex(double price)
{
   double shift = MathRound((price - grid.basePrice) / grid.GridStep);
   if(shift > 0 && shift <= GridLevels) return (int)(shift - 1);
   if(shift < 0 && -shift <= GridLevels) return (int)(GridLevels - shift - 1);
   return -1;
}

//+------------------------------------------------------------------+
//| 检查挂单或持仓                                                   |
//+------------------------------------------------------------------+
bool OrderExists(double price)
{
   int index = GetGridIndex(price);
   if(index < 0 || index >= ArraySize(gridOccupancyMap))
   {
      Log("跳过挂单检查：价格 " + DoubleToString(price, precisionDigits) + " 超出网格范围");
      return false;
   }
   return gridOccupancyMap[index] == 1;
}

bool PositionExists(double price)
{
   int index = GetGridIndex(price);
   if(index < 0 || index >= ArraySize(gridOccupancyMap))
   {
      Log("跳过持仓检查：价格 " + DoubleToString(price, precisionDigits) + " 超出网格范围");
      return false;
   }
   return gridOccupancyMap[index] == 2;
}

//+------------------------------------------------------------------+
//| 计算总手数                                                       |
//+------------------------------------------------------------------+
double CalculateTotalLots()
{
   double totalLots = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
      {
         Log("警告：无法选择持仓以计算总手数，票号=" + IntegerToString(ticket));
         continue;
      }

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER)
      {
         Log("跳过手数计算：品种或魔术号不匹配，票号=" + IntegerToString(ticket));
         continue;
      }

      totalLots += PositionGetDouble(POSITION_VOLUME);
   }
   return totalLots;
}

//+------------------------------------------------------------------+
//| 根据加仓模式调整手数（仅均匀模式）                               |
//+------------------------------------------------------------------+
double AdjustLotSizeByMode(double baseLotSize, int addCount, double totalLots)
{
   if(totalLots + baseLotSize > MaxTotalLots)
   {
      Log("跳过手数调整：总手数 " + DoubleToString(totalLots + baseLotSize, 2) + 
          " 超过 MaxTotalLots=" + DoubleToString(MaxTotalLots, 2));
      return 0;
   }

   return baseLotSize; // 仅支持均匀加仓模式
}

//+------------------------------------------------------------------+
//| 计算手数（仅固定手数模式）                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossDistance, double price)
{
   return NormalizeDouble(LotSize, 2); // 仅支持固定手数模式
}

//+------------------------------------------------------------------+
//| 获取 ATR 值                                                      |
//+------------------------------------------------------------------+
double GetATRValue(string symbol, ENUM_TIMEFRAMES timeframe, int period)
{
   double atrArray[];
   ArraySetAsSeries(atrArray, true);
   int atrHandle = iATR(symbol, timeframe, period);
   if(atrHandle == INVALID_HANDLE)
   {
      Log("警告：无法创建 ATR 指标句柄");
      return 0;
   }

   if(CopyBuffer(atrHandle, 0, 0, 1, atrArray) <= 0)
   {
      Log("警告：无法复制 ATR 数据");
      IndicatorRelease(atrHandle);
      return 0;
   }

   IndicatorRelease(atrHandle);
   return atrArray[0];
}
//+------------------------------------------------------------------+
