import Foundation

/// 主线程延时调度工具集：统一收敛 UI 交互中的防抖（Debounce）与节流（Throttle）语义。
///
/// ## 为什么需要明确区分调度语义
///
/// UI 交互中极易误将所有延时任务都写成“有新事件就 cancel 并重新排期”（纯 Debounce）。
/// 当上游存在高频事件流（如触控板连续 mouseMoved）或轮询巡检（如 0.08s 的 capturePollTimer）时，
/// 若轮询间隔小于延时时间，纯 Debounce 会导致正在等待的 WorkItem 被无限取消重排，
/// 任务永远无法到期执行（**防抖饿死 / Starvation**）。
///
/// 本模块将四种核心调度语义明确建模为类型：
/// 1. `FixedDeadlineTask`：固定截止时间节流（防饿死）。一旦排期，倒计时期间的重复调用被忽略，到期必执行。
/// 2. `KeyedScheduledTask<Key>`：带目标键的固定截止调度。相同 Key 保持原倒计时防饿死，目标切换时立即重置。
/// 3. `DebouncedTask`：经典静默防抖。每次调用推迟截止时间，直到完全静默指定时长后才执行一次。
/// 4. `LadderScheduledTask`：多阶梯重试调度。给定一系列时间间隔，在每个时间点依次执行 action，重排时取消之前全部阶梯。

// MARK: - FixedDeadlineTask

/// 固定截止时间任务调度器（Throttle / Fixed Deadline）
///
/// 语义：从首次触发算起，最迟在 `delay` 秒后必须执行一次。
/// 在倒计时进行期间，后续传入的相同调度请求直接忽略；任务到期执行或显式 `cancel()` 后复位。
///
/// 典型场景：
/// - 悬浮窗鼠标离开后 0.5s 延时收起（巡检定时器每 80ms 报一次离开，必须固定 deadline 才能收起）
/// - 鼠标离开圆环落入空白处时 0.20s 延时收起详情浮层
@MainActor
final class FixedDeadlineTask {
    private var workItem: DispatchWorkItem?

    /// 当前是否正有任务挂起等待执行
    var isPending: Bool {
        workItem != nil
    }

    /// 排期任务：若当前已有挂起任务，保持原有倒计时继续推进（忽略本次调用）；若无任务则开启新倒计时。
    func schedule(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        guard workItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workItem = nil
                action()
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 取消当前挂起的任务并复位
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - KeyedScheduledTask

/// 带目标键的固定截止调度器（Keyed Fixed Deadline / Target-aware Throttle）
///
/// 语义：针对具体目标（Key）的延时展开/激活。
/// - **Key 未变**：保持原倒计时继续推进，绝不防抖重排（防止高频巡检或鼠标颤抖导致饿死）；
/// - **Key 改变**：立即取消上一个目标的任务，并为新目标重新开启延时倒计时（保证换行响应迅速）。
///
/// 典型场景：
/// - 悬浮窗 Provider 圆环 hover 延时 0.15s 展开详情（停在同一个圆环时不饿死，扫过不同圆环时换行重新计时）
/// - 菜单数据行 hover 延时 0.3s~0.5s 展开浮层（同一行内微动不重置倒计时，移到下一行立即重新计时）
@MainActor
final class KeyedScheduledTask<Key: Equatable> {
    private var workItem: DispatchWorkItem?
    private(set) var pendingKey: Key?

    /// 当前是否正有任务挂起等待执行
    var isPending: Bool {
        workItem != nil
    }

    /// 排期目标任务
    /// - Parameters:
    ///   - key: 目标标识（如行下标、UUID 等）
    ///   - delay: 延时触发时间（秒）
    ///   - action: 到期执行的闭包
    func schedule(key: Key, delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        // 同一 Key 且任务挂起中：保持原 deadline 推进，防高频轮询防抖饿死
        if pendingKey == key, workItem != nil {
            return
        }
        cancel()
        pendingKey = key
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingKey == key else { return }
                self.workItem = nil
                self.pendingKey = nil
                action()
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 取消当前挂起的目标任务并复位
    func cancel() {
        workItem?.cancel()
        workItem = nil
        pendingKey = nil
    }
}

// MARK: - DebouncedTask

/// 经典静默防抖调度器（Trailing Debounce）
///
/// 语义：每次调用都取消上一次挂起的任务并重新开始计时。只有在连续静默达到 `delay` 秒后才执行一次。
///
/// 典型场景：
/// - 用户键盘输入搜索框、文本编辑完成后的延时落盘
/// - 窗口尺寸调整过程中的重绘合并
@MainActor
final class DebouncedTask {
    private var workItem: DispatchWorkItem?

    /// 当前是否正有任务挂起等待执行
    var isPending: Bool {
        workItem != nil
    }

    /// 排期防抖任务：取消先前的倒计时，重新开启 `delay` 秒的静默倒计时
    func schedule(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workItem = nil
                action()
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 取消当前挂起的任务并复位
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - LadderScheduledTask

/// 阶梯重试调度器（Ladder / Multi-delay Retries）
///
/// 语义：给定一系列递增延迟阶梯（如 `[0.25, 0.6, 1.1, 1.8, 2.8]`），在每个时间点依次执行 action。
/// 重新 schedule 时取消之前所有未执行的阶梯。
///
/// 典型场景：
/// - Space 切换后随窗口动画过渡过程的阶梯式补测（如全屏状态探测）
@MainActor
final class LadderScheduledTask {
    private(set) var workItems: [DispatchWorkItem] = []

    var isPending: Bool {
        !workItems.isEmpty
    }

    /// 排期阶梯任务：取消先前的所有阶梯，为新的延迟数组生成任务并挂起
    func schedule(ladder: [TimeInterval], action: @escaping @MainActor () -> Void) {
        cancel()
        workItems = ladder.map { delay in
            let item = DispatchWorkItem {
                MainActor.assumeIsolated {
                    action()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    /// 取消当前挂起的所有阶梯并清空
    func cancel() {
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
    }
}
