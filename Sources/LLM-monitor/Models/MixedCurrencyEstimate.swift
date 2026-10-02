import Foundation

/// 跨 provider 汇总用的混合币种价值：统一折算 CNY，USD 按 `usdToCNYRate` 折算。
///
/// 定位分层：
/// - `ModelCostEstimate` 是**单个 provider 内**的计价结果。同一 provider 遇到币种
///   冲突时宁可把冲突模型丢进 unpriced 也不相加（`ModelPricingCatalog.estimate` 的
///   防御分支），报「部分计价」而不是假总额。
/// - 本类型是**跨 provider 汇总**层的第二层：把各 provider 的已计价金额按币种归集，
///   USD 折算成 CNY 求总额，同时保留 USD 原额用于文案标注。
///
/// 全额用 `Decimal` 而非 `Double`：`ModelCostEstimate.value` 来自浮点累加，折算
/// 乘法（`usd × 7`）若继续用 `Double` 会出现 `0.3 × 7 = 2.0999999999999996` 这类尾差，
/// 两位小数文案里就会变成错账。
struct MixedCurrencyEstimate: Equatable, Sendable {
    /// USD → CNY 折算率。产品决策：暂硬编码 7，不做配置项；调整只改这一处。
    static let usdToCNYRate: Decimal = 7

    /// USD 原额（未折算）。
    var usdTotal: Decimal
    /// CNY 原额。
    var cnyTotal: Decimal

    init(usd: Decimal, cny: Decimal) {
        self.usdTotal = usd
        self.cnyTotal = cny
    }

    /// 由各 provider 的 [ModelCostEstimate] 归集。
    ///
    /// 跳过规则：`value` 或 `currency` 为 nil（未计价 / `未定价`）的 estimate 不贡献
    /// 金额。「部分计价」提示由调用方按各自 estimate 的 `CostCoverage` 自行决定，
    /// 本类型只负责金额。
    init(estimates: [ModelCostEstimate]) {
        var usd: Decimal = 0
        var cny: Decimal = 0
        for estimate in estimates {
            guard let value = estimate.value, let currency = estimate.currency else { continue }
            let amount = Self.decimal(fromDouble: value)
            switch currency {
            case .usd:
                usd += amount
            case .cny:
                cny += amount
            }
        }
        self.init(usd: usd, cny: cny)
    }

    /// 折算成 CNY 后的总额：`cnyTotal + usdTotal × usdToCNYRate`。
    var cnyEquivalentTotal: Decimal {
        cnyTotal + usdTotal * Self.usdToCNYRate
    }

    var isEmpty: Bool {
        usdTotal == 0 && cnyTotal == 0
    }

    /// 菜单汇总共用的金额文案。
    ///
    /// - 纯 CNY（usd == 0）→ `¥10.50`，纯 USD（cny == 0）→ `$3.20`
    ///   （与 `ModelCostEstimate.displayText` 同为定长两位小数的「金额」形态）
    /// - 混合 → `10（含$1）`：总额是 CNY 折算后金额（无 `¥` 前缀，因为它已不是单一
    ///   币种），括号内是 USD 原额。混合形态是「总额 + 构成标注」而不是单一金额，
    ///   补 `.00` 会凭空造出并不存在的分位，因此总额与 USD 部分都按最多两位小数
    ///   呈现、无小数则省略。
    /// - 两边都为 0 → `¥0.00`（零值走纯 CNY 分支，符号稳定）
    var displayText: String {
        if usdTotal == 0 {
            return ModelPriceCurrency.cny.symbol + Self.fixedAmount(cnyTotal)
        }
        if cnyTotal == 0 {
            return ModelPriceCurrency.usd.symbol + Self.fixedAmount(usdTotal)
        }
        return Self.trimmedAmount(cnyEquivalentTotal)
            + "（含" + ModelPriceCurrency.usd.symbol + Self.trimmedAmount(usdTotal) + "）"
    }

    // MARK: - 格式化

    /// 从 `ModelCostEstimate.value`（Double）取 Decimal 时截断二进制尾差：
    /// `Decimal(0.1)` 精确等于 0.1000000000000000055511151231257827021181583404541015625，
    /// 累加后会让 `Equatable` 相等判断和文案断言都被尾差绊倒。截到 10 位小数既能
    /// 抹掉尾差，又远高于价格估算本身的精度上限。
    private static func decimal(fromDouble value: Double) -> Decimal {
        var source = Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, Self.doubleToDecimalScale, .plain)
        return rounded
    }

    private static let doubleToDecimalScale = 10

    /// 定长两位小数，等价于 `ModelCostEstimate.displayText` 的 `%.2f` 惯例。
    private static func fixedAmount(_ value: Decimal) -> String {
        format(value, minimumFractionDigits: 2)
    }

    /// 最多两位小数，无小数位则省略。
    private static func trimmedAmount(_ value: Decimal) -> String {
        format(value, minimumFractionDigits: 0)
    }

    private static func format(_ value: Decimal, minimumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        // 显式固定为四舍五入：NumberFormatter 默认是 banker's rounding，在
        // `.005` 边界上会与 UI 其他金额文案产生不一致的进位方向。
        formatter.roundingMode = .halfUp
        return formatter.string(from: value as NSDecimalNumber) ?? Self.fallback(minimumFractionDigits)
    }

    private static func fallback(_ minimumFractionDigits: Int) -> String {
        minimumFractionDigits == 0 ? "0" : "0.00"
    }
}
