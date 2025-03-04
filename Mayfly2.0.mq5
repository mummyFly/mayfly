//+------------------------------------------------------------------+
//| Expert Advisor: Mayfly 3.2.16 System                             |
//| Description: Pre-set Stop Order Grid Trading System with Dynamic Base Price |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property link      "https://xai.com"
#property version   "3.2.16"

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

// 网格结构定义
struct GridStructure
{
   double basePrice;          // 网格的基准价格，所有网格以此为中心展开
   double upperBound;         // 网格的上边界，即最高的上方网格价格
   double lowerBound;         // 网格的下边界，即最低的下方网格价格
   double upperGrid[];        // 上方网格价格数组，存储基准价以上的网格点
   double lowerGrid[];        // 下方网格价格数组，存储基准价以下的网格点
   double GridStep;           // 当前网格间距，根据 GridSpacing 或 ATR 计算
   double originalGridStep;   // 原始网格间距，用于时区调整时的恢复
};

// 订单信息结构体
struct PositionInfo
{
   string symbol;             // 交易品种
   double openPrice;          // 开仓价格
   double gridPrice;          // 所属网格价格
   double stopLossPrice;      // 止损/止盈价格（非镜像模式为 SL，镜像模式为 TP）
   int gridLevel;             // 所属网格层级（对应 upperGrid[] 或 lowerGrid[] 的索引，负数表示下网格）
};

// 输入参数（用户可配置的参数）
input double GridSpacing = -1;        // 网格间距（点数），-1 表示使用 ATR 动态计算
input double LotSize = 0.1;           // 固定手数，当 TradeMode = TRADE_MODE_FIXED 时使用，默认 0.1 标准手
input int GridLevels = 20;            // 网格数量，上下各生成多少个网格，默认 20 层
input int StartHour = 0;              // 开始交易时间（小时，0-23），默认 0 点（全天开始）
input int EndHour = 23;               // 结束交易时间（小时，0-23），默认 23 点（全天结束）
input int ActiveZoneStartHour = 14;   // 活跃时区开始时间（小时，0-23），默认 14 点
input int ActiveZoneEndHour = 22;     // 活跃时区结束时间（小时，0-23），默认 22 点
input int ATR_Period = 14;            // ATR 计算周期，默认 14，用于动态网格间距
input ENUM_TRADE_MODE TradeMode = TRADE_MODE_FIXED; // 开仓模式，默认固定手数模式
input bool IsMiniLot = true;          // 是否使用迷你手（1 迷你手 = 0.1 标准手），默认 true，仅在止损比例模式生效
input double PositionPercent = 5.0;   // 百分比开仓模式下，每笔订单占用账户余额的百分比，默认 5%
input double StopLossPercent = 5.0;   // 止损比例开仓模式下，每笔订单最大损失占账户余额的百分比，默认 5%
input double InputBasePrice = 0;      // 用户手动输入的基准价格，0 表示使用当前市场价格
input double SlippageTolerance = 0.5; // 滑点容忍范围（以 GridStep 为单位），默认 0.5，用于判断网格占用
input bool EnableMirror = false;      // 是否开启镜像逻辑（使用 Limit 订单和止盈），默认关闭（使用 Stop 订单和止损）
input bool EnableLogging = false;     // 是否启用日志记录，默认关闭以减少输出
input ENUM_ADD_MODE AddPositionMode = ADD_MODE_UNIFORM; // 加仓模式，默认匀速加仓
input double MaxTotalLots = 100.0;    // 最大总手数限制，默认 100 手
input int AddPositionTimes = 10;      // 最大加仓次数，默认 10 次
input bool EnableDynamicGrid = false; // 是否开启动态网格（根据 ATR 实时调整），默认关闭
input double AbnormalStopLossMultiplier = 3.0; // 异常止损倍数，默认 3 倍网格间距，用于检测异常波动

