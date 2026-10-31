import Foundation

/// 请求 ZCode 官方私有 API：重置卡状态、Start Plan 活动套餐余额、营销活动触达
enum GlmZcodeAPIClient {
    static let logTag = "[glm-zcode-api]"
    static let defaultAppVersion = "3.17.1"
    static let balanceURLString = "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=\(defaultAppVersion)"
    static let resetStatusURLString = "https://zcode.z.ai/api/v1/coding-plan/reset/status"
    static let marketingTouchURLString = "https://zcode.z.ai/api/v1/marketing/touch"

    // MARK: - 1. Start Plan 套餐余额

    /// 获取 ZCode 活动套餐余额与生效前预告
    static func fetchBalance(
        credentials: GlmZcodeCredentials,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> ([GlmActivityPlanBalance], [GlmActivityPlanPreview]) {
        guard let jwtToken = credentials.jwtToken, !jwtToken.isEmpty else {
            throw QuotaError.decodingError("ZCode JWT Token 缺失")
        }
        guard let url = URL(string: balanceURLString) else {
            throw QuotaError.decodingError("无效的 balance URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        if let deviceMid = credentials.deviceMid, !deviceMid.isEmpty {
            req.setValue(deviceMid, forHTTPHeaderField: "X-Device-Mid")
        }
        req.setValue("zh-CN", forHTTPHeaderField: "X-Client-Language")
        req.setValue(defaultAppVersion, forHTTPHeaderField: "X-ZCode-App-Version")
        if let bigmodelToken = credentials.bigmodelAccessToken, !bigmodelToken.isEmpty {
            req.setValue(bigmodelToken, forHTTPHeaderField: "X-Bigmodel-Authorization")
            req.setValue("PERSONAL", forHTTPHeaderField: "Bigmodel-Target-Type")
        }

        let client = HTTPClient(session: session, logTag: logTag, defaultTimeout: HTTPTimeouts.domestic)
        let (data, _) = try await client.send(req)
        return try parseBalanceResponse(data: data, now: now)
    }

    // MARK: - 2. 额度重置卡状态

    /// 获取可用 5 小时卡与周卡重置卡状态
    static func fetchResetCards(
        credentials: GlmZcodeCredentials,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> GlmResetCardsSnapshot {
        guard let jwtToken = credentials.jwtToken, !jwtToken.isEmpty else {
            throw QuotaError.decodingError("ZCode JWT Token 缺失")
        }
        guard let bigmodelToken = credentials.bigmodelAccessToken, !bigmodelToken.isEmpty else {
            throw QuotaError.decodingError("ZCode BigModel Token 缺失")
        }
        guard let url = URL(string: resetStatusURLString) else {
            throw QuotaError.decodingError("无效的 reset status URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        req.setValue(bigmodelToken, forHTTPHeaderField: "X-Bigmodel-Authorization")
        req.setValue("PERSONAL", forHTTPHeaderField: "Bigmodel-Target-Type")

        let client = HTTPClient(session: session, logTag: logTag, defaultTimeout: HTTPTimeouts.domestic)
        let (data, _) = try await client.send(req)
        return try parseResetCardsResponse(data: data, now: now)
    }

    // MARK: - 3. 运营营销活动触达

    /// 获取未领取的营销活动列表
    static func fetchMarketingTouch(
        credentials: GlmZcodeCredentials,
        seq: Int = 1,
        session: URLSession = .shared
    ) async throws -> [GlmMarketingDelivery] {
        guard let jwtToken = credentials.jwtToken, !jwtToken.isEmpty else {
            throw QuotaError.decodingError("ZCode JWT Token 缺失")
        }
        var comp = URLComponents(string: marketingTouchURLString)
        comp?.queryItems = [URLQueryItem(name: "seq", value: String(seq))]
        guard let url = comp?.url else {
            throw QuotaError.decodingError("无效的 marketing touch URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        if let deviceMid = credentials.deviceMid, !deviceMid.isEmpty {
            req.setValue(deviceMid, forHTTPHeaderField: "X-Device-Mid")
        }
        req.setValue("zh-CN", forHTTPHeaderField: "X-Client-Language")
        req.setValue(defaultAppVersion, forHTTPHeaderField: "X-ZCode-App-Version")

        let client = HTTPClient(session: session, logTag: logTag, defaultTimeout: HTTPTimeouts.domestic)
        let (data, _) = try await client.send(req)
        return try parseMarketingTouchResponse(data: data)
    }

    // MARK: - 响应解析辅助（纯函数）

    static func parseBalanceResponse(
        data: Data,
        now: Date = Date()
    ) throws -> ([GlmActivityPlanBalance], [GlmActivityPlanPreview]) {
        struct BalanceEnvelope: Decodable {
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
                let ends_at: Double?
            }
            struct DataBlock: Decodable {
                let plans: [Plan]?
                let balances: [Balance]?
            }
            struct PayloadWrapper: Decodable {
                let data: DataBlock?
            }

            let code: Int?
            let data: DataBlock?
            let payload: PayloadWrapper?

            var effectiveData: DataBlock? {
                data ?? payload?.data
            }
        }

        func toDate(_ timestamp: Double?) -> Date? {
            guard let timestamp, timestamp > 0 else { return nil }
            let seconds = timestamp > 100_000_000_000 ? timestamp / 1000.0 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }

        guard let envelope = try? JSONDecoder().decode(BalanceEnvelope.self, from: data) else {
            throw QuotaError.decodingError("GLM ZCode Balance 响应无法解析")
        }

        let dataBlock = envelope.effectiveData
        let plans = dataBlock?.plans ?? []
        let rawBalances = dataBlock?.balances ?? []

        let planNameByID = Dictionary(
            uniqueKeysWithValues: plans.compactMap { plan in
                plan.plan_id.map { ($0, plan.name ?? $0) }
            }
        )

        let balances: [GlmActivityPlanBalance] = rawBalances.compactMap { balance in
            guard let entitlementID = balance.entitlement_id, !entitlementID.isEmpty else {
                return nil
            }
            let planID = balance.plan_id ?? ""
            let showName = balance.show_name ?? entitlementID
            let expiryDate = toDate(balance.expires_at ?? balance.ends_at)
            if let expiryDate, expiryDate <= now { return nil }
            return GlmActivityPlanBalance(
                planID: planID,
                planName: planNameByID[planID] ?? planID,
                entitlementID: entitlementID,
                showName: showName,
                modelNames: extractModelNames(from: balance.capabilities, fallback: showName),
                totalUnits: max(balance.total_units ?? 0, 0),
                usedUnits: max(balance.used_units ?? 0, 0),
                remainingUnits: max(balance.remaining_units ?? 0, 0),
                expiresAt: expiryDate,
                observedAt: now
            )
        }

        let coveredEntitlementIDs = Set(rawBalances.compactMap(\.entitlement_id))
        let previews: [GlmActivityPlanPreview] = plans.flatMap { plan -> [GlmActivityPlanPreview] in
            let planID = plan.plan_id ?? ""
            let planName = plan.name ?? planID
            if let endsAt = toDate(plan.ends_at), endsAt <= now {
                return []
            }
            return (plan.entitlements ?? []).compactMap { entitlement -> GlmActivityPlanPreview? in
                guard let entitlementID = entitlement.entitlement_id, !entitlementID.isEmpty else {
                    return nil
                }
                guard !coveredEntitlementIDs.contains(entitlementID) else { return nil }
                guard let effectiveDate = toDate(entitlement.effective_at) else { return nil }
                guard effectiveDate > now else { return nil }
                let showName = entitlement.show_name ?? entitlementID
                return GlmActivityPlanPreview(
                    planID: planID,
                    planName: planName,
                    entitlementID: entitlementID,
                    showName: showName,
                    modelNames: extractModelNames(from: entitlement.capabilities, fallback: showName),
                    grantUnits: max(entitlement.grant_units ?? 0, 0),
                    effectiveAt: effectiveDate,
                    observedAt: now
                )
            }
        }

        return (balances, previews)
    }

    static func parseResetCardsResponse(
        data: Data,
        now: Date = Date()
    ) throws -> GlmResetCardsSnapshot {
        struct ResetCardRawItem: Decodable {
            let expire_at: Double?
            let expires_at: Double?
            var effectiveExpireAt: Double? { expire_at ?? expires_at }
        }
        struct HistoryRawItem: Decodable {
            let used_at: Double?
        }
        struct ResetData: Decodable {
            let available_five_hour_resets: [ResetCardRawItem]?
            let available_week_resets: [ResetCardRawItem]?
            let latest_five_hour_reset_history: HistoryRawItem?
            let latest_week_reset_history: HistoryRawItem?
            let has_unread_history: Bool?
        }
        struct ResetEnvelope: Decodable {
            let code: Int?
            let msg: String?
            let data: ResetData?
        }

        guard let envelope = try? JSONDecoder().decode(ResetEnvelope.self, from: data),
              let resetData = envelope.data else {
            throw QuotaError.decodingError("GLM ZCode 重置卡状态响应无法解析")
        }

        func toDate(_ timestamp: Double?) -> Date? {
            guard let timestamp, timestamp > 0 else { return nil }
            let seconds = timestamp > 100_000_000_000 ? timestamp / 1000.0 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }

        let fiveHourCards = (resetData.available_five_hour_resets ?? []).compactMap { item -> GlmResetCardItem? in
            guard let date = toDate(item.effectiveExpireAt) else { return nil }
            return GlmResetCardItem(expireAt: date)
        }.sorted { $0.expireAt < $1.expireAt }

        let weekCards = (resetData.available_week_resets ?? []).compactMap { item -> GlmResetCardItem? in
            guard let date = toDate(item.effectiveExpireAt) else { return nil }
            return GlmResetCardItem(expireAt: date)
        }.sorted { $0.expireAt < $1.expireAt }

        return GlmResetCardsSnapshot(
            fiveHourResets: fiveHourCards,
            weekResets: weekCards,
            latestFiveHourUsedAt: toDate(resetData.latest_five_hour_reset_history?.used_at),
            latestWeekUsedAt: toDate(resetData.latest_week_reset_history?.used_at),
            observedAt: now
        )
    }

    static func parseMarketingTouchResponse(data: Data) throws -> [GlmMarketingDelivery] {
        struct DeliveryRaw: Decodable {
            let id: String?
            let delivery_id: String?
            let title: String?
            let body: String?
            let content: String?
            let plan_id: String?
            let planID: String?
        }
        struct TouchData: Decodable {
            let deliveries: [DeliveryRaw]?
        }
        struct TouchEnvelope: Decodable {
            let code: Int?
            let msg: String?
            let data: TouchData?
            let deliveries: [DeliveryRaw]?
        }

        guard let envelope = try? JSONDecoder().decode(TouchEnvelope.self, from: data) else {
            throw QuotaError.decodingError("GLM ZCode 营销触达响应无法解析")
        }

        let rawList = envelope.data?.deliveries ?? envelope.deliveries ?? []
        return rawList.compactMap { raw in
            let id = raw.id ?? raw.delivery_id ?? raw.plan_id ?? raw.planID ?? UUID().uuidString
            let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (raw.body ?? raw.content)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let planID = raw.plan_id ?? raw.planID
            return GlmMarketingDelivery(id: id, title: title, body: body, planID: planID)
        }
    }

    private static func extractModelNames(from capabilities: [String]?, fallback: String) -> [String] {
        let names = (capabilities ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("model:") }
            .map { String($0.dropFirst("model:".count)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? [fallback] : names
    }
}
