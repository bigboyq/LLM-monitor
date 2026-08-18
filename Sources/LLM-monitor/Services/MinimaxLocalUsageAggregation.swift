import Foundation
import Combine

// MARK: - Aggregation (pure functions, unit-testable)

extension MinimaxLocalUsageScanner {
    /// 将 per-day reasoning 分摊比例回写到逐次调用，保证 Last Prompt / 窗口
    /// hover 与 7 天柱图使用同一套 output/reason 口径。
    nonisolated static func applyReasoningSplit(
        samples: [LocalTokenUsageSample],
        rawPerDay: [Date: MinimaxDailyUsage],
        adjustedPerDay: [Date: MinimaxDailyUsage],
        calendar: Calendar
    ) -> [LocalTokenUsageSample] {
        samples.map { sample in
            guard sample.reasoningOutputTokens == 0 else { return sample }
            let day = calendar.startOfDay(for: sample.completedAt)
            guard let raw = rawPerDay[day],
                  let adjusted = adjustedPerDay[day],
                  raw.outputTokens > 0,
                  adjusted.reasoningTokens > 0 else {
                return sample
            }

            let ratio = min(
                max(Double(adjusted.reasoningTokens) / Double(raw.outputTokens), 0),
                1
            )
            let reasoning = min(
                Int((Double(sample.outputTokens) * ratio).rounded()),
                sample.outputTokens
            )
            return LocalTokenUsageSample(
                completedAt: sample.completedAt,
                modelName: sample.modelName,
                promptID: sample.promptID,
                inputTokens: sample.inputTokens,
                cachedInputTokens: sample.cachedInputTokens,
                outputTokens: max(sample.outputTokens - reasoning, 0),
                reasoningOutputTokens: reasoning
            )
        }
    }

    /// P1-1 v2 字符聚合过滤 — 异常 day 不跑字符分摊 (会偏高 reason 比例)。
    ///
    /// v2 字符聚合是 per-day 聚合(不 join token_usage),v2 message_rows.turn_id
    /// 100% NULL 无法 per-turn 配对。v2 runtime 早期 token 写入不完整时(7/11
    /// 实测 message 1280 vs token 404 = 3.17x),字符聚合会偏高(分母过大,稀释
    /// reason 比例)。检测并过滤不安全的 v2 字符数据（message 行数 vs token 行数
    /// 比例过高时跳过）。
    ///
    /// - Returns: 过滤后的 perDayChars 字典 (异常 day 被移除)
    nonisolated static func filterUnsafeV2CharCounts(
        aggregate: MinimaxDBAggregate,
        ratioThreshold: Double = 2.0
    ) -> [Date: MinimaxCharCounts] {
        var safeChars: [Date: MinimaxCharCounts] = [:]
        for (day, chars) in aggregate.perDayChars {
            guard let usage = aggregate.perDay[day], usage.rounds > 0 else {
                // 没有 token 行(空 day), 字符聚合无意义 — 跳过
                logInfo("[minimax-scan] day=\(day): v2 字符聚合无对应 token 行, 跳过字符分摊 (messageCount=\(chars.messageCount), rounds=0)")
                continue
            }
            // 真正检测: message 行数 / token 行数
            let ratio = Double(chars.messageCount) / Double(usage.rounds)
            if ratio > ratioThreshold {
                logWarn("[minimax-scan] day=\(day): v2 message(\(chars.messageCount)) / rounds(\(usage.rounds)) = \(String(format: "%.2f", ratio))x (阈值 \(ratioThreshold)) — token 写入不完整,跳过当天字符分摊 (reason 会算成 0)")
            } else {
                safeChars[day] = chars
            }
        }
        return safeChars
    }