// 全局变量
GridStructure grid;                   // 网格对象，存储当前网格结构（包含 GridStep 和 originalGridStep）
CTrade trade;                         // 交易对象，用于执行订单操作
double atrValue;                      // 当前 ATR 值，用于动态网格计算
ulong lastDealTicket = 0;             // 最后处理的成交票号，用于检测新成交
int precisionDigits;                  // 计算精度（比市场点值精度多一位），用于价格标准化
const long MAGIC_NUMBER = StringToInteger("Mayfly3.2"); // EA 的魔术号，唯一标识订单
string EXIT_SIGNAL;                   // 退出信号全局变量名称，图表特定
string CLEANUP_DONE;                  // 清理完成标志全局变量名称，图表特定
ENUM_POSITION_TYPE lastStopLossType = POSITION_TYPE_BUY; // 最近止损/止盈的订单类型（买单/卖单）
bool stopEventDetected = false;       // 当前 Tick 是否检测到止损/止盈事件
bool hasCleanedUpAfterEnd = false;    // 是否已执行超时清理，避免重复
double lastStopLossPrice = 0;         // 最新的止损/止盈价格
double lastBidPrice = 0;              // 上次记录的 Bid 价格，用于检测价格移动
double stopLosses[];                  // 止损/止盈价格数组（当前未直接使用，保留兼容性）
bool stopLossesUpdated = false;       // 止损/止盈数据是否需要更新
double lastBuyStopLoss = 0;           // 买单的最新止损/止盈价格（全局缓存，非镜像模式为止损，镜像模式为止盈）
double lastSellStopLoss = 0;          // 卖单的最新止损/止盈价格（全局缓存，非镜像模式为止损，镜像模式为止盈）
PositionInfo positionsInfo[];         // 缓存所有持仓信息的数组
datetime lastGridUpdateTime = 0;      // 上次网格更新的时间戳（秒）
bool lastActiveZoneState = false;     // 上次活跃时区状态（true 表示活跃）
bool isFirstTick = true;              // 是否为第一个 Tick，用于延迟初始化

double cachedContractSize;            // 缓存的合约大小，从 SymbolInfo 获取
double cachedTickValue;               // 缓存的每点价值
double cachedTickSize;                // 缓存的点值单位
double cachedMinLot;                  // 缓存的最小手数
double cachedMaxLot;                  // 缓存的最大手数
double cachedLotStep;                 // 缓存的手数步长
double cachedSymbolPoint;             // 缓存的点值（Symbol Point）
//+------------------------------------------------------------------+
//| 自定义日志函数                                                    |
//+------------------------------------------------------------------+
void Log(string message)
{
   if(EnableLogging)
      Print(message);
}

//+------------------------------------------------------------------+
//| 判断价格是否与最新止损/止盈重合                                  |
//+------------------------------------------------------------------+
bool IsPriceAtStopLoss(double price)
{
   double normalizedPrice = NormalizeDouble(price, precisionDigits);
   double buyStopLoss = NormalizeDouble(lastBuyStopLoss, precisionDigits);
   double sellStopLoss = NormalizeDouble(lastSellStopLoss, precisionDigits);
   return (normalizedPrice == buyStopLoss || normalizedPrice == sellStopLoss);
}

