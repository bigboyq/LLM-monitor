import SwiftUI

/// 菜单栏面板与悬浮层统一排版系统。业务视图使用语义角色，禁止散落硬编码字号。
enum MenuTypography {
    /// 顶部主标题 (LLM Monitor)
    static let headerTitle = Font.system(size: 13, weight: .semibold)
    /// 卡片主标题 (Provider 名称)
    static let cardTitle = Font.system(size: 13, weight: .bold)
    /// 状态标签与微型 Pill (未启用 / 待更新 / Team / AI Pro)
    static let badge = Font.system(size: 9, weight: .semibold).monospacedDigit()
    static let pill = Font.system(size: 9, weight: .semibold)
    /// 模型名称 (Gemini 2.5 Flash 等)
    static let modelTitle = Font.system(size: 11, weight: .semibold)
    /// 周倍率与辅助标记
    static let multiplier = Font.system(size: 10, weight: .medium).monospacedDigit()
    /// 数据行标签 (5h, 周)
    static let dataLabel = Font.system(size: 10, weight: .semibold)
    /// 数据行百分比与数值
    static let dataValue = Font.system(size: 10, weight: .semibold).monospacedDigit()
    /// 重置时间主体
    static let resetDate = Font.system(size: 10, weight: .semibold).monospacedDigit()
    /// 紧凑剩余时间后缀 (如 (3h20m))
    static let timeSuffix = Font.system(size: 9, weight: .medium).monospacedDigit()
    /// 底部 Footer 状态文本与操作按钮
    static let footer = Font.system(size: 9, weight: .medium)
    static let footerNumber = Font.system(size: 9, weight: .medium).monospacedDigit()
    /// 今日指标与小徽标
    static let metricLabel = Font.system(size: 10, weight: .medium)
    static let metricValue = Font.system(size: 10, weight: .medium).monospacedDigit()
    /// 错误与警示消息
    static let errorMessage = Font.system(size: 11, weight: .medium)
    /// 占位文本与空提示
    static let hint = Font.system(size: 10)
    static let caption = Font.system(size: 11)

    // MARK: - 悬浮面板 (Hover Panel) 排版角色
    /// 悬浮面板标题
    static let hoverTitle = Font.system(size: 12, weight: .semibold)
    /// 悬浮面板正文重点
    static let hoverRowEmphasis = Font.system(size: 11, weight: .semibold)
    /// 悬浮面板正文/数值
    static let hoverBody = Font.system(size: 11, weight: .medium)
    static let hoverBodyMonospaced = Font.system(size: 11, weight: .medium).monospacedDigit()
    /// 悬浮面板辅助说明 (最低 10pt，严禁低于 HIG 规范)
    static let hoverCaption = Font.system(size: 10, weight: .regular)
    static let hoverCaptionEmphasis = Font.system(size: 10, weight: .medium)
    /// 悬浮面板微型注释与来源脚注
    static let hoverFootnote = Font.system(size: 9, weight: .regular)
}
