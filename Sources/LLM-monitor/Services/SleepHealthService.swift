import Foundation
import IOKit
import IOKit.pwr_mgt

enum SleepHealthError: Error {
    case probeUnavailable(String)
}

@_silgen_name("IOPMCopyPMPreferences")
private func IOPMCopyPMPreferences() -> Unmanaged<CFDictionary>?

/// 睡眠健康度与防休眠管理服务：
/// - 检查项 1：IOKit 断言扫描，识别霸占睡眠锁的第三方进程（白名单过滤系统正常断言）
/// - 检查项 2：IOPMCopyPMPreferences / pmset 读取 AC 侧 sleep
/// - 检查项 3：内存级「防止休眠」开关（IOPMAssertion，不入 config.json，重启复位；
///   断言随进程生命周期绑定，进程退出时 powerd 自动回收）
@MainActor
final class SleepHealthService: ObservableObject, SleepHealthReporting {
    @Published private(set) var report: SleepHealthReport?
    @Published private(set) var isKeepAwakeOn = false

    /// 本 App 持有的防休眠断言 ID；0 表示当前未持有
    private var keepAwakeAssertionID: IOPMAssertionID = 0

    /// 本 App 自身 PID（过滤自查自报用）；进程内不变
    private let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

    /// 递增代际号：后台评估完成回主线程时校验，避免慢的旧结果覆盖新结果
    private var refreshGeneration = 0

