// 额度窗口的 hover 明细视图族（QuotaWindowsHoverView / QuotaUsageWindowsHoverView /
// QuotaUsageWindowColumn / SingleQuotaWindowHoverView / HoverMetricLine /
// QuotaWindowsHoverPresentation）已随 menuLayout 死分支一起删除——它们唯一
// 的构造路径是被删的 QuotaCombinedUsageRow / QuotaSingleUsageRow。
//
// `UsageMetricHoverSummaryView`（prompts/rounds/input/cached/output/reason 的
// 逐行指标摘要）也已删除：它唯一的生产宿主是 `OffPeakUsageFootnote`（GLM 闲时
// 脚注），脚注并入「额度窗口」表格的「闲」行后视图失去渲染方，随之删除。
// 拆行规则的量宽测试（QuotaViewsCopyTests）一并移除。
