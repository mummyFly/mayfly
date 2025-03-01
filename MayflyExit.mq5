//+------------------------------------------------------------------+
//| Script: SetExitSignal.mq5                                        |
//| Description: Sets the exit signal for a specific Mayfly 2.0 EA instance |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property link      "https://xai.com"
#property version   "1.0"

//+------------------------------------------------------------------+
//| Script start function                                            |
//+------------------------------------------------------------------+
void OnStart()
{
   // 获取当前图表的交易品种、周期和 ChartID
   string symbol = Symbol();
   ENUM_TIMEFRAMES timeframe = Period();
   long chartId = ChartID();
   
   // 动态拼接退出信号名称，与 EA 中的 EXIT_SIGNAL 一致
   string exitSignal = "Mayfly2.0_" + symbol + "_" + EnumToString(timeframe) + "_Exit_" + IntegerToString(chartId);
   
   // 设置退出信号
   GlobalVariableSet(exitSignal, 1);
   Print("已设置退出信号: ", exitSignal, " = 1");
}
//+------------------------------------------------------------------+
