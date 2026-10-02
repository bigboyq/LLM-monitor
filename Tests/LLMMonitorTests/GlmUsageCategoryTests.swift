import XCTest
@testable import LLM_monitor

final class GlmUsageCategoryTests: XCTestCase {

    /// 设置 → 客户端 → ZCode 的拆行依据：provider 身份 → Coding Plan / Start Plan
    /// / 闲时 / 其他。正式套餐与闲时为显式枚举（`OpencodeLocalUsage` 两个 ID 集合），
    /// 体验套餐按 `bigmodel-start-plan` 子串摘出，未知新套餐一律落其他；
    /// 与额度窗口白名单同一判定来源,无来源标记与 OpenCode / DSH 合并样本归 Coding Plan。
    func testGlmUsageCategoryClassify() {
        func sample(_ providerID: String?, promptID: String = "s:t1") -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(), modelName: "GLM-5.3-Flash", promptID: promptID,
                inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0,
                sourceProviderID: providerID
            )
        }

        // 正式 Coding Plan：0020 迁移后账号化 ID 显式登记（bigmodel + zai 族）
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-individual-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-team-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:zai-individual-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:zai-team-coding-plan")), .normal)
        // 历史遗留：0020 迁移前的旧 ID 继续识别
        XCTAssertEqual(GlmUsageCategory.classify(sample("builtin:bigmodel-coding-plan")), .normal)
        // 闲时：0020 迁移后账号化 ID（迁移前只精确匹配旧裸值,新 ID 会被误入其他）
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-offpeak-idle-plan")), .offPeak)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:zai-offpeak-idle-plan")), .offPeak)
        XCTAssertEqual(GlmUsageCategory.classify(sample("offpeak-idle-plan")), .offPeak)
        // 体验套餐 → Start Plan 独立成行（新旧前缀都算）
        XCTAssertEqual(GlmUsageCategory.classify(sample("builtin:bigmodel-start-plan")), .startPlan)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-start-plan")), .startPlan)
        // zai 族体验套餐仍走「其他」：Start Plan 判定只看 bigmodel-start-plan 子串
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:zai-start-plan")), .other)
        // 行为变更：未登记的后缀变体不再按「前缀 + -coding-plan 后缀」通配进日常
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-max-coding-plan")), .other)
        XCTAssertEqual(GlmUsageCategory.classify(sample("builtin:bigmodel-future-plan")), .other)
        // OpenCode / DSH 合并样本与旧缓存无标记样本 → Coding Plan
        XCTAssertEqual(GlmUsageCategory.classify(sample("dsh:zhipuai-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample(nil, promptID: "opencode:zhipuai-coding-plan:p1")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample(nil)), .normal)

        // 声明序即设置页行序：加 case 时这里会先红
        XCTAssertEqual(
            GlmUsageCategory.allCases.map(\.displayName),
            ["Coding Plan", "Start Plan", "闲时任务", "其他任务"]
        )
    }

    /// Start Plan 拆行不影响额度窗口口径：它依旧被 `isGlmOtherPlanSample` 覆盖，
    /// 依旧不计入 5h / 周窗口的消耗统计。
    func testGlmStartPlanSampleStaysExcludedFromQuotaWindow() {
        let startPlan = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_050),
            modelName: "GLM-5.3-Flash", promptID: "trial:t1",
            inputTokens: 500, cachedInputTokens: 0, outputTokens: 1,
            reasoningOutputTokens: 0, sourceProviderID: "account:bigmodel-start-plan"
        )
        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmStartPlanSample(startPlan))
        XCTAssertTrue(
            LocalUsageSummaryBuilder.isGlmOtherPlanSample(startPlan),
            "拆成 Start Plan 行不等于脱离额度窗口排除口径"
        )
        XCTAssertFalse(
            LocalUsageSummaryBuilder.isGlmStartPlanSample(
                LocalTokenUsageSample(
                    completedAt: Date(), modelName: "GLM-5.3-Flash", promptID: "no-source:t1",
                    inputTokens: 1, cachedInputTokens: 0, outputTokens: 1,
                    reasoningOutputTokens: 0, sourceProviderID: nil
                )
            ),
            "无来源标记的旧缓存样本不该被猜成 Start Plan"
        )
    }
}
