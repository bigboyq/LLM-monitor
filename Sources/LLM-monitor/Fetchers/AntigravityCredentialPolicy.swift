import Foundation

/// agy CLI 单次刷新（`agy models`）的结果。stdout / stderr 内容一律不落日志、
/// 不进错误文案——只保留归类结论。
enum AntigravityAgyRunOutcome: Equatable, Sendable {
    /// 进程退出码 0：agy 已用其内嵌 client + keychain refresh_token 换新
    /// access_token 并写回 keychain。
    case success
    /// 非零退出 / 传输失败。`reloginRequired` = 输出含 `invalid_grant` 类 OAuth
    /// 错误（refresh_token 已失效）→ 用户提示「请重新登录 Antigravity」。
    case failure(reloginRequired: Bool)
}

/// agy 运行器注入 seam（仅测试替换）：执行 `agy models`。生产实现自带 30s
/// 超时；取消用 CancellationError 表达（原样上抛，不落退避），其余失败归入
/// `.failure`。实现不得把子进程输出写入日志。
typealias AntigravityAgyRunner = @Sendable (_ executablePath: String) async throws -> AntigravityAgyRunOutcome

/// agy 可执行查找注入 seam（仅测试替换）：在 PATH 与 `~/.local/bin` 里定位
/// `agy`；找不到返回 nil。
typealias AntigravityAgyLocator = @Sendable () -> String?

/// agy CLI 生产实现：可执行查找 + `agy models` 运行（30s 超时、输出不落日志）。
///
/// 为什么用 agy：keychain 条目 `gemini/antigravity` 只在登录 / agy 使用时被写回
/// （IDE 运行期间刷新的 token 只在其内存），keychain 会陈旧；运行官方 CLI 的
/// 认证流会用其内嵌 client + keychain refresh_token 换新 access_token 并写回
/// keychain（用户手工实测成功）。监控侧只触发这一流程，**不**解析
/// refresh_token、不做任何网络刷新、不回写 keychain。
///
/// 本 enum 的两个入口是**纯实现**（可注入参数、可测试）；测试进程护栏放在
/// `AntigravityCredentialPolicy` 的默认 seam 闭包里（与 `AntigravityKeychain`
/// 同款哲学）：xctest 进程内 locator 恒 nil、runner 恒失败——漏注入 seam 的
/// 测试绝不触达真实文件系统探测或子进程。
enum AntigravityAgyCLI {
    /// `agy models` 的超时上限（秒）。
    static let refreshTimeoutSeconds: TimeInterval = 30

    /// PATH（进程环境）+ `~/.local/bin` 逐目录找可执行的 `agy`，首个命中返回。
    static func locateExecutable(
        pathEnvironment: String,
        homeDirectory: String,
        fileExists: (String) -> Bool
    ) -> String? {
        var directories = pathEnvironment.split(separator: ":").map(String.init)
        directories.append(homeDirectory + "/.local/bin")
        for directory in directories where !directory.isEmpty {
            let candidate = directory.hasSuffix("/") ? directory + "agy" : directory + "/agy"
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// 运行 `agy models` 触发认证流。`ProcessRunner.run` 是同步阻塞实现
    /// （Thread.sleep 轮询 + 超时终止），不能占住协作线程池——经 detached task
    /// 落到全局并发队列执行。stdout / stderr 只用于 `invalid_grant` 归类，
    /// 内容一律不落日志。
    static func runModels(executablePath: String) async throws -> AntigravityAgyRunOutcome {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            do {
                let result = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: executablePath),
                    arguments: ["models"],
                    timeout: Self.refreshTimeoutSeconds
                )
                if result.terminationStatus == 0 {
                    return AntigravityAgyRunOutcome.success
                }
                let combined = (result.standardOutput + "\n" + result.standardError).lowercased()
                return AntigravityAgyRunOutcome.failure(
                    reloginRequired: combined.contains("invalid_grant")
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 超时 / 进程无法启动等传输层失败：按普通失败退避，不做 relogin 归类。
                return AntigravityAgyRunOutcome.failure(reloginRequired: false)
            }
        }
        // detached task 不继承父任务取消；显式转发，令 ProcessRunner 的轮询
        // 终止本轮子进程。返回边界再次检查，避免退出与取消同时发生时继续读钥匙串。
        return try await withTaskCancellationHandler {
            let outcome = try await worker.value
            try Task.checkCancellation()
            return outcome
        } onCancel: {
            worker.cancel()
        }
    }