    /// 把账单的 `outputTokens` 拆成 (realOutput, realReason)。
    /// per-day 决策,贴合 minimax 现实 + future-proof:
    ///
    /// ## 两条路径(per-day 决策)
    ///
    /// 1. **`usage.reasoningTokens > 0`**：账单直接给了 reasoning(未来 thinking
    ///    model 路径)。`output = output - reason`,`reason = reasoningTokens`。
    ///    reader 已经 per-row 取大 `MAX(reasoning_tokens, raw.reasoning)` 再
    ///    SUM(v8 修复 P1/P2-1),所以 `usage.reasoningTokens` 自动捕获两个源 —
    ///    不管 minimax 切到 `reasoning_tokens` 列还是 `raw.reasoning` JSON 字段,
    ///    这条路径都直接触发。
    /// 2. **`usage.reasoningTokens == 0`**：M3 / M2.7 non-thinking 路径,按
    ///    `session_messages.thinking_content` + `msg_content` 字符数比例分摊:
    ///    ```
    ///    reasonTokens  = outputTokens * rawReason / (rawReason + rawOutput)
    ///    realOutput   = outputTokens - reasonTokens
    ///    ```
    ///    守恒: `reasonTokens + realOutput == outputTokens` 永远成立。
    ///
    /// 没字符数据的 day(v2 没 session_messages、字符聚合失败等)保持原样:
    /// `outputTokens` 不变、`reasoningTokens = 0`。
    ///
    /// 抽成 static + 纯函数,方便测试在 XCTestCase sync context 直接调
    /// (不需要构造完整 scanner)。
    nonisolated static func applyReasoningSplit(
        perDay: [Date: MinimaxDailyUsage],
        perDayChars: [Date: MinimaxCharCounts]
    ) -> [Date: MinimaxDailyUsage] {
        var out: [Date: MinimaxDailyUsage] = [:]
        for (day, usage) in perDay {
            let (reasonTokens, realOutput): (Int, Int)
            let outputTokens = max(usage.outputTokens, 0)
            if usage.reasoningTokens > 0 {
                // 未来 thinking model 路径(per-day reasoningTokens > 0):
                // 账单已经分了 reasoning,output = output - reason
                //
                // Sanity check (P2-2): 如果 reasoning > output (异常,可能账单字段
                // 解释变了,或 raw 路径重复算),截断 reasoning 到 output 保持守恒
                // (reasoning + realOutput == output)。原样保持会输出 > 原始 output,
                // 让 UI totalTokens 算错。
                if usage.reasoningTokens > outputTokens {
                    logWarn("[minimax-scan] day=\(day): reasoning(\(usage.reasoningTokens)) > output(\(usage.outputTokens)), 截断到 output 保持守恒")
                }
                reasonTokens = min(usage.reasoningTokens, outputTokens)
                realOutput = outputTokens - reasonTokens
            } else if let chars = perDayChars[day] {
                let totalChars = SaturatingArithmetic.add(chars.reason, chars.output)
                guard totalChars > 0 else {
                    out[day] = usage
                    continue
                }
                // 当前 M3 / M2.7 路径:按字符比例分摊 outputTokens
                if chars.output == 0 {
                    // 极端:只有 thinking 没 content → 100% 算 reason
                    reasonTokens = outputTokens
                } else if chars.reason == 0 {
                    // 极端:只有 content 没 thinking → 0 算 reason
                    reasonTokens = 0
                } else {
                    // 正常:按字符比例
                    let proportion = Double(max(chars.reason, 0)) / Double(totalChars)
                    let estimate = (Double(outputTokens) * proportion).rounded()
                    // Double(Int.max) 在 64-bit 平台会向上舍入到 2^63，直接转 Int
                    // 可能 trap；边界值直接饱和，并再约束到 output 保持守恒。
                    let estimatedTokens = estimate >= Double(Int.max)
                        ? Int.max
                        : (Int(exactly: estimate) ?? 0)
                    reasonTokens = min(max(estimatedTokens, 0), outputTokens)
                }
                realOutput = outputTokens - reasonTokens
            } else {
                // 没字符数据(v2 异常 day 跳过 / 字符聚合失败) → 保持原样
                out[day] = usage
                continue
            }

            // P1-2 修: 重新算 totalTokens, 保持 input + cacheRead + realOutput + reason
            // 守恒 (跟字段总和一致)。之前用 reader 算的 totalTokens (含 reasoning 一
            // 次), 但 UI 看到的 input+realOutput+reason 比 reader 算的少一个
            // reasoning, 字段总和跟 totalTokens 不一致。
            // 修后: totalTokens = input + cacheRead + (output - reason) + reason
            //                              = input + cacheRead + output (跟账单一致)
            let newTotal = SaturatingArithmetic.sum(
                usage.inputTokens,
                usage.cacheReadTokens,
                realOutput,
                reasonTokens
            )
            out[day] = MinimaxDailyUsage(
                dayStart: usage.dayStart,
                inputTokens: usage.inputTokens,
                outputTokens: realOutput,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: reasonTokens,
                totalTokens: newTotal,
                turns: usage.turns,
                rounds: usage.rounds
            )
        }
        return out
    }
    nonisolated static func computeGlobalDaily(
        from dailyBySource: [String: [String: MinimaxDailyUsage]],
        calendar: Calendar
    ) -> [MinimaxDailyUsage] {
        DailyUsageAggregation.computeGlobalDaily(from: dailyBySource, calendar: calendar)
    }

    /// 保留最近 7 个本地自然日（含 today），并补齐缺失的日期，使其恒定返回 7 天。
    /// 跟 AntigravityLocalUsageScanner.filterLast7Days 同构（坑 21 / 22）。
    nonisolated static func filterLast7Days(
        allDaily: [MinimaxDailyUsage],
        today: Date,
        calendar: Calendar
    ) -> [MinimaxDailyUsage] {
        DailyUsageAggregation.filterLast7Days(allDaily: allDaily, today: today, calendar: calendar)
    }

    nonisolated static func todayCutoff(now: Date, calendar: Calendar) -> Date {
        DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
    }

}

// MARK: - LocalUsageScanner 协议

// LocalUsageScanner conformance（lastResultPublisher / isScanningPublisher）
// 由 LocalUsageScannerBase 提供。
