//+------------------------------------------------------------------+
//| Expert Advisor: Mayfly 3.1 System                                |
//| Description: Pre-set Stop Order Grid Trading System with Dynamic Base Price |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property link      "https://xai.com"
#property version   "3.1.13"

#include <Trade\Trade.mqh>

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
   ADD_MODE_PYRAMID = 1,    // 正金字塔加仓（底仓大，上面小）
   ADD_MODE_INV_PYRAMID = 2 // 倒金字塔加仓（底仓小，上面大）
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
input double LotSize = 0.1;           // 固定手数（TradeMode = TRADE_MODE_FIXED 时启用）
input int GridLevels = 20;            // 网格数量（上下各多少格），默认20
input int StartHour = 15;             // 开始交易时间（小时，0-23），默认15点
input int EndHour = 20;               // 结束交易时间（小时，0-23），默认20点
input int ActiveZoneStartHour = 14;   // 活跃时区开始时间（小时，0-23），默认14点
input int ActiveZoneEndHour = 22;     // 活跃时区结束时间（小时，0-23），默认22点
input int ATR_Period = 14;            // ATR周期
input ENUM_TRADE_MODE TradeMode = TRADE_MODE_STOPLOSS_PERCENT; // 开仓模式，默认止损比例模式
input bool IsMiniLot = true;          // 是否为迷你手（1 迷你手 = 0.1 标准手），默认 true
input double PositionPercent = 5.0;   // 百分比开仓模式：每笔订单最大可用资金占账户余额的百分比，默认5%
input double StopLossPercent = 5.0;   // 止损比例开仓模式：每笔订单最大损失占账户余额的百分比，默认5%
input double InputBasePrice = 0;      // 用户手动输入的基准价格，默认0表示未输入
input double SlippageTolerance = 0.5; // 滑点容忍范围（以 GridStep 为单位，默认0.5）
input bool EnableMirror = false;      // 是否开启镜像逻辑，默认关闭
input bool EnableLogging = true;      // 是否打印日志，默认开启以便调试
input ENUM_ADD_MODE AddPositionMode = ADD_MODE_UNIFORM; // 加仓模式，默认匀速加仓
input double MaxTotalLots = 100.0;    // 最大总手数限制，默认100手
input int AddPositionTimes = 10;      // 加仓次数，默认10次
input bool EnableDynamicGrid = false; // 是否开启动态网格，默认关闭
input double AbnormalStopLossMultiplier = 3.0; // 异常止损倍数，默认3倍网格间隔

// 全局变量
GridStructure grid;                   // 网格对象
double GridStep;                      // 网格间距（动态调整）
double originalGridStep;              // 原始网格间距（用于时区调整）
CTrade trade;                         // 交易对象
double atrValue;                      // 当前ATR值
ulong lastDealTicket = 0;             // 最后处理的成交票号
int precisionDigits;                  // 计算精度（比市场精度多一位）
const long MAGIC_NUMBER = StringToInteger("Mayfly3.1");  // 魔术号
string EXIT_SIGNAL;                   // 退出信号全局变量名称（图表特定）
string CLEANUP_DONE;                  // 清理完成标志全局变量名称（图表特定）
ENUM_POSITION_TYPE lastStopLossType = POSITION_TYPE_BUY;  // 最近止损的订单类型
bool stopLossDetected = false;        // 当前循环是否检测到止损
bool hasCleanedUpAfterEnd = false;    // 是否已执行过超出结束时间的清理
double lastStopLossPrice = 0;         // 最新止损/止盈价格
double lastBidPrice = 0;              // 上次 bid 价格
double stopLosses[];                  // 缓存止损/止盈价格数组
bool stopLossesUpdated = false;       // 止损/止盈数组是否需要更新
double lastBuyLimit = 0;              // 上次买单止损/止盈
double lastSellLimit = 0;             // 上次卖单止损/止盈
double positionGridPrices[];          // 缓存持仓的网格价位
double stopLossPrices[];              // 缓存持仓的止损/止盈价位
string positionSymbols[];             // 缓存持仓的交易品种
double positionOpenPrices[];          // 缓存持仓的开仓价格
datetime lastGridUpdateTime = 0;      // 上次网格更新的时间戳（秒）
bool lastActiveZoneState = false;     // 上次时区状态（true 为活跃时区）

// 缓存的静态变量
double cachedContractSize;            // 缓存的合约大小
double cachedTickValue;               // 缓存的每点价值
double cachedTickSize;                // 缓存的点值单位
double cachedMinLot;                  // 缓存的最小手数
double cachedMaxLot;                  // 缓存的最大手数
double cachedLotStep;                 // 缓存的手数步长
double cachedSymbolPoint;             // 缓存的点值

//+------------------------------------------------------------------+
//| 自定义日志函数                                                    |
//+------------------------------------------------------------------+
void Log(string message)
{
   if(EnableLogging)
      Print(message);
}

