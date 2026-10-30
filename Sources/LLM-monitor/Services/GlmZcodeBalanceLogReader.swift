import Foundation

/// 一次余额日志解析的产出。balances 与 previews 同源——同一条最后匹配的
/// billing/balance 日志行，保证两条数据不会来自不同的轮询时刻。
struct GlmActivityPlanBalanceRead: Equatable, Sendable {
    let balances: [GlmActivityPlanBalance]
    let previews: [GlmActivityPlanPreview]
}

/// 解析 ZCode 余额轮询日志，产出最新活动套餐余额快照。
///
/// 文件发现策略：先读**今天**的 `YYYY-MM-DD.log`，没有任何 billing/balance 行时
/// 回退到**昨天**的文件（ZCode 今天还没运行过的场景）。日志可能很大（几十 MB），
/// 只读文件尾部若干 KB 再按行切分；尾部首行可能是半行，丢弃。
@available(*, deprecated, message: "Use GlmZcodeAPIClient instead")
enum GlmZcodeBalanceLogReader {
    nonisolated static let defaultLogDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".zcode", isDirectory: true)
        .appendingPathComponent("v2", isDirectory: true)
        .appendingPathComponent("logs", isDirectory: true)

    /// 行内标记。完整响应 JSON 紧跟在该标记之后直到行尾。
    nonisolated static let lineMarker = "billing/balance 请求完成 "

    /// 尾部读取字节数。每条余额响应约 2-4KB，512KB 足以覆盖最后几十条轮询。
    nonisolated static let tailByteCount = 512 * 1024

    /// 取最新的活动套餐余额 + 生效前预告。今天找不到标记行时回退昨天；
    /// 两天都没有 → nil。返回的 `balances` 为 `[]` 表示「解析成功但当前无活动
    /// 套餐」（如未领取体验套餐），与 nil（无法解析）语义不同，调用方据此区分展示。
    nonisolated static func latestRead(
        logDirectory: URL = defaultLogDirectoryURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> GlmActivityPlanBalanceRead? {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dates = [now, now.addingTimeInterval(-86_400)]
        for day in dates {
            let fileURL = logDirectory
                .appendingPathComponent(dayFormatter.string(from: day), isDirectory: false)
                .appendingPathExtension("log")
            guard let text = readTail(fileURL: fileURL) else { continue }
            if let read = latestRead(inLogText: text, now: now) {
                return read
            }
        }
        return nil
    }

    /// 兼容薄封装：只要余额列表（既有测试 / 调用表面）。
    nonisolated static func latestBalances(
        logDirectory: URL = defaultLogDirectoryURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [GlmActivityPlanBalance]? {
        latestRead(logDirectory: logDirectory, now: now, calendar: calendar)?.balances
    }

    /// 在一段日志文本里找**最后一条** billing/balance 行并解析。
    /// 没有匹配行 → nil；有行但 JSON 缺 balances → `[]`。
    nonisolated static func latestRead(
        inLogText text: String,
        now: Date = Date()
    ) -> GlmActivityPlanBalanceRead? {
        var lastMatch: (observedAt: Date?, json: String)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = line.range(of: lineMarker) else { continue }
            let json = line[range.upperBound...]
            guard !json.isEmpty else { continue }
            lastMatch = (parseLogTimestamp(String(line)), String(json))
        }
        guard let match = lastMatch else { return nil }
        return decodeRead(json: String(match.json), observedAt: match.observedAt, now: now)
    }

    /// 兼容薄封装：只要余额列表（既有测试表面）。
    nonisolated static func latestBalances(
        inLogText text: String,
        now: Date = Date()
    ) -> [GlmActivityPlanBalance]? {
        latestRead(inLogText: text, now: now)?.balances
    }

    // MARK: - 单行解析（纯函数，测试表面）

    /// 解析一条完整日志行为余额 + 生效前预告。
    nonisolated static func parseLine(
        _ line: String,
        now: Date = Date()
    ) -> GlmActivityPlanBalanceRead? {
        guard let range = line.range(of: lineMarker) else { return nil }
        let json = line[range.upperBound...]
        guard !json.isEmpty else { return nil }
        return decodeRead(json: String(json), observedAt: parseLogTimestamp(line), now: now)
    }

    /// 兼容薄封装：只要余额列表（既有测试表面）。过期条目（expires_at < now）
    /// 直接剔除，与「plan expire 就不显示」的口径一致。
    nonisolated static func parseBalanceLine(
        _ line: String,
        now: Date = Date()
    ) -> [GlmActivityPlanBalance]? {
        parseLine(line, now: now)?.balances
    }

    private nonisolated static func decodeRead(
        json: String,
        observedAt: Date?,
        now: Date
    ) -> GlmActivityPlanBalanceRead? {
        struct Payload: Decodable {
            struct Data: Decodable {
                struct Entitlement: Decodable {
                    let entitlement_id: String?
                    let show_name: String?
                    let capabilities: [String]?
                    let grant_units: Int?
                    let effective_at: Double?
                }
                struct Plan: Decodable {
                    let plan_id: String?
                    let name: String?
                    let status: String?
                    let ends_at: Double?
                    let entitlements: [Entitlement]?
                }
                struct Balance: Decodable {
                    let plan_id: String?
                    let entitlement_id: String?
                    let show_name: String?
                    let capabilities: [String]?
                    let total_units: Int?
                    let used_units: Int?
                    let remaining_units: Int?
                    let expires_at: Double?
                }
                let plans: [Plan]?
                let balances: [Balance]?
            }
            let payload: PayloadData?
            struct PayloadData: Decodable { let data: Data? }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            return nil
        }
        // 以 payload.data 为准（含 expires_at / capabilities）；顶层 summaries 是
        // host 日志的复制摘要，字段更少，不作数据源。
        let data = payload.payload?.data
        let plans = data?.plans ?? []
        let planNameByID = Dictionary(
            uniqueKeysWithValues: plans.compactMap { plan in
                plan.plan_id.map { ($0, plan.name ?? $0) }
            }
        )
        let balances = (data?.balances ?? []).compactMap { balance -> GlmActivityPlanBalance? in
            guard let entitlementID = balance.entitlement_id, !entitlementID.isEmpty else {
                return nil
            }
            let planID = balance.plan_id ?? ""
            let showName = balance.show_name ?? entitlementID
            // 过期即不显示：expires_at 缺失时保守保留，交给 UI 按缺失处理。
            if let expiresAt = balance.expires_at {
                let date = Date(timeIntervalSince1970: expiresAt)
                if date <= now { return nil }
            }
            return GlmActivityPlanBalance(
                planID: planID,
                planName: planNameByID[planID] ?? planID,
                entitlementID: entitlementID,
                showName: showName,
                modelNames: modelNames(from: balance.capabilities, fallback: showName),
                totalUnits: max(balance.total_units ?? 0, 0),
                usedUnits: max(balance.used_units ?? 0, 0),
                remainingUnits: max(balance.remaining_units ?? 0, 0),
                expiresAt: balance.expires_at.map { Date(timeIntervalSince1970: $0) },
                observedAt: observedAt
            )
        }

        // 生效前预告：活动套餐额度生效前 balances 为空，plans[].entitlements[]
        // 是唯一信息源。三条判定（与展示口径对齐）：balances 已有对应桶的不预告
        //（生效后不重复）；effective_at 未到才预告；plan 已过 ends_at 的整组剔除。
        let coveredEntitlementIDs = Set((data?.balances ?? []).compactMap(\.entitlement_id))
        let previews = plans.flatMap { plan -> [GlmActivityPlanPreview] in
            let planID = plan.plan_id ?? ""
            let planName = plan.name ?? planID
            if let endsAt = plan.ends_at, Date(timeIntervalSince1970: endsAt) <= now {
                return []
            }
            return (plan.entitlements ?? []).compactMap { entitlement -> GlmActivityPlanPreview? in
                guard let entitlementID = entitlement.entitlement_id, !entitlementID.isEmpty else {
                    return nil
                }
                guard !coveredEntitlementIDs.contains(entitlementID) else { return nil }
                guard let effectiveAt = entitlement.effective_at else { return nil }
                let effectiveDate = Date(timeIntervalSince1970: effectiveAt)
                guard effectiveDate > now else { return nil }
                let showName = entitlement.show_name ?? entitlementID
                return GlmActivityPlanPreview(
                    planID: planID,
                    planName: planName,
                    entitlementID: entitlementID,
                    showName: showName,
                    modelNames: modelNames(from: entitlement.capabilities, fallback: showName),
                    grantUnits: max(entitlement.grant_units ?? 0, 0),
                    effectiveAt: effectiveDate,
                    observedAt: observedAt
                )
            }
        }

        return GlmActivityPlanBalanceRead(balances: balances, previews: previews)
    }

    /// capabilities 里 `model:` 前缀的模型 ID；缺失时回退 `[fallback]`
    ///（balances 与 previews 共用同一口径）。
    private nonisolated static func modelNames(
        from capabilities: [String]?,
        fallback: String
    ) -> [String] {
        let names = (capabilities ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("model:") }
            .map { String($0.dropFirst("model:".count)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? [fallback] : names
    }

    /// 日志行前缀 `[2026-08-28 20:56:24.518]` → 本地时间。解析失败为 nil。
    private nonisolated static func parseLogTimestamp(_ line: String) -> Date? {
        let matched = line.first
        guard matched == "[", let close = line.firstIndex(of: "]") else { return nil }
        let text = String(line[line.index(after: line.startIndex)..<close])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: text)
    }

    /// 读文件尾部（≤ tailByteCount），避免大文件全量读盘。文件不存在 / 读失败 → nil。
    private nonisolated static func readTail(fileURL: URL) -> String? {
        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > 0 else { return nil }
        let byteCount = min(size, tailByteCount)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(size - byteCount))) != nil else { return nil }
        guard let data = try? handle.read(upToCount: byteCount) else { return nil }
        // 首字节大概率是半行，丢弃到第一个换行之后。
        var text = String(decoding: data, as: UTF8.self)
        if byteCount < size, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }
}