    /// 三个后台闭包（时钟 + 两个探针）必须是 `@Sendable`：`refreshNow()` 把它们
    /// 捕获进 `Task.detached` 这一非隔离任务，Swift 6 语言模式下非 Sendable 捕获
    /// 会被判为 sending 数据竞争（`Task.detached` 处直接编译失败）。
    /// 反过来若它们只是普通闭包，后台线程调用时没有任何隔离检查兜底。
    private let now: @Sendable () -> Date
    private let assertionProbe: @Sendable () throws -> [SleepAssertionSnapshot]
    private let powerConfigProbe: @Sendable () throws -> PowerConfigSnapshot?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        assertionProbe: (@Sendable () throws -> [SleepAssertionSnapshot])? = nil,
        powerConfigProbe: (@Sendable () throws -> PowerConfigSnapshot?)? = nil,
        pmsetCustomReader: (@Sendable () throws -> String)? = nil
    ) {
        self.now = now
        // 裸 `func` 引用的函数类型不是 `@Sendable`，直接赋给 `@Sendable` 目标会告警
        // （"converting non-Sendable function value ... may introduce data races"）。
        // 用零捕获闭包字面量包一层，契约在转换点显式化；探针体与调用时机都不变。
        self.assertionProbe = assertionProbe ?? { try Self.defaultAssertionProbe() }
        if let powerConfigProbe {
            self.powerConfigProbe = powerConfigProbe
        } else if let pmsetCustomReader {
            self.powerConfigProbe = {
                let output = try pmsetCustomReader()
                return SleepHealthEvaluator.parsePmsetCustomOutput(output)
            }
        } else {
            self.powerConfigProbe = { try Self.defaultPowerConfigProbe() }
        }
    }

    // MARK: - 对外控制

    func refreshNow() {
        // 取快照后交给后台线程；IOKit 断言枚举与电源参数探测都不绑定 MainActor
        let probe = assertionProbe
        let powerProbe = powerConfigProbe
        let keepAwakeOn = isKeepAwakeOn
        let clock = now
        let pid = ownPID
        refreshGeneration &+= 1
        let generation = refreshGeneration

        Task.detached { [weak self] in
            // 检查项 1：断言扫描。「探不到」≠「无违规」——探针抛错时无法判定
            // 有无违规，按空快照继续评估会把失败包装成 .healthy（假绿）。与检查
            // 项 2 的降级口径一致：本轮按未知处理，不发布健康结论。
            var snapshots: [SleepAssertionSnapshot]? = nil
            do {
                snapshots = try probe()
            } catch {
                logWarn("睡眠健康度：断言扫描失败，本轮按未知处理，不发布健康结论：\(error)")
            }

            // 检查项 2：电源配置；读取/解析失败时置 nil（unknown 不得误判为 acSleepDisabled）
            var powerConfig: PowerConfigSnapshot?
            var acSleepMinutes: Int?
            do {
                if let config = try powerProbe() {
                    powerConfig = config
                    acSleepMinutes = config.ac.sleepMinutes
                } else {
                    logWarn("睡眠健康度：电源配置读取为空，按未读取处理")
                }
            } catch {
                logWarn("睡眠健康度：电源配置读取失败，按未读取处理：\(error)")
            }

            // 断言扫描失败 → 本轮无健康结论：清除旧报告而不是沿用（旧报告可能
            // 是失败前一轮的「绿」，继续展示同样是假绿）。UI 对 nil report 按
            // 「评估中/未知」展示；防休眠红色由 isKeepAwakeOn 独立驱动，不受影响。
            guard let snapshots else {
                await MainActor.run { [weak self] in
                    guard let self, self.refreshGeneration == generation else { return }
                    self.report = nil
                }
                return
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
                if let old = report {
                    report = SleepHealthReport(
                        status: .keepAwake,
                        offenders: old.offenders,
                        acSleepMinutes: old.acSleepMinutes,
                        powerConfig: old.powerConfig,
                        generatedAt: Date()
                    )
                }
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
            if let old = report {
                let newStatus = SleepHealthEvaluator.evaluate(
                    keepAwakeOn: false,
                    offenders: old.offenders,
                    acSleepMinutes: old.acSleepMinutes
                )
                report = SleepHealthReport(
                    status: newStatus,
                    offenders: old.offenders,
                    acSleepMinutes: old.acSleepMinutes,
                    powerConfig: old.powerConfig,
                    generatedAt: Date()
                )
            }
        }
        refreshNow()
    }

    func stop() {
        // Invalidate a detached probe that may still be returning. Without
        // advancing the generation, a stop/restart boundary could publish a
        // stale report after the service has already been torn down.
        refreshGeneration &+= 1
        // L4: 清除旧报告——停止评估后不给任何健康结论，UI 不得继续显示停止前
        // 的三色状态（含探针失败被误降级成「绿」的假绿风险）。
        report = nil
        if keepAwakeAssertionID != 0 {
            let status = IOPMAssertionRelease(keepAwakeAssertionID)
            if status != 0 {
                logError("释放防休眠断言失败：IOReturn \(status)")
            }
            keepAwakeAssertionID = 0
        }
        isKeepAwakeOn = false
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
    /// - 断言 ID "AssertionId" / "AssertId"
    /// - 创建时间 "CreationDate"（旧 kIOPMAssertionCreationTimeKey）/ 实测键 "AssertStartWhen"
    /// - 级别 "AssertLevel"（kIOPMAssertionLevelKey），255 = kIOPMAssertionLevelOn
    /// `nonisolated`：这些系统探针要作为 `@Sendable` 闭包在 detached 任务里调用。
    /// 若沿用类上的 `@MainActor` 隐式隔离，函数引用在赋给闭包变量时隔离会被静默
    /// 抹掉——编译能过，实际却在后台线程执行，无人检查。
    nonisolated private static func defaultAssertionProbe() throws -> [SleepAssertionSnapshot] {
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

                var assertionId: UInt32?
                if let rawId = props["AssertionId"] as? Int ?? props["AssertId"] as? Int ?? props["AssertionID"] as? Int {
                    assertionId = UInt32(truncatingIfNeeded: rawId)
                }

                let creationDate = props["CreationDate"] as? Date ?? props["AssertStartWhen"] as? Date

                let level = props["AssertLevel"] as? Int
                snapshots.append(
                    SleepAssertionSnapshot(
                        assertionId: assertionId,
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

    /// 优先调用 IOPMCopyPMPreferences() 读取原生电源配置，失败则降级为 pmset -g custom
    nonisolated private static func defaultPowerConfigProbe() throws -> PowerConfigSnapshot? {
        if let unmanaged = IOPMCopyPMPreferences() {
            let dict = unmanaged.takeRetainedValue() as NSDictionary
            if let swiftDict = dict as? [AnyHashable: Any],
               let config = SleepHealthEvaluator.parsePmPreferencesDictionary(swiftDict) {
                return config
            }
        }
        let output = try defaultPmsetCustomRead()
        return SleepHealthEvaluator.parsePmsetCustomOutput(output)
    }

    /// ProcessRunner 执行 /usr/bin/pmset -g custom（只读、免 sudo）并返回 stdout（备用兜底）
    nonisolated private static func defaultPmsetCustomRead() throws -> String {
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