//+------------------------------------------------------------------+
//| 检查异常止损情况                                                  |
//+------------------------------------------------------------------+
void CheckAbnormalStopLoss()
{
   if(lastStopLossPrice == 0) return; // 未设置止损价格，跳过

   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double priceDiff = 0.0;

   // 根据订单类型判断价格差值
   if(lastStopLossType == POSITION_TYPE_BUY)
   {
      // 买单：价格下跌触发止损，当前价格应低于止损价
      priceDiff = lastStopLossPrice - bidPrice;
      Log("异常止损检查：lastStopLossType=BUY, lastStopLossPrice=" + DoubleToString(lastStopLossPrice) + 
          ", bidPrice=" + DoubleToString(bidPrice) + ", priceDiff=" + DoubleToString(priceDiff));
   }
   else if(lastStopLossType == POSITION_TYPE_SELL)
   {
      // 卖单：价格上涨触发止损，当前价格应高于止损价
      priceDiff = bidPrice - lastStopLossPrice;
      Log("异常止损检查：lastStopLossType=SELL, lastStopLossPrice=" + DoubleToString(lastStopLossPrice) + 
          ", bidPrice=" + DoubleToString(bidPrice) + ", priceDiff=" + DoubleToString(priceDiff));
   }

   // 使用提取的常量倍数
   double threshold = AbnormalStopLossMultiplier * GridStep;

   // 判断是否为异常止损：差值大于指定倍数的网格间隔
   if(priceDiff > threshold)
   {
      Log("检测到异常止损情况！当前价格=" + DoubleToString(bidPrice) + 
          ", 最新止损价=" + DoubleToString(lastStopLossPrice) + 
          ", 价格差值=" + DoubleToString(priceDiff) + 
          ", " + DoubleToString(AbnormalStopLossMultiplier) + "倍网格间隔=" + DoubleToString(threshold) + 
          ", 订单类型=" + EnumToString(lastStopLossType) + 
          ". 平掉全部订单！");
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| 缓存持仓的网格价位和止损/止盈价位                                |
//+------------------------------------------------------------------+
void CachePositionGridPrices()
{
   int totalPositions = PositionsTotal();
   ArrayResize(positionGridPrices, totalPositions);
   ArrayResize(stopLossPrices, totalPositions);
   ArrayResize(positionSymbols, totalPositions);
   ArrayResize(positionOpenPrices, totalPositions);

   for(int i = 0; i < totalPositions; i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         // 一次性缓存持仓的符号和开仓价格
         positionSymbols[i] = PositionGetString(POSITION_SYMBOL);
         positionOpenPrices[i] = PositionGetDouble(POSITION_PRICE_OPEN);

         if(positionSymbols[i] == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            double positionPrice = positionOpenPrices[i];
            // 计算 positionPrice 所属的网格价位
            double shift = MathRound((positionPrice - grid.basePrice) / GridStep);
            double nearestGridPrice = NormalizeDouble(grid.basePrice + shift * GridStep, precisionDigits);
            positionGridPrices[i] = nearestGridPrice;
            // 缓存止损/止盈价位
            double stopLossPrice = EnableMirror ? PositionGetDouble(POSITION_TP) : PositionGetDouble(POSITION_SL);
            stopLossPrices[i] = NormalizeDouble(stopLossPrice, precisionDigits);
            if(EnableLogging)
            {
               Log("持仓 " + IntegerToString(i) + " 开仓价=" + DoubleToString(positionPrice) + 
                   ", 所属网格价位=" + DoubleToString(nearestGridPrice) + 
                   ", 止损/止盈价=" + DoubleToString(stopLossPrice));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 检查指定价位是否在止损/止盈价位列表中                            |
//+------------------------------------------------------------------+
bool IsPriceInStopLossList(double price)
{
   double normalizedPrice = NormalizeDouble(price, precisionDigits);
   for(int i = 0; i < ArraySize(stopLossPrices); i++)
   {
      if(normalizedPrice == stopLossPrices[i])
      {
         if(EnableLogging)
         {
            Log("价位 " + DoubleToString(price) + " 与持仓止损/止盈价重合，无法挂单");
         }
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Log("账户不允许交易");
      return(INIT_FAILED);
   }
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_DISABLED)
   {
      Log("市场未开放");
      return(INIT_FAILED);
   }
   
   long chartId = ChartID();
   string timeframe = EnumToString(_Period);
   EXIT_SIGNAL = "Mayfly3.1_" + _Symbol + "_" + timeframe + "_Exit_" + IntegerToString(chartId);
   CLEANUP_DONE = "Mayfly3.1_" + _Symbol + "_" + timeframe + "_CleanupDone_" + IntegerToString(chartId);
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            trade.OrderDelete(ticket);
         }
      }
   }
   
   GlobalVariableSet(EXIT_SIGNAL, 0);
   if(GlobalVariableCheck(CLEANUP_DONE))
      GlobalVariableDel(CLEANUP_DONE);
   
   // 缓存静态变量
   cachedSymbolPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   precisionDigits = (int)MathCeil(-MathLog10(cachedSymbolPoint)) - 1;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   cachedContractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   cachedTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   cachedTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   cachedMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   cachedMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   cachedLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   Log("缓存静态变量：contractSize=" + DoubleToString(cachedContractSize) + 
       ", tickValue=" + DoubleToString(cachedTickValue) + 
       ", tickSize=" + DoubleToString(cachedTickSize) + 
       ", minLot=" + DoubleToString(cachedMinLot) + 
       ", maxLot=" + DoubleToString(cachedMaxLot) + 
       ", lotStep=" + DoubleToString(cachedLotStep) + 
       ", symbolPoint=" + DoubleToString(cachedSymbolPoint));
   
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
      GridStep = NormalizeDouble(GridSpacing * cachedSymbolPoint, precisionDigits);
   }
   else
   {
      atrValue = GetATRValue(_Symbol, _Period, ATR_Period); // 使用当前图表周期
      GridStep = NormalizeDouble(atrValue > 0 ? atrValue * 2.0 : 0.01, precisionDigits);
   }
   
   // 保存原始 GridStep 值
   originalGridStep = GridStep;
   
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
   Log("网格初始化完成，上边界=" + DoubleToString(grid.upperBound) + "，下边界=" + DoubleToString(grid.lowerBound));
   
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   Log("Mayfly 3.1 初始化完成，主人，准备好啦！镜像模式=" + (EnableMirror ? "开启" : "关闭") +
       ", 加仓模式=" + EnumToString(AddPositionMode) +
       ", 加仓次数=" + IntegerToString(AddPositionTimes) +
       ", 动态网格=" + (EnableDynamicGrid ? "开启" : "关闭") +
       ", 异常止损倍数=" + DoubleToString(AbnormalStopLossMultiplier) +
       ", 活跃时区=" + IntegerToString(ActiveZoneStartHour) + "点至" + IntegerToString(ActiveZoneEndHour) + "点");
   
   SetupGridOrders();
   DrawBasePriceLine();
   lastDealTicket = GetLastDealTicket();
   lastBidPrice = currentPrice;
   lastGridUpdateTime = TimeCurrent(); // 初始化上次网格更新时间
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
   Log("Mayfly 3.1 停止运行，主人，下次见哦！原因代码=" + IntegerToString(reason));
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
      Log("嘿，主人！超过交易结束时间 (" + IntegerToString(EndHour) + "点) 啦，赶紧平仓所有订单并取消所有挂单！");
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

   // 缓存订单和持仓数量
   int totalOrders = OrdersTotal();
   int totalPositions = PositionsTotal();

   // 缓存持仓的网格价位和止损/止盈价位
   CachePositionGridPrices();

   stopLossDetected = false;

   if(GlobalVariableGet(EXIT_SIGNAL) == 1)
   {
      Log("主人，检测到退出信号，清理订单并撤退啦！");
      CleanupOrders();
      ExpertRemove();
      return;
   }

   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 检查时区并调整 GridStep
   datetime currentTimeSec = TimeCurrent();
   if(currentTimeSec - lastGridUpdateTime >= 60) // 每分钟检查一次
   {
      bool isActiveZone = (currentHour >= ActiveZoneStartHour && currentHour < ActiveZoneEndHour);
      if(isActiveZone != lastActiveZoneState) // 时区状态发生变化
      {
         if(isActiveZone)
         {
            // 进入活跃时区，GridStep 变为 2 倍
            GridStep = originalGridStep * 2.0;
            Log("进入活跃时区 (" + IntegerToString(ActiveZoneStartHour) + "点至" + IntegerToString(ActiveZoneEndHour) + "点)，GridStep 调整为 2 倍，原 GridStep=" + DoubleToString(originalGridStep) + "，新 GridStep=" + DoubleToString(GridStep));
         }
         else
         {
            // 退出活跃时区，恢复原始 GridStep
            GridStep = originalGridStep;
            Log("退出活跃时区，恢复原始 GridStep，原 GridStep=" + DoubleToString(originalGridStep) + "，新 GridStep=" + DoubleToString(GridStep));
         }

         // 重构网格
         ArrayResize(grid.upperGrid, GridLevels);
         ArrayResize(grid.lowerGrid, GridLevels);
         for(int i = 0; i < GridLevels; i++)
         {
            grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * GridStep, precisionDigits);
            grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * GridStep, precisionDigits);
         }
         grid.upperBound = grid.upperGrid[GridLevels - 1];
         grid.lowerBound = grid.lowerGrid[GridLevels - 1];
         Log("因时区变化重构网格，新上边界=" + DoubleToString(grid.upperBound) + ", 新下边界=" + DoubleToString(grid.lowerBound));

         // 删除旧挂单
         CleanupOrders();
         Log("因时区变化调整 GridStep，删除所有旧挂单");

         lastActiveZoneState = isActiveZone; // 更新时区状态
      }

      // 如果开启动态网格，实时更新 GridStep
      if(EnableDynamicGrid && GridSpacing <= 0)
      {
         double newAtrValue = GetATRValue(_Symbol, _Period, ATR_Period);
         if(newAtrValue > 0)
         {
            double newGridStep = NormalizeDouble(newAtrValue * 2.0, precisionDigits);
            if(newGridStep != originalGridStep)
            {
               Log("动态网格更新：旧 originalGridStep=" + DoubleToString(originalGridStep) + 
                   ", 新 ATR=" + DoubleToString(newAtrValue) + 
                   ", 新 originalGridStep=" + DoubleToString(newGridStep));
               originalGridStep = newGridStep;
               // 根据当前时区调整 GridStep
               if(isActiveZone)
                  GridStep = originalGridStep * 2.0;
               else
                  GridStep = originalGridStep;

               // 重构网格
               ArrayResize(grid.upperGrid, GridLevels);
               ArrayResize(grid.lowerGrid, GridLevels);
               for(int i = 0; i < GridLevels; i++)
               {
                  grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * GridStep, precisionDigits);
                  grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * GridStep, precisionDigits);
               }
               grid.upperBound = grid.upperGrid[GridLevels - 1];
               grid.lowerBound = grid.lowerGrid[GridLevels - 1];
               Log("因动态网格调整重构网格，新上边界=" + DoubleToString(grid.upperBound) + 
                   ", 新下边界=" + DoubleToString(grid.lowerBound));

               // 删除旧挂单
               CleanupOrders();
               Log("因动态网格调整 GridStep，删除所有旧挂单");
            }
         }
      }
      lastGridUpdateTime = currentTimeSec; // 更新时间戳
   }

   // 仅在价格变化超过 GridStep 时检查移位
   if(MathAbs(bidPrice - lastBidPrice) >= GridStep)
   {
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
      lastBidPrice = bidPrice;
   }

   ulong currentDealTicket = GetLastDealTicket();
   if(currentDealTicket > lastDealTicket || stopLossDetected)
   {
      UpdateStopLosses();
      stopLossesUpdated = true;  // 标记止损数组需要更新
      lastDealTicket = currentDealTicket;
   }

   // 在止损移动之后，检查异常止损情况
   CheckAbnormalStopLoss();

   // 先挂单，后检查取消挂单
   PlaceGridOrders(totalPositions);

   if(totalPositions > 0 && totalOrders > 0)
      CancelOrdersMatchingStopLoss();
}

