import Foundation
import IOKit
import IOKit.pwr_mgt

enum SleepHealthError: Error {
    case probeUnavailable(String)
}

/// 睡眠健康度与防休眠管理服务：
/// - 检查项 1：IOKit 断言扫描，识别霸占睡眠锁的第三方进程（白名单过滤系统正常断言）
/// - 检查项 2：`pmset -g custom` 读取 AC 侧 sleep（无公开 API，只读调用、免 sudo）
/// - 检查项 3：内存级「防止休眠」开关（IOPMAssertion，不入 config.json，重启复位；
///   断言随进程生命周期绑定，进程退出时 powerd 自动回收）
@MainActor
final class SleepHealthService: ObservableObject, SleepHealthReporting {
    @Published private(set) var report: SleepHealthReport?
    @Published private(set) var isKeepAwakeOn = false

    /// 本 App 持有的防休眠断言 ID；0 表示当前未持有
    private var keepAwakeAssertionID: IOPMAssertionID = 0
    private var pollTask: Task<Void, Never>?

    /// 本 App 自身 PID（过滤自查自报用）；进程内不变
    private let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

    /// 递增代际号：后台评估完成回主线程时校验，避免慢的旧结果覆盖新结果
    private var refreshGeneration = 0

    private let now: () -> Date
    private let assertionProbe: () throws -> [SleepAssertionSnapshot]
    private let pmsetCustomReader: () throws -> String

    init(
        now: @escaping () -> Date = { Date() },
        assertionProbe: (() throws -> [SleepAssertionSnapshot])? = nil,
        pmsetCustomReader: (() throws -> String)? = nil
    ) {
        self.now = now
        self.assertionProbe = assertionProbe ?? Self.defaultAssertionProbe
        self.pmsetCustomReader = pmsetCustomReader ?? Self.defaultPmsetCustomRead
    }

    // MARK: - 对外控制

    func refreshNow() {
        // 取快照后交给后台线程；IOKit 断言枚举与 pmset 子进程都不绑定 MainActor
        let probe = assertionProbe
        let reader = pmsetCustomReader
        let keepAwakeOn = isKeepAwakeOn
        let clock = now
        let pid = ownPID
        refreshGeneration &+= 1
        let generation = refreshGeneration

        Task.detached { [weak self] in
            // 检查项 1：断言扫描；探针抛错时按「无违规」降级，不让整体评估失败
            var snapshots: [SleepAssertionSnapshot] = []
            do {
                snapshots = try probe()
            } catch {
                logWarn("睡眠健康度：断言扫描失败，按无违规处理：\(error)")
            }

            // 检查项 2：pmset 电源配置；读取/解析失败时置 nil（unknown 不得误判为 acSleepDisabled）
            var powerConfig: PowerConfigSnapshot?
            var acSleepMinutes: Int?
            do {
                let output = try reader()
                if let config = SleepHealthEvaluator.parsePmsetCustomOutput(output) {
                    powerConfig = config
                    acSleepMinutes = config.ac.sleepMinutes
                } else {
                    logWarn("睡眠健康度：pmset 输出中未找到任何供电节，按未读取处理")
                }
            } catch {
                logWarn("睡眠健康度：pmset 读取失败，按未读取处理：\(error)")
            }

            // 检查项 3 + 综合：三色状态判定。违规列表只过滤一次，状态判定与
            // 明细展示共用同一份结果（红色态明细需要真实违规数据）。
            let offenders = SleepHealthEvaluator.filterOffenders(
                snapshots: snapshots,
                ownPID: pid,
                now: clock()
            )
            let status = SleepHealthEvaluator.evaluate(
                keepAwakeOn: keepAwakeOn,
                offenders: offenders,
                acSleepMinutes: acSleepMinutes
            )
            let report = SleepHealthReport(
                status: status,
                offenders: offenders,
                acSleepMinutes: acSleepMinutes,
                powerConfig: powerConfig,
                generatedAt: clock()
            )

            await MainActor.run { [weak self] in
                // 代际校验：仅发布最新一轮的结果，乱序返回的旧轮次直接丢弃
                guard let self, self.refreshGeneration == generation else { return }
                self.report = report
            }
        }
    }

