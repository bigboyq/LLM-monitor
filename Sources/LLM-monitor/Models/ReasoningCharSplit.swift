/// 「思考字符数 → 思考 token 数」的守恒拆分。
///
/// ## 适用场景
///
/// 三处账本都只报**一个** output 桶，账面 `reasoning_tokens` 恒 0 或缺失，但内容侧
/// 保留了真实思考文本：
/// - **ZCode 分片**（`GlmZcodeDBReader`）：`model_usage.reasoning_tokens` 对所有 provider
///   恒 0，真正的思考文本在 `part` 表（`$.type = 'reasoning'` 的 `$.text`）。
/// - **MiniMax Code runtime**（`MinimaxLocalUsageAggregation.applyReasoningSplit`）：
///   token 表无 reasoning，思考在 `session_messages.thinking_content`。
/// - **Dsh M3**（`DshLocalUsageScanner.estimateM3ReasoningTokens`）：usage 记录只有
///   raw output，思考在消息的 reasoning block 里。
///
/// 三者都按同一口径估算：思考字符数占总字符（思考 + 可见输出）的比例乘以账面
/// output，得到的部分记作 reasoning，剩下的记作 output。
enum ReasoningCharSplit {
    /// 按字符比例把 `outputTokens` 拆成 (reasoning, output)。
    ///
    /// - Returns: `(reasoning, output)`，`output` 已扣掉 reasoning，守恒
    ///   `reasoning + output == max(0, outputTokens)` 恒成立。返回 `nil` 表示
    ///   **无法估算**（账面 output <= 0 或思考字符数 <= 0），调用方保持原样。
    static func split(
        outputTokens: Int,
        reasoningChars: Int,
        visibleChars: Int
    ) -> (reasoning: Int, output: Int)? {
        let output = max(0, outputTokens)
        let reasoning = max(0, reasoningChars)
        let visible = max(0, visibleChars)
        // 没有思考字符就没法按比例分摊；output <= 0 时也无从分摊（0 / 0 比例无意义）。
        guard output > 0, reasoning > 0 else { return nil }
        // 饱和加法：字符数异常大时 total 封顶而不是溢出 trap（比例仍 < 1）。
        let total = SaturatingArithmetic.add(reasoning, visible)
        guard total > 0 else { return nil }

        let proportion = Double(reasoning) / Double(total)
        let estimate = (Double(output) * proportion).rounded()
        // Double(Int.max) 在 64-bit 平台会向上舍入到 2^63，直接转 Int 可能 trap；
        // 边界值饱和，并再 clamp 到 [0, output] 保证守恒。
        let estimatedTokens = estimate >= Double(Int.max) ? Int.max : (Int(exactly: estimate) ?? 0)
        let reasoningTokens = min(max(estimatedTokens, 0), output)
        return (reasoning: reasoningTokens, output: output - reasoningTokens)
    }
}