//+------------------------------------------------------------------+
//| 统一挂单逻辑                                                      |
//+------------------------------------------------------------------+
void PlaceGridOrders(int totalPositions)
{
   if(totalPositions >= GridLevels)
   {
      Log("持仓数量已达到网格数量上限，暂停挂单，当前持仓=" + IntegerToString(totalPositions));
      return;
   }

   bool allowBuy = !stopLossDetected || lastStopLossType != POSITION_TYPE_SELL;
   bool allowSell = !stopLossDetected || lastStopLossType != POSITION_TYPE_BUY;

   // 计算当前持仓的总手数
   double totalLots = 0.0;
   for(int i = 0; i < totalPositions; i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(positionSymbols[i] == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            totalLots += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   // 遍历所有网格价位，统一挂单
   int addCount = 0; // 当前加仓次数
   for(int i = 0; i < GridLevels; i++)
   {
      if(addCount >= AddPositionTimes)
      {
         Log("加仓次数已达到上限，暂停挂单，加仓次数=" + IntegerToString(addCount));
         break;
      }

      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(GridStep, sellPrice);

      // 检查同一网格位置是否已有挂单或持仓
      bool buyPriceHasOrder = OrderExists(buyPrice);
      bool buyPriceHasPosition = PositionExists(buyPrice);
      bool sellPriceHasOrder = OrderExists(sellPrice);
      bool sellPriceHasPosition = PositionExists(sellPrice);

      // 检查价位是否与止损/止盈重合
      bool buyPriceConflictsWithStopLoss = IsPriceInStopLossList(buyPrice);
      bool sellPriceConflictsWithStopLoss = IsPriceInStopLossList(sellPrice);

      // 计算当前加仓手数
      double currentBuyLotSize = 0.0;
      double currentSellLotSize = 0.0;
      if(AddPositionMode == ADD_MODE_UNIFORM)
      {
         // 匀速加仓：每次加仓固定手数
         double uniformLotSize = lotSizeBuy; // 以 CalculateLotSize 计算的基础手数为准
         if(totalLots + uniformLotSize <= MaxTotalLots)
         {
            currentBuyLotSize = uniformLotSize;
            currentSellLotSize = lotSizeSell;
         }
      }
      else if(AddPositionMode == ADD_MODE_PYRAMID)
      {
         // 正金字塔加仓：底仓大，上面小，每次挂单递减
         double firstLotSize = lotSizeBuy; // 底仓手数基于 CalculateLotSize
         double minLotSize = 0.01; // 最小手数
         double decrement = (AddPositionTimes > 1) ? (firstLotSize - minLotSize) / (AddPositionTimes - 1) : 0; // 每次递减量
         double currentLotSize = firstLotSize - (decrement * addCount); // 当前加仓手数

         // 确保手数不低于 0.01
         if(currentLotSize < minLotSize)
         {
            currentLotSize = minLotSize;
         }

         // 买单挂单
         if(currentLotSize > 0 && allowBuy && !buyPriceHasOrder && !buyPriceHasPosition && 
            !buyPriceConflictsWithStopLoss && buyPrice != lastStopLossPrice)
         {
            if(totalLots + currentLotSize <= MaxTotalLots)
            {
               currentBuyLotSize = currentLotSize;
            }
         }

         // 卖单挂单（在买单之后，可能需要重新计算手数）
         if(currentLotSize > 0 && allowSell && !sellPriceHasOrder && !sellPriceHasPosition && 
            !sellPriceConflictsWithStopLoss && sellPrice != lastStopLossPrice)
         {
            if(totalLots + currentLotSize <= MaxTotalLots)
            {
               currentSellLotSize = currentLotSize;
            }
         }
      }
      else if(AddPositionMode == ADD_MODE_INV_PYRAMID)
      {
         // 倒金字塔加仓：底仓小，上面大
         int currentAddIndex = addCount + 1; // 当前加仓序号（从 1 开始）
         double totalAddTimes = MathMin(AddPositionTimes, (int)(MaxTotalLots / lotSizeBuy));
         if(totalAddTimes > 0)
         {
            double currentLotSize = (lotSizeBuy / (totalAddTimes * (totalAddTimes + 1) / 2)) * currentAddIndex;
            if(totalLots + currentLotSize <= MaxTotalLots)
            {
               currentBuyLotSize = currentLotSize;
               currentSellLotSize = currentLotSize;
            }
         }
      }

      if(EnableMirror)
      {
         // 镜像模式：在 sellPrice 挂 BuyLimit，在 buyPrice 挂 SellLimit
         if(currentSellLotSize > 0 && allowBuy && !sellPriceHasOrder && !sellPriceHasPosition && 
            !sellPriceConflictsWithStopLoss && sellPrice != lastStopLossPrice)
         {
            double buyLimitTpPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
            trade.BuyLimit(currentSellLotSize, sellPrice, _Symbol, 0, buyLimitTpPrice, ORDER_TIME_GTC, 0, "Buy Limit Grid (Mirror - Place)");
            Log("挂单 BuyLimit，价格=" + DoubleToString(sellPrice) + ", 止盈价=" + DoubleToString(buyLimitTpPrice) + ", 手数=" + DoubleToString(currentSellLotSize));
            totalLots += currentSellLotSize;
            addCount++;
         }

         if(currentBuyLotSize > 0 && allowSell && !buyPriceHasOrder && !buyPriceHasPosition && 
            !buyPriceConflictsWithStopLoss && buyPrice != lastStopLossPrice)
         {
            double sellLimitTpPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
            trade.SellLimit(currentBuyLotSize, buyPrice, _Symbol, 0, sellLimitTpPrice, ORDER_TIME_GTC, 0, "Sell Limit Grid (Mirror - Place)");
            Log("挂单 SellLimit，价格=" + DoubleToString(buyPrice) + ", 止盈价=" + DoubleToString(sellLimitTpPrice) + ", 手数=" + DoubleToString(currentBuyLotSize));
            totalLots += currentBuyLotSize;
            addCount++;
         }
      }
      else
      {
         // 非镜像模式：在 buyPrice 挂 BuyStop，在 sellPrice 挂 SellStop
         if(AddPositionMode == ADD_MODE_PYRAMID)
         {
            // 正金字塔加仓：每次挂单递减
            double firstLotSize = lotSizeBuy; // 底仓手数基于 CalculateLotSize
            double minLotSize = 0.01; // 最小手数
            double decrement = (AddPositionTimes > 1) ? (firstLotSize - minLotSize) / (AddPositionTimes - 1) : 0; // 每次递减量

            // 买单挂单
            if(currentBuyLotSize > 0 && allowBuy && !buyPriceHasOrder && !buyPriceHasPosition && 
               !buyPriceConflictsWithStopLoss && buyPrice != lastStopLossPrice)
            {
               double buySlPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
               trade.BuyStop(currentBuyLotSize, buyPrice, _Symbol, buySlPrice, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid (Place)");
               Log("挂单 BuyStop，价格=" + DoubleToString(buyPrice) + ", 止损价=" + DoubleToString(buySlPrice) + ", 手数=" + DoubleToString(currentBuyLotSize));
               totalLots += currentBuyLotSize;
               addCount++; // 每次挂单后递增

               // 重新计算手数
               currentBuyLotSize = firstLotSize - (decrement * addCount);
               if(currentBuyLotSize < minLotSize) currentBuyLotSize = minLotSize;
               currentSellLotSize = currentBuyLotSize; // 同步卖单手数
            }

            // 卖单挂单
            if(currentSellLotSize > 0 && allowSell && !sellPriceHasOrder && !sellPriceHasPosition && 
               !sellPriceConflictsWithStopLoss && sellPrice != lastStopLossPrice)
            {
               double sellSlPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
               trade.SellStop(currentSellLotSize, sellPrice, _Symbol, sellSlPrice, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid (Place)");
               Log("挂单 SellStop，价格=" + DoubleToString(sellPrice) + ", 止损价=" + DoubleToString(sellSlPrice) + ", 手数=" + DoubleToString(currentSellLotSize));
               totalLots += currentSellLotSize;
               addCount++; // 每次挂单后递增

               // 重新计算手数
               currentSellLotSize = firstLotSize - (decrement * addCount);
               if(currentSellLotSize < minLotSize) currentSellLotSize = minLotSize;
               currentBuyLotSize = currentSellLotSize; // 同步买单手数
            }
         }
         else
         {
            // 非正金字塔模式（匀速或倒金字塔）
            if(currentBuyLotSize > 0 && allowBuy && !buyPriceHasOrder && !buyPriceHasPosition && 
               !buyPriceConflictsWithStopLoss && buyPrice != lastStopLossPrice)
            {
               double buySlPrice = NormalizeDouble(buyPrice - GridStep, precisionDigits);
               trade.BuyStop(currentBuyLotSize, buyPrice, _Symbol, buySlPrice, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid (Place)");
               Log("挂单 BuyStop，价格=" + DoubleToString(buyPrice) + ", 止损价=" + DoubleToString(buySlPrice) + ", 手数=" + DoubleToString(currentBuyLotSize));
               totalLots += currentBuyLotSize;
               addCount++;
            }

            if(currentSellLotSize > 0 && allowSell && !sellPriceHasOrder && !sellPriceHasPosition && 
               !sellPriceConflictsWithStopLoss && sellPrice != lastStopLossPrice)
            {
               double sellSlPrice = NormalizeDouble(sellPrice + GridStep, precisionDigits);
               trade.SellStop(currentSellLotSize, sellPrice, _Symbol, sellSlPrice, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid (Place)");
               Log("挂单 SellStop，价格=" + DoubleToString(sellPrice) + ", 止损价=" + DoubleToString(sellSlPrice) + ", 手数=" + DoubleToString(currentSellLotSize));
               totalLots += currentSellLotSize;
               addCount++;
            }
         }
      }

      if(totalLots >= MaxTotalLots)
      {
         Log("总手数达到上限，暂停挂单，总手数=" + DoubleToString(totalLots));
         break;
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
         if(positionSymbols[i] == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            if(!trade.PositionClose(ticket))
               Log("哎呀，平仓失败啦，票号=" + IntegerToString(ticket) + "，错误代码=" + IntegerToString(GetLastError()));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 清理所有挂单                                                      |
//+------------------------------------------------------------------+
void CleanupOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            trade.OrderDelete(ticket);
         }
      }
   }
   GlobalVariableSet(CLEANUP_DONE, 1);
   GlobalVariableSet(EXIT_SIGNAL, 0);
   Log("清理完成，主人，干得漂亮吧！");
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
      return;

   PlaceGridOrders(totalPositions);
}

//+------------------------------------------------------------------+
//| 调整网格订单                                                      |
//+------------------------------------------------------------------+
void AdjustGridOrders()
{
   int totalPositions = PositionsTotal();

   if(totalPositions >= GridLevels)
      return;

   // 删除超出边界的老挂单
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            if(orderPrice > grid.upperBound || orderPrice < grid.lowerBound)
            {
               trade.OrderDelete(ticket);
            }
         }
      }
   }

   // 重新挂单
   PlaceGridOrders(totalPositions);
}

//+------------------------------------------------------------------+
//| 更新所有持仓止损（原有逻辑，镜像时改为止盈）                     |
//+------------------------------------------------------------------+
void UpdateStopLosses()
{
   int totalPositions = PositionsTotal();
   if(totalPositions == 0) return;

   double newBuyLimit = 0;
   double newSellLimit = 0;
   datetime latestTime = 0;

   // 单次遍历：查找最新止损/止盈并更新
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(positionSymbols[i] == _Symbol && 
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
                     newBuyLimit = tpPrice;
                  else
                     newSellLimit = tpPrice;
                  lastStopLossPrice = tpPrice;
               }
               else
               {
                  double slPrice = PositionGetDouble(POSITION_SL);
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                     newBuyLimit = slPrice;
                  else
                     newSellLimit = slPrice;
                  lastStopLossPrice = slPrice;
               }
            }
         }
      }
   }

   // 仅在止损/止盈变化时更新
   if((newBuyLimit > 0 && newBuyLimit != lastBuyLimit) || (newSellLimit > 0 && newSellLimit != lastSellLimit))
   {
      for(int i = totalPositions - 1; i >= 0; i--)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            if(positionSymbols[i] == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
            {
               if(EnableMirror)
               {
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newBuyLimit > 0)
                  {
                     double newTpPrice = NormalizeDouble(newBuyLimit, precisionDigits);
                     if(newTpPrice != PositionGetDouble(POSITION_TP))
                     {
                        trade.PositionModify(PositionGetTicket(i), 0, newTpPrice);
                     }
                  }
                  else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && newSellLimit > 0)
                  {
                     double newTpPrice = NormalizeDouble(newSellLimit, precisionDigits);
                     if(newTpPrice != PositionGetDouble(POSITION_TP))
                     {
                        trade.PositionModify(PositionGetTicket(i), 0, newTpPrice);
                     }
                  }
               }
               else
               {
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newBuyLimit > 0)
                  {
                     double newSlPrice = NormalizeDouble(newBuyLimit, precisionDigits);
                     if(newSlPrice != PositionGetDouble(POSITION_SL))
                     {
                        trade.PositionModify(PositionGetTicket(i), newSlPrice, 0);
                     }
                  }
                  else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && newSellLimit > 0)
                  {
                     double newSlPrice = NormalizeDouble(newSellLimit, precisionDigits);
                     if(newSlPrice != PositionGetDouble(POSITION_SL))
                     {
                        trade.PositionModify(PositionGetTicket(i), newSlPrice, 0);
                     }
                  }
               }
            }
         }
      }
      lastBuyLimit = newBuyLimit;
      lastSellLimit = newSellLimit;
   }
}

