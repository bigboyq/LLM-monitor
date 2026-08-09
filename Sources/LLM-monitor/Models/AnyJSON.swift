import Foundation

/// 弱类型 JSON 值，专给"schema 不公开或字段名会变"的端点用。
///
/// Antigravity 的 `GetCascadeTrajectoryGeneratorMetadata` 响应里 token 字段
/// 嵌套很深 + 字段名版本会变（`inputTokens` / `input_tokens` / `promptTokens`
/// 都在历史上出现过），所以走"按 key 名正则递归分类"的策略，而不是定义
/// 一个固定的 Decodable struct。
indirect enum AnyJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    static func == (lhs: AnyJSON, rhs: AnyJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }
}

extension AnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyJSON].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyJSON].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyJSON: unsupported value"
            )
        }
    }
}

extension AnyJSON: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .number(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }
}

extension AnyJSON {
    /// 有限、在 `Int` 范围内且没有小数部分的 number / string → Int。
    ///
    /// 不能直接调用 `Int(Double)`：超出范围或 NaN/Infinity 会触发运行时 trap。
    /// 这个类型用于解析本地 RPC 的弱类型、不可信响应，因此转换失败必须返回 nil。
    var intValue: Int? {
        switch self {
        case .number(let n):
            guard n.isFinite,
                  n.rounded(.towardZero) == n,
                  n >= Double(Int.min),
                  n < Double(Int.max) else {
                return nil
            }
            return Int(n)
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s):
            guard let value = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
                  value.isFinite else {
                return nil
            }
            return value
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        default: return nil
        }
    }
}