    /// 默认 agy 查找 seam（带测试进程护栏）。
    static func locateExecutableForProduction() -> String? {
        if AntigravityKeychain.isRunningInTestProcess { return nil }
        return locateExecutable(
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "",
            homeDirectory: NSHomeDirectory(),
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// 默认 agy 运行 seam（带测试进程护栏）。
    static func runModelsForProduction(executablePath: String) async throws -> AntigravityAgyRunOutcome {
        if AntigravityKeychain.isRunningInTestProcess {
            return .failure(reloginRequired: false)
        }
        return try await runModels(executablePath: executablePath)
    }
}

/// Antigravity 凭据策略的进程级共享状态（2.5.0）。
///
/// fetcher 是按需构造的轻量 struct（每轮刷新都新建），而三样东西必须**跨刷新
/// 存活**：启动预检结果（会话内记忆）、内存 token 缓存（省钥匙串访问）、agy
/// 刷新退避。它们都住在这里；`AntigravityFetcher` 每次构造都持有同一实例
/// （默认 `shared`，测试注入独立实例）。
///
/// 线程模型：状态用 `NSLock` 短临界区保护（预检 / 缓存 / 退避读写都是微秒级）；
/// agy 子进程运行在锁外，由 `AsyncMutex` 互斥（30s 的进程等待不占状态锁）。
final class AntigravityCredentialPolicy: @unchecked Sendable {
    /// 启动预检结果（monitor 启动 + config 热重载各执行一次，记忆到本会话）。
    ///
    /// - `keychainAccessDenied`: 系统授权被拒/钥匙串不可读 → 自动 disable
    ///   `accessTokenFallback`（运行时生效，不改用户 json）；UI 显示
    ///   off + disabled + 原因「钥匙串访问被拒」。
    /// - `keychainEntryMissing`: 条目不存在（未登录）→ **软不可用不 disable**
    ///   （登录后 keychain 可读即自动恢复），路径标记不可用。
    /// - `agyCLIMissing`: `which agy`（PATH + `~/.local/bin/agy`）找不到 →
    ///   自动 disable `allowTokenRefresh`；UI 原因「未找到 agy CLI」。
    ///
    /// 预检失败自动 disable 后，若原因消除（agy 安装了 / 钥匙串授权了），由
    /// 用户手动重开开关或重启 monitor 触发重新预检恢复；不做后台自动复活。
    struct Preflight: Equatable, Sendable {
        var keychainAccessDenied = false
        var keychainEntryMissing = false
        var agyCLIMissing = false
    }

    /// 进程级共享实例（`LLMMonitorApp.makeDescriptors` 的 makeFetcher 闭包只
    /// 拿得到 ProviderConfig，跨刷新状态必须住进程级单例）。
    static let shared = AntigravityCredentialPolicy()

    private let lock = NSLock()
    private var preflightState = Preflight()
    /// 内存 token 缓存：读到的 keychain access_token 存进程内存，未过期时下一拍
    /// 直接用（省钥匙串访问）；keychain 重读在内存过期/缺失时发生。
    private var cachedCredential: AntigravityCredential?
    /// agy 刷新失败的退避截止时刻（退避一个刷新周期，期间步骤 5 直接落提示）。
    private var backoffUntil: Date?

    private let credentialReader: @Sendable () -> AntigravityCredential?
    private let keychainOutcomeReader: @Sendable () -> AntigravityKeychain.KeychainReadOutcome
    private let agyLocator: AntigravityAgyLocator
    private let agyRunner: AntigravityAgyRunner
    private let clock: @Sendable () -> Date
    /// 同一时刻只跑一个 `agy models`（手动刷新与排期刷新并发到达时串行）。
    private let agyMutex = AsyncMutex()

    init(
        credentialReader: @escaping @Sendable () -> AntigravityCredential? = {
            AntigravityKeychain.readCredential()
        },
        keychainOutcomeReader: @escaping @Sendable () -> AntigravityKeychain.KeychainReadOutcome = {
            AntigravityKeychain.readOutcome()
        },
        agyLocator: @escaping AntigravityAgyLocator = {
            AntigravityAgyCLI.locateExecutableForProduction()
        },
        agyRunner: @escaping AntigravityAgyRunner = {
            try await AntigravityAgyCLI.runModelsForProduction(executablePath: $0)
        },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialReader = credentialReader
        self.keychainOutcomeReader = keychainOutcomeReader
        self.agyLocator = agyLocator
        self.agyRunner = agyRunner
        self.clock = clock
    }

    // MARK: - 启动预检

    /// monitor 启动与 config 热重载时各执行一次（结果记忆到本会话）。开关关闭
    /// 的路径不做任何探测；整个方法**替换**上次预检结果（重载后开关翻转会
    /// 得到全新结论，例如 ② 被自动 disable 后用户重开开关 → 重新预检恢复）。
    func runPreflight(accessTokenFallbackOn: Bool, autoRefreshOn: Bool) {
        var result = Preflight()
        if accessTokenFallbackOn {
            switch keychainOutcomeReader() {
            case .readable(let rawValue):
                // 预检读到的凭据顺手播种内存缓存，省掉下一拍的钥匙串访问。
                if let credential = AntigravityCredential.parse(keychainValue: rawValue) {
                    lock.lock()
                    cachedCredential = credential
                    lock.unlock()
                }
            case .accessDenied:
                result.keychainAccessDenied = true
            case .entryMissing:
                result.keychainEntryMissing = true
            }
        }
        if autoRefreshOn, agyLocator() == nil {
            result.agyCLIMissing = true
        }
        lock.lock()
        preflightState = result
        lock.unlock()
        logInfo(
            "[antigravity] 凭据策略预检：keychainAccessDenied=\(result.keychainAccessDenied), "
                + "keychainEntryMissing=\(result.keychainEntryMissing), agyCLIMissing=\(result.agyCLIMissing)"
        )
    }

    var preflightSnapshot: Preflight {
        lock.lock()
        defer { lock.unlock() }
        return preflightState
    }

    // MARK: - 开关生效态（预检自动 disable 只作用于运行时，不改用户 json）

    /// `accessTokenFallback` 是否生效：config 开启且预检未因钥匙串授权被拒而
    /// 自动 disable。条目缺失（未登录）是软不可用——开关保持生效，由决策树
    /// 的「读不到凭据」自然落到下一分支。
    func isAccessTokenFallbackActive(configEnabled: Bool) -> Bool {
        configEnabled && !preflightSnapshot.keychainAccessDenied
    }

    /// `allowTokenRefresh`（autoRefresh）是否生效：config 开启且预检未因找不到
    /// agy CLI 而自动 disable。预检通过但运行期 `agy models` 失败**不** disable
    /// ——退避重试。
    func isAutoRefreshActive(configEnabled: Bool) -> Bool {
        configEnabled && !preflightSnapshot.agyCLIMissing
    }

    // MARK: - 内存 token 缓存

    /// 只读内存缓存（绝不触发钥匙串访问）；过期/缺失返回 nil。本地 RPC 路径
    /// 的邮箱兜底用这个入口——ls 可用时额度数据来自 bridge 新凭据，不值得为
    /// 邮箱付一次钥匙串访问。
    func memoryCachedFreshCredential() -> AntigravityCredential? {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = cachedCredential, !credential.isExpired(now: clock()) else { return nil }
        return credential
    }

    /// 远端路径的凭据：缓存优先；内存过期/缺失时重读 keychain 并回填缓存。
    func currentCredentialForRemote() -> AntigravityCredential? {
        if let fresh = memoryCachedFreshCredential() { return fresh }
        let credential = credentialReader()
        if let credential {
            lock.lock()
            cachedCredential = credential
            lock.unlock()
        }
        return credential
    }

    /// agy 刷新成功后的强制重读（绕过内存缓存）并回填——agy 刚把新 token 写回
    /// keychain，内存里的旧值必然过期。
    func credentialAfterAgyRefresh() -> AntigravityCredential? {
        let credential = credentialReader()
        if let credential {
            lock.lock()
            cachedCredential = credential
            lock.unlock()
        }
        return credential
    }

    // MARK: - 退避

    /// 上次 agy 刷新失败后是否仍在退避期内（退避一个刷新周期）。
    func isBackedOff() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = backoffUntil else { return false }
        return clock() < until
    }

    func startBackoff(intervalSeconds: TimeInterval) {
        lock.lock()
        backoffUntil = clock().addingTimeInterval(intervalSeconds)
        lock.unlock()
        logInfo("[antigravity] agy 刷新退避 \(Int(intervalSeconds))s")
    }

    // MARK: - agy 刷新（互斥）

    /// 步骤 5：运行 `agy models`（生产 30s 超时、AsyncMutex 互斥、输出不落日志）。
    /// 仅在 autoRefresh 生效且未退避时由 fetcher 调用；locator 为 nil 的极端
    /// 情形（预检后 CLI 被移除）按普通失败返回，不 disable。
    func runAgyRefresh() async throws -> AntigravityAgyRunOutcome {
        try Task.checkCancellation()
        guard let executable = agyLocator() else {
            logWarn("[antigravity] 未找到 agy 可执行文件，无法代理刷新")
            return .failure(reloginRequired: false)
        }
        return try await agyMutex.withLock {
            logInfo("[antigravity] 运行 agy models 刷新 keychain 凭据（互斥，超时 30s，输出不落日志）")
            let outcome = try await agyRunner(executable)
            try Task.checkCancellation()
            switch outcome {
            case .success:
                logInfo("[antigravity] agy models 完成：成功")
            case .failure(let reloginRequired):
                logWarn("[antigravity] agy models 失败（reloginRequired=\(reloginRequired)，输出不落日志）")
            }
            return outcome
        }
    }
}