//+------------------------------------------------------------------+
//| 取消与持仓止损/止盈重合的挂单并记录类型                          |
//+------------------------------------------------------------------+
void CancelOrdersMatchingStopLoss()
{
   int totalPositions = PositionsTotal();
   
   // 更新止损/止盈数组
   if(stopLossesUpdated || ArraySize(stopLosses) != totalPositions)
   {
      ArrayResize(stopLosses, totalPositions);
      int stopLossCount = 0;
      for(int i = totalPositions - 1; i >= 0; i--)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            if(positionSymbols[i] == _Symbol && 
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
      stopLossesUpdated = false;
   }

   int stopLossCount = ArraySize(stopLosses);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && 
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
                     lastStopLossPrice = orderPrice;
                     Log("检测到" + (EnableMirror ? "止盈" : "止损") + "，类型=" + EnumToString(lastStopLossType) + "，价格=" + DoubleToString(orderPrice));
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
//| 检查指定价位是否已有挂单（任何类型）                              |
//+------------------------------------------------------------------+
bool OrderExists(double price)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), precisionDigits);
         double normalizedPrice = NormalizeDouble(price, precisionDigits);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && orderPrice == normalizedPrice)
         {
            return true;  // 找到任何类型的挂单
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 检查指定网格价位是否已有持仓（考虑滑点）                          |
//+------------------------------------------------------------------+
bool PositionExists(double gridPrice)
{
   double normalizedGridPrice = NormalizeDouble(gridPrice, precisionDigits);
   double tolerance = GridStep * SlippageTolerance;
   double lowerBound = normalizedGridPrice - tolerance;
   double upperBound = normalizedGridPrice + tolerance;

   // 遍历缓存的网格价位
   for(int i = 0; i < ArraySize(positionGridPrices); i++)
   {
      double cachedGridPrice = NormalizeDouble(positionGridPrices[i], precisionDigits);
      if(cachedGridPrice == normalizedGridPrice)
      {
         if(EnableLogging)
         {
            Log("网格价位 " + DoubleToString(gridPrice) + " 已存在持仓（缓存匹配），缓存网格价=" + DoubleToString(cachedGridPrice));
         }
         return true;
      }
   }

   // 再次遍历实际持仓，确保缓存未遗漏
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(positionSymbols[i] == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            double positionPrice = positionOpenPrices[i];
            if(positionPrice >= lowerBound && positionPrice < upperBound)
            {
               if(EnableLogging)
               {
                  Log("网格价位 " + DoubleToString(gridPrice) + " 已存在持仓，持仓价=" + DoubleToString(positionPrice) + 
                      ", 网格范围=[" + DoubleToString(lowerBound) + "," + DoubleToString(upperBound) + ")");
               }
               // 检查滑点是否过大
               if(MathAbs(positionPrice - normalizedGridPrice) > GridStep)
               {
                  Log("警告：持仓价 " + DoubleToString(positionPrice) + " 与网格价 " + DoubleToString(normalizedGridPrice) + 
                      " 偏差过大（超过 GridStep=" + DoubleToString(GridStep) + "），建议调整 GridStep 或 SlippageTolerance");
               }
               return true;
            }
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
   {
      return NormalizeDouble(LotSize, 2);
   }

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(accountBalance <= 0)
   {
      Log("错误：账户余额为 0，无法计算手数");
      return 0;
   }

   double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   if(leverage <= 0) leverage = 100;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   // 按标准合约计算 marginPerLot
   double marginPerLot = (cachedContractSize * price) / leverage;

   double lotSize = 0.0;

   if(TradeMode == TRADE_MODE_PERCENT)
   {
      // 百分比开仓模式：基于最大可用资金
      double maxAvailableCapital = accountBalance * (PositionPercent / 100.0) * leverage;
      lotSize = maxAvailableCapital / marginPerLot;
   }
   else if(TradeMode == TRADE_MODE_STOPLOSS_PERCENT)
   {
      // 止损比例开仓模式：基于最大损失金额
      double maxLossAmount = accountBalance * (StopLossPercent / 100.0);

      if(cachedTickSize == 0)
      {
         Log("错误：tickSize 为 0，无法计算手数");
         return 0;
      }

      // 每手止损损失（按标准合约计算）
      double points = stopLossDistance / cachedTickSize; // 止损点数
      double lossPerLot = points * cachedTickValue; // 每手止损损失
      if(lossPerLot <= 0)
      {
         Log("错误：lossPerLot <= 0, stopLossDistance=" + DoubleToString(stopLossDistance) + 
             ", tickSize=" + DoubleToString(cachedTickSize) + ", tickValue=" + DoubleToString(cachedTickValue));
         return 0;
      }

      lotSize = maxLossAmount / lossPerLot;

      if(EnableLogging)
      {
         Log("StopLossPercent 模式计算：maxLossAmount=" + DoubleToString(maxLossAmount) + 
             ", stopLossDistance=" + DoubleToString(stopLossDistance) + 
             ", tickSize=" + DoubleToString(cachedTickSize) + 
             ", tickValue=" + DoubleToString(cachedTickValue) + 
             ", points=" + DoubleToString(points) + 
             ", lossPerLot=" + DoubleToString(lossPerLot) + 
             ", lotSize（未限制前，标准手）=" + DoubleToString(lotSize));
      }
   }

   // 严格限制手数（基于标准合约）
   double maxLotByMargin = freeMargin / marginPerLot;
   double standardLotSize = lotSize; // 保存标准手数
   lotSize = MathMin(lotSize, maxLotByMargin);
   lotSize = MathMax(cachedMinLot, MathMin(cachedMaxLot, lotSize));
   lotSize = MathRound(lotSize / cachedLotStep) * cachedLotStep;
   lotSize = NormalizeDouble(lotSize, 2);

   // 再次验证保证金（基于标准合约）
   if(lotSize <= 0 || lotSize * marginPerLot > freeMargin)
   {
      Log("错误：手数 " + DoubleToString(lotSize) + " 超过可用保证金，freeMargin=" + DoubleToString(freeMargin) + 
          ", marginPerLot=" + DoubleToString(marginPerLot));
      return 0;
   }

   // 仅在止损开仓模式下调整手数为迷你手
   double finalLotSize = lotSize;
   if(TradeMode == TRADE_MODE_STOPLOSS_PERCENT && IsMiniLot)
   {
      finalLotSize = lotSize * 10.0; // 1 标准手 = 10 迷你手
   }

   if(EnableLogging)
   {
      Log("CalculateLotSize: TradeMode=" + EnumToString(TradeMode) + 
          ", accountBalance=" + DoubleToString(accountBalance) + 
          ", leverage=" + DoubleToString(leverage) + 
          ", freeMargin=" + DoubleToString(freeMargin) + 
          ", marginPerLot=" + DoubleToString(marginPerLot) + 
          ", maxLotByMargin=" + DoubleToString(maxLotByMargin) + 
          ", standardLotSize=" + DoubleToString(standardLotSize) + 
          ", lotSize（调整后，" + (IsMiniLot && TradeMode == TRADE_MODE_STOPLOSS_PERCENT ? "迷你手" : "标准手") + "）=" + DoubleToString(finalLotSize));
   }

   return finalLotSize;
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
//+------------------------------------------------------------------+v