//+------------------------------------------------------------------+
//| 检查异常止损情况                                                  |
//+------------------------------------------------------------------+
void CheckAbnormalStopLoss()
{
   if(lastStopLossPrice == 0) return;

   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double priceDiff = 0.0;

   if(lastStopLossType == POSITION_TYPE_BUY)
   {
      priceDiff = lastStopLossPrice - bidPrice;
   }
   else if(lastStopLossType == POSITION_TYPE_SELL)
   {
      priceDiff = bidPrice - lastStopLossPrice;
   }

   double threshold = AbnormalStopLossMultiplier * grid.GridStep;
   if(priceDiff > threshold)
   {
      Log("检测到异常止损情况！平掉全部订单！");
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| 缓存持仓的网格价位和止损/止盈价位                                |
//+------------------------------------------------------------------+
void CachePositionGridPrices()
{
   int totalPositions = PositionsTotal();
   if(totalPositions <= 0)
   {
      ArrayResize(positionsInfo, 0);
      return;
   }

   if(ArrayResize(positionsInfo, totalPositions) < 0)
   {
      Log("错误：缓存数组调整大小失败，totalPositions=" + IntegerToString(totalPositions));
      return;
   }

   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
      {
         Log("警告：无法获取或选择持仓，索引=" + IntegerToString(i));
         continue;
      }

      positionsInfo[i].symbol = PositionGetString(POSITION_SYMBOL);
      positionsInfo[i].openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(positionsInfo[i].symbol == "" || positionsInfo[i].openPrice == 0)
      {
         Log("警告：持仓数据无效，索引=" + IntegerToString(i));
         continue;
      }

      if(positionsInfo[i].symbol == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
      {
         double positionPrice = positionsInfo[i].openPrice;
         double shift = MathRound((positionPrice - grid.basePrice) / grid.GridStep);
         positionsInfo[i].gridPrice = NormalizeDouble(grid.basePrice + shift * grid.GridStep, precisionDigits);
         positionsInfo[i].stopLossPrice = EnableMirror ? PositionGetDouble(POSITION_TP) : PositionGetDouble(POSITION_SL);
         positionsInfo[i].gridLevel = (int)shift;
         if(EnableLogging)
         {
            Log("持仓 " + IntegerToString(i) + " 开仓价=" + DoubleToString(positionPrice) + 
                ", 所属网格价位=" + DoubleToString(positionsInfo[i].gridPrice) + 
                ", 止损/止盈价=" + DoubleToString(positionsInfo[i].stopLossPrice) + 
                ", 网格层级=" + IntegerToString(positionsInfo[i].gridLevel));
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
   for(int i = 0; i < ArraySize(positionsInfo); i++)
   {
      if(normalizedPrice == NormalizeDouble(positionsInfo[i].stopLossPrice, precisionDigits))
      {
         if(EnableLogging)
            Log("价位 " + DoubleToString(price) + " 与持仓止损/止盈价重合，无法挂单");
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
   EXIT_SIGNAL = "Mayfly3.2_" + _Symbol + "_" + timeframe + "_Exit_" + IntegerToString(chartId);
   CLEANUP_DONE = "Mayfly3.2_" + _Symbol + "_" + timeframe + "_CleanupDone_" + IntegerToString(chartId);
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
            trade.OrderDelete(ticket);
      }
   }
   
   GlobalVariableSet(EXIT_SIGNAL, 0);
   if(GlobalVariableCheck(CLEANUP_DONE))
      GlobalVariableDel(CLEANUP_DONE);
   
   cachedSymbolPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   precisionDigits = (int)MathCeil(-MathLog10(cachedSymbolPoint)) - 1;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   cachedContractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   cachedTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   cachedTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   cachedMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   cachedMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   cachedLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

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
      grid.GridStep = NormalizeDouble(GridSpacing * cachedSymbolPoint, precisionDigits);
   }
   else
   {
      atrValue = GetATRValue(_Symbol, _Period, ATR_Period);
      grid.GridStep = NormalizeDouble(atrValue > 0 ? atrValue * 2.0 : 0.01, precisionDigits);
   }
   grid.originalGridStep = grid.GridStep;
   
   if(GridLevels <= 0)
   {
      Log("错误：GridLevels 必须大于 0，当前值=" + IntegerToString(GridLevels));
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(ArrayResize(grid.upperGrid, GridLevels) < 0 || ArrayResize(grid.lowerGrid, GridLevels) < 0)
   {
      Log("错误：网格数组调整大小失败");
      return(INIT_FAILED);
   }
   
   for(int i = 0; i < GridLevels; i++)
   {
      grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * grid.GridStep, precisionDigits);
      grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * grid.GridStep, precisionDigits);
   }
   grid.upperBound = grid.upperGrid[GridLevels - 1];
   grid.lowerBound = grid.lowerGrid[GridLevels - 1];
   Log("网格初始化完成，上边界=" + DoubleToString(grid.upperBound) + "，下边界=" + DoubleToString(grid.lowerBound));
   
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   Log("Mayfly 3.2.16 初始化完成，镜像模式=" + (EnableMirror ? "开启" : "关闭"));
   
   SetupGridOrders();
   DrawBasePriceLine();
   lastDealTicket = GetLastDealTicket();
   lastBidPrice = currentPrice;
   lastGridUpdateTime = TimeCurrent();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(!GlobalVariableCheck(CLEANUP_DONE) || GlobalVariableGet(CLEANUP_DONE) != 1)
      CleanupOrders();
   ObjectDelete(0, "BasePriceLine");
   Log("Mayfly 3.2.16 停止运行，原因代码=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(isFirstTick)
   {
      CachePositionGridPrices();
      isFirstTick = false;
   }

   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   int currentHour = timeStruct.hour;

   if(currentHour >= EndHour && !hasCleanedUpAfterEnd)
   {
      Log("超过交易结束时间 (" + IntegerToString(EndHour) + "点)，平仓并取消挂单！");
      CloseAllPositions();
      CleanupOrders();
      hasCleanedUpAfterEnd = true;
      return;
   }

   if(currentHour >= StartHour && currentHour < EndHour)
      hasCleanedUpAfterEnd = false;
   else
      return;

   int totalOrders = OrdersTotal();
   int totalPositions = PositionsTotal();

   CachePositionGridPrices();

   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 修改后的止损检测：检查当前品种最近一小时的最后止损/止盈成交
   stopEventDetected = false;
   if(HistorySelect(TimeCurrent() - 3600, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket > 0 && 
            HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MAGIC_NUMBER && 
            HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol) // 确保品种匹配
         {
            ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
            if(reason == DEAL_REASON_SL || reason == DEAL_REASON_TP)
            {
               stopEventDetected = true;
               lastStopLossPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
               lastStopLossType = (HistoryDealGetInteger(dealTicket, DEAL_TYPE) == DEAL_TYPE_BUY) 
                                  ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               Log("检测到当前品种最后止损/止盈：dealTicket=" + IntegerToString(dealTicket) + 
                   ", price=" + DoubleToString(lastStopLossPrice) + 
                   ", type=" + EnumToString(lastStopLossType) + 
                   ", symbol=" + _Symbol);
               break; // 找到后退出循环
            }
         }
      }
   }

   // 网格移动逻辑
   if(MathAbs(bidPrice - lastBidPrice) >= grid.GridStep)
   {
      int shift = 0;
      if(bidPrice >= grid.basePrice + grid.GridStep)
         shift = (int)MathFloor((bidPrice - grid.basePrice) / grid.GridStep);
      else if(bidPrice <= grid.basePrice - grid.GridStep)
         shift = (int)MathCeil((bidPrice - grid.basePrice) / grid.GridStep);

      if(shift != 0)
      {
         grid.basePrice = NormalizeDouble(grid.basePrice + shift * grid.GridStep, precisionDigits);
         Log("常规网格移动：shift=" + IntegerToString(shift) + ", 新 basePrice=" + DoubleToString(grid.basePrice));
         for(int i = 0; i < GridLevels; i++)
         {
            grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * grid.GridStep, precisionDigits);
            grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * grid.GridStep, precisionDigits);
         }
         grid.upperBound = grid.upperGrid[GridLevels - 1];
         grid.lowerBound = grid.lowerGrid[GridLevels - 1];
         AdjustGridOrders();
         DrawBasePriceLine();
      }
      lastBidPrice = bidPrice;
   }

   // 止损后强制调整基准价格
   if(stopEventDetected && lastStopLossPrice != 0)
   {
      double nearestGridPrice = grid.basePrice + MathRound((lastStopLossPrice - grid.basePrice) / grid.GridStep) * grid.GridStep;
      double tolerance = SlippageTolerance * grid.GridStep;
      if(MathAbs(lastStopLossPrice - nearestGridPrice) <= tolerance)
      {
         grid.basePrice = NormalizeDouble(nearestGridPrice, precisionDigits);
         Log("止损后强制调整：lastStopLossPrice=" + DoubleToString(lastStopLossPrice) + 
             ", nearestGridPrice=" + DoubleToString(nearestGridPrice) + 
             ", 新 basePrice=" + DoubleToString(grid.basePrice));
         for(int i = 0; i < GridLevels; i++)
         {
            grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * grid.GridStep, precisionDigits);
            grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * grid.GridStep, precisionDigits);
         }
         grid.upperBound = grid.upperGrid[GridLevels - 1];
         grid.lowerBound = grid.lowerGrid[GridLevels - 1];
         AdjustGridOrders();
         DrawBasePriceLine();
      }
   }

   // 时区调整逻辑
   datetime currentTimeSec = TimeCurrent();
   if(currentTimeSec - lastGridUpdateTime >= 60)
   {
      bool isActiveZone = (currentHour >= ActiveZoneStartHour && currentHour < ActiveZoneEndHour);
      if(isActiveZone != lastActiveZoneState)
      {
         if(isActiveZone)
            grid.GridStep = grid.originalGridStep * 2.0;
         else
            grid.GridStep = grid.originalGridStep;

         ArrayResize(grid.upperGrid, GridLevels);
         ArrayResize(grid.lowerGrid, GridLevels);
         for(int i = 0; i < GridLevels; i++)
         {
            grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * grid.GridStep, precisionDigits);
            grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * grid.GridStep, precisionDigits);
         }
         grid.upperBound = grid.upperGrid[GridLevels - 1];
         grid.lowerBound = grid.lowerGrid[GridLevels - 1];
         CleanupOrders();
         lastActiveZoneState = isActiveZone;
      }

      if(EnableDynamicGrid && GridSpacing <= 0)
      {
         double newAtrValue = GetATRValue(_Symbol, _Period, ATR_Period);
         if(newAtrValue > 0)
         {
            double newGridStep = NormalizeDouble(newAtrValue * 2.0, precisionDigits);
            if(newGridStep != grid.originalGridStep)
            {
               grid.originalGridStep = newGridStep;
               grid.GridStep = isActiveZone ? grid.originalGridStep * 2.0 : grid.originalGridStep;
               ArrayResize(grid.upperGrid, GridLevels);
               ArrayResize(grid.lowerGrid, GridLevels);
               for(int i = 0; i < GridLevels; i++)
               {
                  grid.upperGrid[i] = NormalizeDouble(grid.basePrice + (i + 1) * grid.GridStep, precisionDigits);
                  grid.lowerGrid[i] = NormalizeDouble(grid.basePrice - (i + 1) * grid.GridStep, precisionDigits);
               }
               grid.upperBound = grid.upperGrid[GridLevels - 1];
               grid.lowerBound = grid.lowerGrid[GridLevels - 1];
               CleanupOrders();
            }
         }
      }
      lastGridUpdateTime = currentTimeSec;
   }

   // 新成交时及时更新止损
   ulong currentDealTicket = GetLastDealTicket();
   if(currentDealTicket > lastDealTicket && totalPositions > 0)
   {
      UpdateStopLosses();
      stopLossesUpdated = true;
      lastDealTicket = currentDealTicket;
   }

   CheckAbnormalStopLoss();
   PlaceGridOrders(totalPositions);

   if(totalPositions > 0 && totalOrders > 0)
      CancelOrdersMatchingStopLoss();
}

