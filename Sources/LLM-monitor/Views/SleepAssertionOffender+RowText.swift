import Foundation
import SwiftUI

/// 「阻止休眠的第三方应用」行的展示文案：设置页节能 Tab 检查项一与
/// 主面板 header 悬浮清单共用，避免两处格式漂移。
extension SleepAssertionOffender {
    /// 断言类型的中文展示名，未知类型原样展示。
    var assertionDisplayName: String {
        switch assertionType {
        case "PreventUserIdleSystemSleep": return "阻止空闲休眠"
        case "NoIdleSleepAssertion": return "阻止空闲休眠（NoIdleSleep）"
        case "PreventSystemSleep": return "阻止系统休眠"
        default: return assertionType
        }
    }

    /// 单行文案：进程名 · PID · 断言类型 · 已持续时长。
    /// 时长优先按断言创建时间实时推算，缺失时回退扫描快照的已持有时长。
    func rowText(now: Date = Date()) -> String {
        let duration = creationDate.map { max(0, now.timeIntervalSince($0)) } ?? heldSeconds
        return "\(processName) · PID \(pid) · \(assertionDisplayName) · 已持续 \(Self.formatHeldDuration(duration))"
    }

    /// 时长展示：超过 1 小时为 h:mm:ss，否则 mm:ss。
    static func formatHeldDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 主面板 header「N 个应用正在阻止休眠」的悬浮清单，橙色行文案与
/// 设置页节能 Tab 检查项一完全一致。
struct SleepOffendersHoverView: View {
    let offenders: [SleepAssertionOffender]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正在阻止休眠的第三方应用")
                .font(MenuTypography.hoverRowEmphasis)
            ForEach(offenders) { offender in
                Text(offender.rowText())
                    .font(MenuTypography.hoverCaption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("完整诊断见 设置 → 节能")
                .font(MenuTypography.hoverFootnote)
                .foregroundStyle(.secondary)
        }
    }
}
