import Foundation

/// 从 MiniMax Code 的 session 目录里读出**真实模型名**。
///
/// 为什么必须有它：runtime 的 token 账本（`local_runtime_token_usage.model`）
/// 与 session 投影（`local_runtime_sessions.record_json.effectiveModel`）写的
/// 都是**泛化标签** `minimax/MiniMax-M3`；2026-08-15 的 schema migration 之后，
/// 账本行的 `model` 列干脆是 NULL。真实模型只写在 session 目录的
/// `llm-call.json` 里（`model` + `provider` 字段）。
///
/// 不读它的后果：扫描窗口（今天 + 前 7 天）内**全部**用量行的 `model` 都是
/// NULL，session 投影也可能是空，于是整批用量都会落到回退链最后那档
/// `minimax/MiniMax-M3` 上 —— M3.1 Flash 被归到 M3 名下。模型名错，
/// 定价也跟着错（M3.1 Flash 与 M3 不同价）。
///
/// 读不到时（目录已被清理 / 文件缺失 / JSON 坏了）返回 nil，由调用方退回
/// 原有回退链；**读不到不等于猜**。
final class MinimaxSessionModelResolver {
    /// session 目录根（`~/.minimax/v2/sessions`）。
    let sessionsRoot: URL

    /// 每个 session 目录只读一次：同一 session 的所有 token 行共用一个模型。
    /// 区分"没读到"与"读到空"——`unavailable` 是缓存结论，不是缓存缺失。
    private var cache: [String: Entry] = [:]

    private enum Entry {
        case resolved(String)
        case unavailable
    }

    init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    /// session 相对目录（`local_runtime_sessions.history_relative_dir`）
    /// → 真实模型名。
    func modelName(forRelativeDir relativeDir: String) -> String? {
        guard !relativeDir.isEmpty else { return nil }
        switch cache[relativeDir] {
        case .resolved(let name)?:
            return name
        case .unavailable?:
            return nil
        default:
            break
        }
        let resolved = Self.readModelName(sessionsRoot: sessionsRoot, relativeDir: relativeDir)
        if let resolved {
            cache[relativeDir] = .resolved(resolved)
            return resolved
        }
        cache[relativeDir] = .unavailable
        return nil
    }

    /// 读 `<sessionsRoot>/<relativeDir>/llm-call.json` 的 `model` 字段。
    ///
    /// 该文件是 session 的 LLM 调用配置（api / model / provider / maxTokens /
    /// systemPrompt），体积不小（百 KB 级，内嵌 system prompt），所以**按 session
    /// 缓存**，不让同一 session 的几十上百行 token 各自去解析一次。
    private static func readModelName(sessionsRoot: URL, relativeDir: String) -> String? {
        let url = sessionsRoot
            .appendingPathComponent(relativeDir, isDirectory: true)
            .appendingPathComponent("llm-call.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let raw = dict["model"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