//+------------------------------------------------------------------+
//| 统一挂单逻辑                                                      |
//+------------------------------------------------------------------+
void PlaceGridOrders(int totalPositions)
{
   Log("进入 PlaceGridOrders，totalPositions=" + IntegerToString(totalPositions) + 
       ", GridLevels=" + IntegerToString(GridLevels));
   if(totalPositions >= GridLevels)
   {
      Log("持仓数量已达上限，暂停挂单");
      return;
   }

   bool allowBuy = !stopEventDetected || lastStopLossType != POSITION_TYPE_SELL;
   bool allowSell = !stopEventDetected || lastStopLossType != POSITION_TYPE_BUY;
   Log("挂单权限：allowBuy=" + (allowBuy ? "true" : "false") + 
       ", allowSell=" + (allowSell ? "true" : "false") + 
       ", stopEventDetected=" + (stopEventDetected ? "true" : "false") + 
       ", lastStopLossType=" + EnumToString(lastStopLossType));

   double totalLots = 0.0;
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
      {
         Log("警告：无法选择持仓计算手数，索引=" + IntegerToString(i));
         continue;
      }

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(symbol == _Symbol && magic == MAGIC_NUMBER)
      {
         double volume = PositionGetDouble(POSITION_VOLUME);
         totalLots += volume;
         Log("持仓 " + IntegerToString(i) + " 手数=" + DoubleToString(volume) + 
             ", 当前 totalLots=" + DoubleToString(totalLots));
      }
   }
   Log("总手数计算完成：totalLots=" + DoubleToString(totalLots) + 
       ", MaxTotalLots=" + DoubleToString(MaxTotalLots));

   int addCount = 0;
   for(int i = 0; i < GridLevels; i++)
   {
      Log("网格层级 " + IntegerToString(i) + " 检查开始，addCount=" + IntegerToString(addCount) + 
          ", AddPositionTimes=" + IntegerToString(AddPositionTimes));
      if(addCount >= AddPositionTimes)
      {
         Log("加仓次数已达上限，暂停挂单");
         break;
      }

      double buyPrice = grid.upperGrid[i];
      double sellPrice = grid.lowerGrid[i];
      double lotSizeBuy = CalculateLotSize(grid.GridStep, buyPrice);
      double lotSizeSell = CalculateLotSize(grid.GridStep, sellPrice);
      Log("网格价格：buyPrice=" + DoubleToString(buyPrice) + 
          ", sellPrice=" + DoubleToString(sellPrice) + 
          ", lotSizeBuy=" + DoubleToString(lotSizeBuy) + 
          ", lotSizeSell=" + DoubleToString(lotSizeSell));

      bool buyPriceHasOrder = OrderExists(buyPrice);
      bool buyPriceHasPosition = PositionExists(buyPrice);
      bool sellPriceHasOrder = OrderExists(sellPrice);
      bool sellPriceHasPosition = PositionExists(sellPrice);
      Log("网格状态：buyPriceHasOrder=" + (buyPriceHasOrder ? "true" : "false") + 
          ", buyPriceHasPosition=" + (buyPriceHasPosition ? "true" : "false") + 
          ", sellPriceHasOrder=" + (sellPriceHasOrder ? "true" : "false") + 
          ", sellPriceHasPosition=" + (sellPriceHasPosition ? "true" : "false"));

      bool buyPriceConflictsWithStopLoss = IsPriceInStopLossList(buyPrice);
      bool sellPriceConflictsWithStopLoss = IsPriceInStopLossList(sellPrice);
      bool buyPriceAtStopLoss = IsPriceAtStopLoss(buyPrice);
      bool sellPriceAtStopLoss = IsPriceAtStopLoss(sellPrice);
      Log("止损检查：buyPriceConflictsWithStopLoss=" + (buyPriceConflictsWithStopLoss ? "true" : "false") + 
          ", sellPriceConflictsWithStopLoss=" + (sellPriceConflictsWithStopLoss ? "true" : "false") + 
          ", buyPriceAtStopLoss=" + (buyPriceAtStopLoss ? "true" : "false") + 
          ", sellPriceAtStopLoss=" + (sellPriceAtStopLoss ? "true" : "false") + 
          ", lastBuyStopLoss=" + DoubleToString(lastBuyStopLoss) + 
          ", lastSellStopLoss=" + DoubleToString(lastSellStopLoss));

      double currentBuyLotSize = 0.0;
      double currentSellLotSize = 0.0;
      if(AddPositionMode == ADD_MODE_UNIFORM)
      {
         if(totalLots + lotSizeBuy <= MaxTotalLots)
         {
            currentBuyLotSize = lotSizeBuy;
            currentSellLotSize = lotSizeSell;
         }
      }
      else if(AddPositionMode == ADD_MODE_PYRAMID)
      {
         double firstLotSize = lotSizeBuy;
         double minLotSize = 0.01;
         double decrement = (AddPositionTimes > 1) ? (firstLotSize - minLotSize) / (AddPositionTimes - 1) : 0;
         double currentLotSize = firstLotSize - (decrement * addCount);
         if(currentLotSize < minLotSize)
            currentLotSize = minLotSize;

         if(totalLots + currentLotSize <= MaxTotalLots)
         {
            currentBuyLotSize = currentLotSize;
            currentSellLotSize = currentLotSize;
         }
      }
      else if(AddPositionMode == ADD_MODE_INV_PYRAMID)
      {
         int currentAddIndex = addCount + 1;
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
      Log("手数计算：currentBuyLotSize=" + DoubleToString(currentBuyLotSize) + 
          ", currentSellLotSize=" + DoubleToString(currentSellLotSize));

      if(EnableMirror)
      {
         if(currentSellLotSize > 0 && allowBuy && !sellPriceHasOrder && !sellPriceHasPosition && 
            !sellPriceConflictsWithStopLoss && !sellPriceAtStopLoss)
         {
            double buyLimitTpPrice = NormalizeDouble(sellPrice + grid.GridStep, precisionDigits);
            Log("挂单：Buy Limit @ " + DoubleToString(sellPrice) + ", TP=" + DoubleToString(buyLimitTpPrice) + 
                ", 手数=" + DoubleToString(currentSellLotSize));
            trade.BuyLimit(currentSellLotSize, sellPrice, _Symbol, 0, buyLimitTpPrice, ORDER_TIME_GTC, 0, "Buy Limit Grid");
            totalLots += currentSellLotSize;
            addCount++;
         }
         else
         {
            Log("未挂 Buy Limit @ " + DoubleToString(sellPrice) + "，条件未满足");
         }

         if(currentBuyLotSize > 0 && allowSell && !buyPriceHasOrder && !buyPriceHasPosition && 
            !buyPriceConflictsWithStopLoss && !buyPriceAtStopLoss)
         {
            double sellLimitTpPrice = NormalizeDouble(buyPrice - grid.GridStep, precisionDigits);
            Log("挂单：Sell Limit @ " + DoubleToString(buyPrice) + ", TP=" + DoubleToString(sellLimitTpPrice) + 
                ", 手数=" + DoubleToString(currentBuyLotSize));
            trade.SellLimit(currentBuyLotSize, buyPrice, _Symbol, 0, sellLimitTpPrice, ORDER_TIME_GTC, 0, "Sell Limit Grid");
            totalLots += currentBuyLotSize;
            addCount++;
         }
         else
         {
            Log("未挂 Sell Limit @ " + DoubleToString(buyPrice) + "，条件未满足");
         }
      }
      else
      {
         if(currentBuyLotSize > 0 && allowBuy && !buyPriceHasOrder && !buyPriceHasPosition && 
            !buyPriceConflictsWithStopLoss && !buyPriceAtStopLoss)
         {
            double buySlPrice = NormalizeDouble(buyPrice - grid.GridStep, precisionDigits);
            Log("挂单：Buy Stop @ " + DoubleToString(buyPrice) + ", SL=" + DoubleToString(buySlPrice) + 
                ", 手数=" + DoubleToString(currentBuyLotSize));
            trade.BuyStop(currentBuyLotSize, buyPrice, _Symbol, buySlPrice, 0, ORDER_TIME_GTC, 0, "Buy Stop Grid");
            totalLots += currentBuyLotSize;
            addCount++;
         }
         else
         {
            Log("未挂 Buy Stop @ " + DoubleToString(buyPrice) + "，条件未满足：" + 
                "currentBuyLotSize=" + DoubleToString(currentBuyLotSize) + " (需 > 0), " + 
                "allowBuy=" + (allowBuy ? "true" : "false") + ", " + 
                "buyPriceHasOrder=" + (buyPriceHasOrder ? "true" : "false") + ", " + 
                "buyPriceHasPosition=" + (buyPriceHasPosition ? "true" : "false") + ", " + 
                "buyPriceConflictsWithStopLoss=" + (buyPriceConflictsWithStopLoss ? "true" : "false") + ", " + 
                "buyPriceAtStopLoss=" + (buyPriceAtStopLoss ? "true" : "false"));
         }

         if(currentSellLotSize > 0 && allowSell && !sellPriceHasOrder && !sellPriceHasPosition && 
            !sellPriceConflictsWithStopLoss && !sellPriceAtStopLoss)
         {
            double sellSlPrice = NormalizeDouble(sellPrice + grid.GridStep, precisionDigits);
            Log("挂单：Sell Stop @ " + DoubleToString(sellPrice) + ", SL=" + DoubleToString(sellSlPrice) + 
                ", 手数=" + DoubleToString(currentSellLotSize));
            trade.SellStop(currentSellLotSize, sellPrice, _Symbol, sellSlPrice, 0, ORDER_TIME_GTC, 0, "Sell Stop Grid");
            totalLots += currentSellLotSize;
            addCount++;
         }
         else
         {
            Log("未挂 Sell Stop @ " + DoubleToString(sellPrice) + "，条件未满足：" + 
                "currentSellLotSize=" + DoubleToString(currentSellLotSize) + " (需 > 0), " + 
                "allowSell=" + (allowSell ? "true" : "false") + ", " + 
                "sellPriceHasOrder=" + (sellPriceHasOrder ? "true" : "false") + ", " + 
                "sellPriceHasPosition=" + (sellPriceHasPosition ? "true" : "false") + ", " + 
                "sellPriceConflictsWithStopLoss=" + (sellPriceConflictsWithStopLoss ? "true" : "false") + ", " + 
                "sellPriceAtStopLoss=" + (sellPriceAtStopLoss ? "true" : "false"));
         }
      }

      if(totalLots >= MaxTotalLots)
      {
         Log("总手数达到上限，暂停挂单，totalLots=" + DoubleToString(totalLots));
         break;
      }
   }
   Log("PlaceGridOrders 结束，addCount=" + IntegerToString(addCount) + ", totalLots=" + DoubleToString(totalLots));
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
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            if(!trade.PositionClose(ticket))
               Log("平仓失败，票号=" + IntegerToString(ticket) + "，错误代码=" + IntegerToString(GetLastError()));
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
            trade.OrderDelete(ticket);
      }
   }
   GlobalVariableSet(CLEANUP_DONE, 1);
   GlobalVariableSet(EXIT_SIGNAL, 0);
   Log("清理完成！");
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
         return dealTicket;
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

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            if(orderPrice > grid.upperBound || orderPrice < grid.lowerBound)
               trade.OrderDelete(ticket);
         }
      }
   }

   PlaceGridOrders(totalPositions);
}