    func setKeepAwake(_ enabled: Bool) {
        if enabled {
            // 已持有断言时幂等，避免重复创建导致泄漏
            guard keepAwakeAssertionID == 0 else {
                refreshNow()
                return
            }
            var newID: IOPMAssertionID = 0
            // kIOPMAssertionTypePreventUserIdleSystemSleep / kIOPMAssertionLevelOn 是
            // CFSTR 宏或匿名枚举值：前者未暴露给 Swift，直接使用其字符串值
            // "PreventUserIdleSystemSleep"（IOPMLib.h 中定义）；后者可见，直接引用。
            // kIOReturnSuccess 是 #define 宏（KERN_SUCCESS），未暴露给 Swift，以 0 比较。
            let status = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LLM-Monitor Keep-Awake" as CFString,
                &newID
            )
            if status == 0, newID != 0 {
                keepAwakeAssertionID = newID
                isKeepAwakeOn = true
            } else {
                // 创建失败不改 isKeepAwakeOn，保持「未开启」语义
                logError("创建防休眠断言失败：IOReturn \(status)")
            }
        } else {
            if keepAwakeAssertionID != 0 {
                let status = IOPMAssertionRelease(keepAwakeAssertionID)
                if status != 0 {
                    logError("释放防休眠断言失败：IOReturn \(status)")
                }
                keepAwakeAssertionID = 0
            }
            isKeepAwakeOn = false
        }
        refreshNow()
    }

    /// 启动周期轮询（首次立即评估；节奏与本地用量扫描循环保持同一量级）
    func start(interval: TimeInterval = 60) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            self?.refreshNow()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return // cancel 打断睡眠，直接退出循环
                }
                guard let self, !Task.isCancelled else { return }
                self.refreshNow()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 系统探针

    /// 枚举当前全部活动断言并映射为快照。
    ///
    /// 说明：任务目标中的 `IOPMAssertionGetIDList` 在本机（macOS 26 SDK + 运行时 dlsym）
    /// 均不存在——IOKit.tbd 未导出该符号，运行时也 dlsym 不到，它所属的 IOPMAssertions.h
    /// 头文件未随现代 SDK 发布。因此改用 SDK 公开导出的 `IOPMCopyAssertionsByProcess`
    /// （`pmset -g assertions` 同款数据源）：按 PID 返回每条断言的完整属性字典，字段与
    /// `IOPMAssertionCopyProperties` 返回的逐条字典一致，语义上等价覆盖「全部活动断言」。
    ///
    /// 属性键的真实字符串值（IOPMLib.h 中确认为 CFSTR 宏；OwnerName/PID/创建时间三个键
    /// 未随 SDK 发布，取真机 IOPMCopyAssertionsByProcess 实测值，并兼容旧头文件的键名）：
    /// - 类型 "AssertType"（kIOPMAssertionTypeKey）
    /// - 详情名 "AssertName"（kIOPMAssertionNameKey，对应 pmset 的 named: 字段），
    ///   补充字段 "Details"（kIOPMAssertionDetailsKey）
    /// - 属主名 "OwnerName"（旧 kIOPMAssertionOwnerNameKey）/ 实测键 "Process Name"
    /// - 属主 PID "OwnerPID"（旧 kIOPMAssertionOwnerPIDKey）/ 实测键 "AssertPID"
    /// - 创建时间 "CreationDate"（旧 kIOPMAssertionCreationTimeKey）/ 实测键 "AssertStartWhen"
    /// - 级别 "AssertLevel"（kIOPMAssertionLevelKey），255 = kIOPMAssertionLevelOn
    private static func defaultAssertionProbe() throws -> [SleepAssertionSnapshot] {
        var byPIDRef: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&byPIDRef)
        guard status == 0, let byPID = byPIDRef?.takeRetainedValue() as? [AnyHashable: Any] else {
            throw SleepHealthError.probeUnavailable("IOPMCopyAssertionsByProcess 失败：IOReturn \(status)")
        }

        var snapshots: [SleepAssertionSnapshot] = []
        for (_, value) in byPID {
            // 单条/单进程异常只跳过自身，不中断整体枚举
            guard let assertions = value as? [[AnyHashable: Any]] else { continue }
            for props in assertions {
                // 缺类型字段无法判定断言性质，跳过
                guard let type = props["AssertType"] as? String else { continue }

                var detailName = props["AssertName"] as? String
                if detailName == nil, let details = props["Details"] as? String {
                    detailName = details
                }

                var ownerName = props["OwnerName"] as? String
                if ownerName == nil { ownerName = props["Process Name"] as? String }

                var pid: Int32?
                if let number = props["OwnerPID"] as? Int ?? props["AssertPID"] as? Int {
                    pid = Int32(truncatingIfNeeded: number)
                }

                let creationDate = props["CreationDate"] as? Date ?? props["AssertStartWhen"] as? Date

                let level = props["AssertLevel"] as? Int
                snapshots.append(
                    SleepAssertionSnapshot(
                        assertionType: type,
                        detailName: detailName,
                        ownerName: ownerName,
                        pid: pid,
                        creationDate: creationDate,
                        levelOn: level == Int(kIOPMAssertionLevelOn)
                    )
                )
            }
        }
        return snapshots
    }

    /// ProcessRunner 执行 /usr/bin/pmset -g custom（只读、免 sudo）并返回 stdout
    private static func defaultPmsetCustomRead() throws -> String {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: ["-g", "custom"],
            timeout: 5
        )
        guard result.terminationStatus == 0 else {
            throw SleepHealthError.probeUnavailable(
                "pmset 退出码 \(result.terminationStatus)：\(result.standardError)"
            )
        }
        return result.standardOutput
    }
}
