import SwiftUI
import AppKit

/// SettingsView 的「节能」tab：系统睡眠健康度状态卡 + 防止休眠开关 +
/// 只读电源参数矩阵。从 SettingsView.swift 拆出（对照 SettingsClientsPane
/// 的拆分模式）。
///
/// 数据只读消费 `AppState.sleepHealth`（SleepHealthService，公共 API 契约见
/// Models/SleepHealthModels.swift 的 SleepHealthReporting）：本 pane 不产生
/// 任何配置修改，不触碰 bottomActionBar 的取消/保存逻辑。
extension SettingsView {
    var energyPane: some View {
        // 独立子视图直接观察 SleepHealthService 的 @Published；SettingsView
        // 只观察 AppState，不感知 report / isKeepAwakeOn 的变化。
        EnergyPaneContent(
            service: state.sleepHealth,
            healthColors: state.configStore.config.effectiveStatusBarHealthColors
        )
        .onAppear {
            // 打开页面立即刷新；后台还会由 AppState 复用 provider deadline
            // driver 周期性刷新，避免健康灯长期停留在旧快照。
            state.sleepHealth.refreshNow()
        }
    }
}

/// 「节能」pane 的实际内容。internal：`SettingsView.energyPane` 需要把它作为
/// 返回类型暴露出去。
struct EnergyPaneContent: View {
    @ObservedObject var service: SleepHealthService
    /// 菜单栏同款三色配色实例（configStore.config.effectiveStatusBarHealthColors）。
    let healthColors: StatusBarHealthColors

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusSection
            keepAwakeSection
            powerConfigSection
        }
    }

    // MARK: - 状态卡片

    private var statusSection: some View {
        SettingsSection(title: "当前状态") {
            if let report = service.report {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Color(nsColor: dotColor(for: report.status.healthLevel)))
                        .frame(width: 14, height: 14)
                    Text(statusHeadline(for: report))
                        .font(SettingsTypography.rowEmphasis)
                        .fixedSize(horizontal: false, vertical: true)
                }

                statusDetail(for: report)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取系统电源状态…")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func statusDetail(for report: SleepHealthReport) -> some View {
        switch report.status {
        case .healthy:
            EmptyView()

        case .blockedByAssertions, .acSleepDisabled:
            let hasOffenders = !report.offenders.isEmpty
            let isAcZero = report.acSleepMinutes == 0

            VStack(alignment: .leading, spacing: 8) {
                if hasOffenders {
                    if isAcZero {
                        Text("1. 阻止休眠的第三方应用：")
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.offenders) { offender in
                            Text(offenderRowText(offender))
                                .font(SettingsTypography.metadata)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if isAcZero {
                    if hasOffenders {
                        Text("2. AC 自动休眠配置：")
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Text("修复方式：系统设置 → 电池 → 选项…，关闭“当显示器关闭时，在电源适配器上防止自动睡眠”；或在终端执行 sudo pmset -c sleep 15。")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .keepAwake:
            // 红色态：一键关闭 + 检查项 1/2 明细区结构照常展示（判定顺序上红色
            // 优先短路，但明细反映真实数据，不按胜出状态反推）。
            // 本 App 自身的防休眠断言已被服务层从扫描结果里排除。
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("关闭防止睡眠") {
                        service.setKeepAwake(false)
                    }
                    .controlSize(.small)
                    Spacer()
                }

                if report.offenders.isEmpty {
                    Text("检查项一 · 第三方睡眠锁：未发现霸占睡眠锁的第三方进程。")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("检查项一 · 第三方睡眠锁：以下应用正在阻止休眠：")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.offenders) { offender in
                        Text(offenderRowText(offender))
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("检查项二 · AC 自动休眠：\(acSleepCheckText(for: report))")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dotColor(for level: HealthLevel) -> NSColor {
        healthColors.color(for: level) ?? .systemGray
    }

    private func statusHeadline(for report: SleepHealthReport) -> String {
        switch report.status {
        case .healthy:
            return "系统休眠机制正常，可按设定时间自动进入睡眠。"
        case .blockedByAssertions, .acSleepDisabled:
            if !report.offenders.isEmpty && report.acSleepMinutes == 0 {
                return "系统休眠受阻，检测到多项异常："
            }
            if !report.offenders.isEmpty {
                return "以下应用正在阻止休眠，建议退出或保存状态："
            }
            return "AC 供电下自动休眠已关闭。"
        case .keepAwake:
            return "当前已手动开启【防止睡眠】模式，电脑将持续保持唤醒。"
        }
    }

    private func offenderRowText(_ offender: SleepAssertionOffender) -> String {
        let duration = offender.creationDate.map { max(0, Date().timeIntervalSince($0)) } ?? offender.heldSeconds
        return "\(offender.processName) · PID \(offender.pid) · \(assertionDisplayName(offender.assertionType)) · 已持续 \(formatHeldDuration(duration))"
    }

    private func assertionDisplayName(_ type: String) -> String {
        switch type {
        case "PreventUserIdleSystemSleep": return "阻止空闲休眠"
        case "NoIdleSleepAssertion": return "阻止空闲休眠（NoIdleSleep）"
        case "PreventSystemSleep": return "阻止系统休眠"
        default: return type
        }
    }

    /// 断言已持续时长：不足 1 小时用 mm:ss，超过用 h:mm:ss。
    private func formatHeldDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func acSleepCheckText(for report: SleepHealthReport) -> String {
        guard let minutes = report.acSleepMinutes else { return "未能读取。" }
        if minutes == 0 { return "已关闭。" }
        return "正常（\(minutes) 分钟无操作后休眠）。"
    }

    // MARK: - 防止休眠开关

    private var keepAwakeSection: some View {
        SettingsSection(
            title: "防止休眠",
            footer: "内存开关：仅本次运行有效，重启应用后自动关闭。"
        ) {
            SettingsToggleRow(
                label: "防止电脑休眠（临时）",
                isOn: Binding(
                    get: { service.isKeepAwakeOn },
                    set: { service.setKeepAwake($0) }
                )
            )
        }
    }

    // MARK: - 电源参数矩阵（只读）

    private var powerConfigSection: some View {
        SettingsSection(
            title: "电源参数",
            footer: "只读展示 `pmset -g custom` 的当前取值；本页不会修改任何系统设置。"
        ) {
            if let report = service.report {
                if let powerConfig = report.powerConfig {
                    VStack(alignment: .leading, spacing: 12) {
                        matrixHeader
                        Divider()
                            .opacity(0.4)
                        ForEach(matrixRows(ac: powerConfig.ac, battery: powerConfig.battery)) { row in
                            matrixRow(row)
                        }
                    }
                    .frame(maxWidth: 540, alignment: .leading)
                } else {
                    Text("本次未能读取电源参数（pmset -g custom）。")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("正在读取系统电源状态…")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var matrixHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("参数")
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
            Spacer()
            Text("电源适配器")
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text("电池")
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private func matrixRow(_ row: PowerMatrixRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.name)
                    .font(SettingsTypography.rowEmphasis)
                Spacer()
                Group {
                    // 列标签已在表头（电源适配器 / 电池），行内只放数值避免重复
                    Text(matrixValueText(row.acValue, isMinutes: row.isMinutes))
                        .frame(width: 96, alignment: .trailing)
                    Text(matrixValueText(row.batteryValue, isMinutes: row.isMinutes))
                        .frame(width: 76, alignment: .trailing)
                }
                .font(SettingsTypography.numericValue)
                .foregroundStyle(.secondary)
            }

            Text(row.guide)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 分钟语义的参数带单位展示；womp / tcpkeepalive / powernap 是开关位，展示原始 0/1。
    private func matrixValueText(_ value: Int?, isMinutes: Bool) -> String {
        guard let value else { return "—" }
        return isMinutes ? "\(value) 分" : "\(value)"
    }

    private func matrixRows(
        ac: PowerProfileSettings,
        battery: PowerProfileSettings?
    ) -> [PowerMatrixRow] {
        [
            PowerMatrixRow(
                name: "sleep · 系统空闲休眠",
                guide: "无操作多少分钟后休眠，0 为从不。系统设置 → 电池 → 选项…；命令：sudo pmset -c sleep 15 / sudo pmset -b sleep 10",
                acValue: ac.sleepMinutes,
                batteryValue: battery?.sleepMinutes,
                isMinutes: true
            ),
            PowerMatrixRow(
                name: "womp · 网络唤醒",
                guide: "允许局域网/外设唤醒，半夜误唤醒可关。命令：sudo pmset -c womp 0",
                acValue: ac.womp,
                batteryValue: battery?.womp,
                isMinutes: false
            ),
            PowerMatrixRow(
                name: "tcpkeepalive · 网络保活",
                guide: "休眠期维持网络连接，关闭可深度休眠。命令：sudo pmset -a tcpkeepalive 0",
                acValue: ac.tcpkeepalive,
                batteryValue: battery?.tcpkeepalive,
                isMinutes: false
            ),
            PowerMatrixRow(
                name: "powernap · 电能小憩",
                guide: "休眠期执行后台维护任务。命令：sudo pmset -a powernap 0",
                acValue: ac.powernap,
                batteryValue: battery?.powernap,
                isMinutes: false
            ),
            PowerMatrixRow(
                name: "displaysleep · 显示器关闭",
                guide: "屏幕无操作关闭超时。系统设置 → 锁屏；命令：sudo pmset -c displaysleep 20",
                acValue: ac.displaysleepMinutes,
                batteryValue: battery?.displaysleepMinutes,
                isMinutes: true
            ),
        ]
    }
}

/// 电源参数矩阵的一行。
private struct PowerMatrixRow: Identifiable {
    let name: String
    let guide: String
    let acValue: Int?
    let batteryValue: Int?
    /// true = 分钟数（sleep / displaysleep）；false = 0/1 开关位。
    let isMinutes: Bool

    var id: String { name }
}