//+------------------------------------------------------------------+
//| 更新所有持仓止损（原有逻辑，镜像时改为止盈）                     |
//+------------------------------------------------------------------+
void UpdateStopLosses()
{
   int totalPositions = PositionsTotal();
   if(totalPositions == 0) return;

   double newBuyStopLoss = 0;
   double newSellStopLoss = 0;
   datetime latestTime = 0;

   for(int i = totalPositions - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if(openTime > latestTime)
            {
               latestTime = openTime;
               if(EnableMirror)
               {
                  double tpPrice = PositionGetDouble(POSITION_TP);
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                     newBuyStopLoss = tpPrice;
                  else
                     newSellStopLoss = tpPrice;
                  lastStopLossPrice = tpPrice;
               }
               else
               {
                  double slPrice = PositionGetDouble(POSITION_SL);
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                     newBuyStopLoss = slPrice;
                  else
                     newSellStopLoss = slPrice;
                  lastStopLossPrice = slPrice;
               }
            }
         }
      }
   }

   if((newBuyStopLoss > 0 && newBuyStopLoss != lastBuyStopLoss) || (newSellStopLoss > 0 && newSellStopLoss != lastSellStopLoss))
   {
      for(int i = totalPositions - 1; i >= 0; i--)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
            {
               if(EnableMirror)
               {
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newBuyStopLoss > 0)
                  {
                     double newTpPrice = NormalizeDouble(newBuyStopLoss, precisionDigits);
                     if(newTpPrice != PositionGetDouble(POSITION_TP))
                        trade.PositionModify(PositionGetTicket(i), 0, newTpPrice);
                  }
                  else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && newSellStopLoss > 0)
                  {
                     double newTpPrice = NormalizeDouble(newSellStopLoss, precisionDigits);
                     if(newTpPrice != PositionGetDouble(POSITION_TP))
                        trade.PositionModify(PositionGetTicket(i), 0, newTpPrice);
                  }
               }
               else
               {
                  if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newBuyStopLoss > 0)
                  {
                     double newSlPrice = NormalizeDouble(newBuyStopLoss, precisionDigits);
                     if(newSlPrice != PositionGetDouble(POSITION_SL))
                        trade.PositionModify(PositionGetTicket(i), newSlPrice, 0);
                  }
                  else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && newSellStopLoss > 0)
                  {
                     double newSlPrice = NormalizeDouble(newSellStopLoss, precisionDigits);
                     if(newSlPrice != PositionGetDouble(POSITION_SL))
                        trade.PositionModify(PositionGetTicket(i), newSlPrice, 0);
                  }
               }
            }
         }
      }
      lastBuyStopLoss = newBuyStopLoss;
      lastSellStopLoss = newSellStopLoss;
   }
}

