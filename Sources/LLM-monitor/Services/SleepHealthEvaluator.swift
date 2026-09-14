import Foundation

/// 睡眠健康度纯判定逻辑：断言白名单过滤、`pmset -g custom` 输出解析、三色状态评估。
/// 全部为无副作用的 static 函数，供 SleepHealthService 与单元测试复用。
enum SleepHealthEvaluator {
    /// 会阻止系统空闲睡眠的断言类型（与 pmset -g assertions 输出中的 AssertType 值一致；
    /// IOPMLib.h 中 kIOPMAssertionTypePreventUserIdleSystemSleep 等是 CFSTR 宏，未暴露给
    /// Swift，故直接使用其字符串值）。UserIsActive 等其他类型天然被该集合排除。
    private static let sleepBlockingTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "NoIdleSleepAssertion",
        "PreventSystemSleep",
    ]

    /// 系统白名单进程名（路径解析失败时的兜底）：
    /// - powerd: 屏幕亮时的 "Powerd - Prevent sleep while display is on"
    /// - bluetoothd: "com.apple.BTStack" / "Bluetooth LE HID Activity"
    /// - WindowServer: 鼠标键盘活动断言
    /// （以上均已在真机 `pmset -g assertions` 输出中逐一验证）
    private static let systemWhitelistedOwners: Set<String> = [
        "powerd", "bluetoothd", "WindowServer", "loginwindow", "hidd",
    ]

    /// macOS 自带组件的可执行文件路径前缀。按路径判定比按进程名维护白名单更
    /// 稳健：系统守护进程常以用户会话身份持有"正常"断言（如 /usr/libexec/sharingd
    /// 的 "Handoff" PreventUserIdleSystemSleep，真机实测），逐个进程名打补丁追不完。
    private static let systemPathPrefixes: [String] = [
        "/System/", "/usr/libexec/", "/usr/lib/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
    ]

    /// 进程可执行文件路径解析（proc_pidpath；真机实测对 root 守护进程与第三方
    /// 应用均可解析）。作为 filterOffenders 的默认注入，测试可替换。
    static func resolveProcessPath(_ pid: Int32) -> String? {
        var pathbuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathbuf, UInt32(MAXPATHLEN)) > 0 else { return nil }
        return String(cString: pathbuf)
    }

    /// 是否系统自有进程：名称白名单命中，或路径可解析且位于系统目录。
    /// 路径解析失败且名称未命中时按第三方处理（保守口径，宁可误报不漏报）。
    private static func isSystemOwned(
        ownerName: String?,
        pid: Int32,
        pathProvider: (Int32) -> String?
    ) -> Bool {
        if let owner = ownerName, systemWhitelistedOwners.contains(owner) { return true }
        guard let path = pathProvider(pid) else { return false }
        return systemPathPrefixes.contains { path.hasPrefix($0) }
    }

    // MARK: - 检查项 1：违规断言过滤

    /// 从原始断言快照中筛出霸占睡眠锁的第三方进程：
    /// - 仅保留 levelOn 且类型属于睡眠锁集合的断言
    /// - 排除本 App 自己的断言（pid == ownPID，避免自查自报）
    /// - 排除系统自有进程（名称白名单或系统路径）的正常断言
    /// - heldSeconds = max(0, now - creationDate)，creationDate 缺失按 0 处理
    /// 结果按 heldSeconds 降序排列，便于 UI 直接展示。
    static func filterOffenders(
        snapshots: [SleepAssertionSnapshot],
        ownPID: Int32,
        now: Date,
        pathProvider: (Int32) -> String? = resolveProcessPath
    ) -> [SleepAssertionOffender] {
        var offenders: [SleepAssertionOffender] = []
        for snapshot in snapshots {
            guard snapshot.levelOn else { continue }
            guard sleepBlockingTypes.contains(snapshot.assertionType) else { continue }
            if let pid = snapshot.pid, pid == ownPID { continue }
            if isSystemOwned(ownerName: snapshot.ownerName, pid: snapshot.pid ?? 0, pathProvider: pathProvider) {
                continue
            }

            let heldSeconds = snapshot.creationDate.map { max(0, now.timeIntervalSince($0)) } ?? 0
            offenders.append(
                SleepAssertionOffender(
                    pid: snapshot.pid ?? 0,
                    processName: snapshot.ownerName ?? "未知",
                    assertionType: snapshot.assertionType,
                    detail: snapshot.detailName ?? "",
                    heldSeconds: heldSeconds
                )
            )
        }
        return offenders.sorted { $0.heldSeconds > $1.heldSeconds }
    }

    // MARK: - 检查项 2：pmset -g custom 输出解析

    /// 解析 `pmset -g custom` 的 stdout 为 AC / Battery 双份电源配置。
    /// - 按 "Battery Power:" / "AC Power:" 分节（大小写不敏感、容忍前后空白）
    /// - 每节解析 sleep/womp/tcpkeepalive/powernap/displaysleep 为 Int
    /// - "Sleep On Power Button 1"、hibernatefile 路径等行必须忽略
    /// - 台式机没有 Battery 节 → battery = nil；两节都找不到才返回 nil
    static func parsePmsetCustomOutput(_ text: String) -> PowerConfigSnapshot? {
        var sections: [String: PowerProfileSettings] = [:]

        var currentSection: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // 节头识别（大小写不敏感）；此前的 "System-wide power settings:" 等行因
            // currentSection == nil 被自然忽略
            let lowered = line.lowercased()
            if lowered == "battery power:" {
                currentSection = "battery"
                continue
            }
            if lowered == "ac power:" {
                currentSection = "ac"
                continue
            }
            guard let section = currentSection else { continue }

            // pmset 参数行的固定格式为 `名称<TAB/空格>数值`：取最后一个 token 作为数值，
            // 其余部分作为参数名。这样 "Sleep On Power Button 1" 的参数名是
            // "sleep on power button"（≠ sleep），hibernatefile 的数值是路径而非整数，
            // 两者都会被下面的名称/整数双重校验挡掉。
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 2 else { continue }
            let key = tokens.dropLast().joined(separator: " ").lowercased()
            guard let value = Int(String(tokens.last!)) else { continue }

            switch key {
            case "sleep":
                sections[section, default: PowerProfileSettings.defaults()].sleepMinutes = value
            case "womp":
                sections[section, default: PowerProfileSettings.defaults()].womp = value
            case "tcpkeepalive":
                sections[section, default: PowerProfileSettings.defaults()].tcpkeepalive = value
            case "powernap":
                sections[section, default: PowerProfileSettings.defaults()].powernap = value
            case "displaysleep":
                sections[section, default: PowerProfileSettings.defaults()].displaysleepMinutes = value
            default:
                break
            }
        }

        // 台式机只有 AC 节；极端情况下若只出现 Battery 节，AC 用全 nil 占位
        guard sections["ac"] != nil || sections["battery"] != nil else { return nil }
        let ac = sections["ac"] ?? PowerProfileSettings.defaults()
        let battery = sections["battery"]
        return PowerConfigSnapshot(ac: ac, battery: battery)
    }

    // MARK: - 综合评估

    /// 三色状态评估，判定顺序固定：
    /// 1. keepAwakeOn → .keepAwake（红，短路）
    /// 2. 违规断言非空 → .blockedByAssertions（黄，按 heldSeconds 降序）
    /// 3. acSleepMinutes == 0 → .acSleepDisabled（黄）
    /// 4. 否则 .healthy（绿）；acSleepMinutes == nil 视为未读取，不触发黄
    static func evaluate(
        keepAwakeOn: Bool,
        snapshots: [SleepAssertionSnapshot],
        ownPID: Int32,
        acSleepMinutes: Int?,
        now: Date,
        pathProvider: (Int32) -> String? = resolveProcessPath
    ) -> SleepHealthStatus {
        let offenders = filterOffenders(
            snapshots: snapshots,
            ownPID: ownPID,
            now: now,
            pathProvider: pathProvider
        )
        return evaluate(keepAwakeOn: keepAwakeOn, offenders: offenders, acSleepMinutes: acSleepMinutes)
    }

    /// 已过滤违规列表的评估核心（服务层先 filterOffenders 一次，供状态判定与
    /// 明细展示共用同一份结果，避免红色态下重复过滤）。
    static func evaluate(
        keepAwakeOn: Bool,
        offenders: [SleepAssertionOffender],
        acSleepMinutes: Int?
    ) -> SleepHealthStatus {
        if keepAwakeOn { return .keepAwake }

        if !offenders.isEmpty { return .blockedByAssertions(offenders) }

        if acSleepMinutes == 0 { return .acSleepDisabled }

        return .healthy
    }
}

private extension PowerProfileSettings {
    /// 全字段 nil 的空白配置（解析中途尚未命中任何目标行时的占位值）
    static func defaults() -> PowerProfileSettings {
        PowerProfileSettings(
            sleepMinutes: nil,
            womp: nil,
            tcpkeepalive: nil,
            powernap: nil,
            displaysleepMinutes: nil
        )
    }
}
