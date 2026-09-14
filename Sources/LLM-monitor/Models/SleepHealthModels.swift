import Combine
import Foundation

// 「节能」模块（系统睡眠健康度与防休眠管理）在 UI 与服务实现之间的稳定数据契约。
// 实现见 Services/SleepHealthService.swift；纯判定/解析逻辑见 SleepHealthEvaluator。

/// 原始断言快照：由 IOKit 断言枚举映射而来，供白名单过滤与单元测试使用
struct SleepAssertionSnapshot: Equatable {
    /// 断言 ID（系统唯一自增标识，如 33575）
    var assertionId: UInt32?
    /// 断言类型，如 PreventUserIdleSystemSleep / NoIdleSleepAssertion / PreventSystemSleep
    var assertionType: String
    /// named: 详情字段，如 "Electron"、"com.apple.BTStack"
    var detailName: String?
    /// 属主进程名（kIOPMAssertionOwnerNameKey），如 "powerd"、"ZCode"
    var ownerName: String?
    /// 属主进程 PID
    var pid: Int32?
    /// 断言创建时间（用于计算已持有时长）
    var creationDate: Date?
    /// 断言级别是否为 On（255）
    var levelOn: Bool
}

/// 违规持有睡眠锁的第三方进程条目（检查项 1 的输出）
struct SleepAssertionOffender: Identifiable, Equatable {
    let assertionId: UInt32?
    let pid: Int32
    let processName: String
    let assertionType: String
    let detail: String
    let heldSeconds: TimeInterval
    let creationDate: Date?

    init(
        assertionId: UInt32? = nil,
        pid: Int32,
        processName: String,
        assertionType: String,
        detail: String,
        heldSeconds: TimeInterval,
        creationDate: Date? = nil
    ) {
        self.assertionId = assertionId
        self.pid = pid
        self.processName = processName
        self.assertionType = assertionType
        self.detail = detail
        self.heldSeconds = heldSeconds
        self.creationDate = creationDate
    }

    var id: String {
        if let assertionId, assertionId > 0 {
            return "\(assertionId)"
        }
        return "\(pid)-\(assertionType)-\(detail)"
    }
}

/// 单一供电配置下的关键电源参数（nil 表示 pmset 未报告该项）
struct PowerProfileSettings: Equatable {
    var sleepMinutes: Int?
    var womp: Int?
    var tcpkeepalive: Int?
    var powernap: Int?
    var displaysleepMinutes: Int?
}

/// `pmset -g custom` 解析结果（AC / Battery 双列；台式机无电池节时 battery 为 nil）
struct PowerConfigSnapshot: Equatable {
    var ac: PowerProfileSettings
    var battery: PowerProfileSettings?
}

/// 三色睡眠健康度状态
enum SleepHealthStatus: Equatable {
    /// 绿：三项检查全部通过
    case healthy
    /// 黄：存在第三方进程霸占睡眠锁（检查项 1 不通过）
    case blockedByAssertions([SleepAssertionOffender])
    /// 黄：AC 供电下自动休眠已关闭（检查项 2 不通过，ac_sleep = 0）
    case acSleepDisabled
    /// 红：本 App 的「防止休眠」开关开启（检查项 3）
    case keepAwake

    /// 映射到全局三色体系（与菜单栏健康圆点共用 HealthLevel）
    var healthLevel: HealthLevel {
        switch self {
        case .healthy:
            return .healthy
        case .blockedByAssertions, .acSleepDisabled:
            return .warning
        case .keepAwake:
            return .critical
        }
    }
}

/// 一次睡眠健康度评估的完整输出
struct SleepHealthReport: Equatable {
    var status: SleepHealthStatus
    /// 过滤后的全部第三方违规断言（无论哪个状态胜出都携带：红色态的检查项 1
    /// 明细需要真实数据，而非按胜出状态反推）
    var offenders: [SleepAssertionOffender]
    /// AC 侧 sleep 原始值（分钟）；nil 表示未能读取
    var acSleepMinutes: Int?
    /// 参数矩阵表数据；nil 表示本次未获取到
    var powerConfig: PowerConfigSnapshot?
    var generatedAt: Date
}

/// UI 与 AppState 消费睡眠健康度的稳定接口；实现在 Services/SleepHealthService.swift
@MainActor
protocol SleepHealthReporting: ObservableObject {
    /// 最近一次评估结果；nil 表示尚未完成首次评估
    var report: SleepHealthReport? { get }
    /// 「防止休眠」内存开关（不持久化，应用重启后复位为关闭）
    var isKeepAwakeOn: Bool { get }
    /// 立即重新评估（断言扫描 + pmset 读取）
    func refreshNow()
    /// 设置/取消本 App 的防休眠断言
    func setKeepAwake(_ enabled: Bool)
}