//+------------------------------------------------------------------+
//| 取消与持仓止损/止盈重合的挂单并记录类型                          |
//+------------------------------------------------------------------+
void CancelOrdersMatchingStopLoss()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         if(orderSymbol == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC_NUMBER)
         {
            if(IsPriceAtStopLoss(orderPrice))
            {
               ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
               if((EnableMirror && (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)) ||
                  (!EnableMirror && (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)))
               {
                  stopEventDetected = true;
                  lastStopLossType = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_LIMIT) 
                                     ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
                  lastStopLossPrice = orderPrice;
                  Log("检测到" + (EnableMirror ? "止盈" : "止损") + "，类型=" + EnumToString(lastStopLossType));
                  trade.OrderDelete(ticket);
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
            return true;
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
   double tolerance = grid.GridStep * SlippageTolerance;
   double lowerBound = normalizedGridPrice - tolerance;
   double upperBound = normalizedGridPrice + tolerance;

   for(int i = 0; i < ArraySize(positionsInfo); i++)
   {
      double cachedGridPrice = NormalizeDouble(positionsInfo[i].gridPrice, precisionDigits);
      if(cachedGridPrice == normalizedGridPrice)
      {
         if(EnableLogging)
            Log("网格价位 " + DoubleToString(gridPrice) + " 已存在持仓（缓存匹配）");
         return true;
      }
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER)
         {
            double positionPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            if(positionPrice >= lowerBound && positionPrice < upperBound)
            {
               if(EnableLogging)
                  Log("网格价位 " + DoubleToString(gridPrice) + " 已存在持仓，持仓价=" + DoubleToString(positionPrice));
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
      return NormalizeDouble(LotSize, 2);

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(accountBalance <= 0)
   {
      Log("错误：账户余额为 0，无法计算手数");
      return 0;
   }

   double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   if(leverage <= 0) leverage = 100;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginPerLot = (cachedContractSize * price) / leverage;

   double lotSize = 0.0;

   if(TradeMode == TRADE_MODE_PERCENT)
   {
      double maxAvailableCapital = accountBalance * (PositionPercent / 100.0) * leverage;
      lotSize = maxAvailableCapital / marginPerLot;
   }
   else if(TradeMode == TRADE_MODE_STOPLOSS_PERCENT)
   {
      double maxLossAmount = accountBalance * (StopLossPercent / 100.0);
      if(cachedTickSize == 0)
      {
         Log("错误：tickSize 为 0，无法计算手数");
         return 0;
      }

      double points = stopLossDistance / cachedTickSize;
      double lossPerLot = points * cachedTickValue;
      if(lossPerLot <= 0)
      {
         Log("错误：lossPerLot <= 0");
         return 0;
      }

      lotSize = maxLossAmount / lossPerLot;
   }

   double maxLotByMargin = freeMargin / marginPerLot;
   lotSize = MathMin(lotSize, maxLotByMargin);
   lotSize = MathMax(cachedMinLot, MathMin(cachedMaxLot, lotSize));
   lotSize = MathRound(lotSize / cachedLotStep) * cachedLotStep;
   lotSize = NormalizeDouble(lotSize, 2);

   if(lotSize <= 0 || lotSize * marginPerLot > freeMargin)
   {
      Log("错误：手数 " + DoubleToString(lotSize) + " 超过可用保证金");
      return 0;
   }

   double finalLotSize = (TradeMode == TRADE_MODE_STOPLOSS_PERCENT && IsMiniLot) ? lotSize * 10.0 : lotSize;
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
//+------------------------------------------------------------------+
