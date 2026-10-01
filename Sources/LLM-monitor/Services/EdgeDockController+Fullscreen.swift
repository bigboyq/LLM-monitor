import AppKit

/// 边缘状态窗的全屏门控：从 `EdgeDockController` 拆出。
///
/// 判定本体在 `FullscreenProbe`；这里只管"判定变了要不要重排窗口"，以及窗口
/// 进出场动画期间按阶梯补测（动画中读到的判据是中间态）。
extension EdgeDockController {
    // MARK: - 全屏门控

    /// 全屏是否**应该**让 dock 消失。探测结果（`isFullscreenSpace`）是事实，
    /// 策略本身在 `EdgeDockConfig.hidesInFullscreen` 上（可单测）。
    ///
    /// 单独拎出来而不是在四个 guard 里各写一次：多写一次不会编译报错，只会让
    /// 某一处（比如 popover 的显示判断）漏掉这个开关，表现是"dock 在全屏里还
    /// 开着、点开详情却什么都没有"。
    var isHiddenByFullscreen: Bool {
        config.hidesInFullscreen(isFullscreenSpace: isFullscreenSpace)
    }

    /// Space 切换后**阶梯式**补测全屏，各档延迟。
    ///
    /// 单次补测不够，因为"进/出全屏"和"滑动 Space"是两种时长完全不同的过渡：
    ///
    /// - 滑动 Space：瞬时，0.25s 后就稳定了
    /// - 进/出全屏：约 1s 的窗口动画。0.25s 时窗口还在**长大**，`covers()`
    ///   读到的中间态盖不满整屏 → 判成"没全屏"
    ///
    /// 而 `evaluateFullscreen` 对"值没变"是直接 return 的，也就是**一次读错就被
    /// 永久缓存**，直到下一次无关事件才可能纠正。这正是实测症状的成因：
    /// 浏览器刚进全屏时 dock 留着（0.25s 读到动画中间态），等关掉另一个全屏
    /// 窗口再滑回来反而正常（滑动没有动画，0.25s 足够）。
    ///
    /// 阶梯覆盖到 2.8s，够任何真实过渡走完。重复执行无害——判定本身幂等，
    /// 只有真正翻转时才 reconcile。成本是每次 Space 切换多 5 次窗口列表读取。
    private static let fullscreenRetryLadder: [TimeInterval] = [0.25, 0.6, 1.1, 1.8, 2.8]

    func scheduleFullscreenRechecks() {
        cancelFullscreenRechecks()
        fullscreenRetryWorkItems = Self.fullscreenRetryLadder.map { delay in
            let work = DispatchWorkItem { [weak self] in
                self?.evaluateFullscreen()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    func cancelFullscreenRechecks() {
        fullscreenRetryWorkItems.forEach { $0.cancel() }
        fullscreenRetryWorkItems.removeAll()
    }

    func evaluateFullscreen() {
        guard config.mode.isVisible else {
            isFullscreenSpace = false
            reconcile(animated: false)
            return
        }
        // fail-open：探测失败返回 false，窗口照常显示。
        //
        // 判据问的是"当前 Space 上有没有铺满整屏的窗口"，不是"前台 App 有没有"——
        // 滑动 Space 不触发 App 激活，按前台过滤会漏判出非前台 App 的全屏 Space。
        let fullscreen = FullscreenProbe.isAnyFullscreenWindow(
            on: Self.targetScreen,
            excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        guard fullscreen != isFullscreenSpace else { return }
        isFullscreenSpace = fullscreen
        logInfo(fullscreen
            ? (config.hideInFullscreen
                ? "EdgeDock: 检测到全屏，隐藏"
                : "EdgeDock: 检测到全屏（已关闭全屏隐藏，继续显示）")
            : "EdgeDock: 退出全屏，恢复显示")
        reconcile(animated: false)
    }
}
