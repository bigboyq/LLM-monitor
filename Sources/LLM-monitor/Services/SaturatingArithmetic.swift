/// 非负计数使用的饱和算术。
///
/// Token、turn、round 等计数在业务上不应为负。为避免损坏或不可信输入把聚合结果
/// 变成负数，所有入口都会把负值安全归零；正数加法溢出时返回 `Int.max`。
/// 该类型没有共享可变状态，可安全地跨并发任务使用。
enum SaturatingArithmetic: Sendable {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let lhs = max(0, lhs)
        let rhs = max(0, rhs)
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? Int.max : result
    }

    static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let lhs = max(0, lhs)
        let rhs = max(0, rhs)
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? Int64.max : result
    }

    /// 饱和减法，下溢归零。用于从"含 cache 的 input"推算 uncached input
    /// （`input_raw - cacheRead`）等场景，避免 db 取整误差产生负值。
    static func subtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let lhs = max(0, lhs)
        let rhs = max(0, rhs)
        let (result, overflowed) = lhs.subtractingReportingOverflow(rhs)
        return overflowed ? 0 : result
    }

    static func sum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0, add)
    }

    static func sum(_ values: Int...) -> Int {
        sum(values)
    }

    static func sum<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        values.reduce(0, add)
    }

    static func sum(_ values: Int64...) -> Int64 {
        sum(values)
    }
}
