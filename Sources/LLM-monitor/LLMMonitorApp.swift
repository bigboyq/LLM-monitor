import SwiftUI
import AppKit
import Darwin

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                logInfo("AppLifecycleDelegate: 系统唤醒，触发 provider 刷新")
                await appState.refreshAll()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}

@main
struct LLMMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var appDelegate: AppLifecycleDelegate

    @StateObject private var configStore: ConfigStore
    @StateObject private var state: AppState
    @StateObject private var loginItemService: LoginItemService

    private let instanceLock: AppInstanceLock
    private let rightClickHandler = MenuBarRightClickHandler()

    init() {
        let instanceLock: AppInstanceLock
        switch AppInstanceLock.acquireDefault() {
        case .acquired(let lock):
            instanceLock = lock
        case .alreadyRunning:
            logWarn("LLMMonitorApp: 已有实例运行，当前实例退出")
            let alert = NSAlert()
            alert.messageText = "LLM Monitor 已在运行"
            alert.informativeText = "已有一个 LLM Monitor 实例在使用当前用户数据。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(EXIT_SUCCESS)
        case .failed(let error):
            logError("LLMMonitorApp: 单实例锁初始化失败: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "LLM Monitor 无法启动"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        self.instanceLock = instanceLock

        logInfo("========== LLM Monitor @main init ==========")
        let configStore = ConfigStore()
        let loginItemService = LoginItemService()
        let descriptors = Self.makeDescriptors()
        logInfo("@main: 已注册 \(descriptors.count) 个 provider")
        // 自动补全 config.json 缺失 of provider 段（不覆盖已有）
        configStore.ensureProvidersPresent(descriptors: descriptors)
        
        let state = AppState(descriptors: descriptors, configStore: configStore)
        _configStore = StateObject(wrappedValue: configStore)
        _state = StateObject(wrappedValue: state)
        _loginItemService = StateObject(wrappedValue: loginItemService)

        appDelegate.appState = state
        rightClickHandler.setup(state: state)
        logInfo("@main: AppState 启动完成")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state, loginItemService: loginItemService)
        } label: {
            MenuBarLabel(state: state, configStore: configStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                configStore: configStore,
                loginItemService: loginItemService,
                state: state,
                descriptors: state.descriptors
            )
        }
    }

    // MARK: - provider 注册表

    static func makeDescriptors() -> [FetcherDescriptor] {
        [
            FetcherDescriptor(
                id: ProviderKind.minimaxTokenPlan.providerID,
                displayName: "minimax Token Plan",
                kind: .minimaxTokenPlan,
                iconSystemName: "bubble.left.and.text.bubble.right.fill",
                accentColor: .minimax,
                makeFetcher: { config in
                    MinimaxTokenPlanFetcher(apiKey: config.usableAPIKey ?? "")
                },
                settingsTabTitle: "minimax",
                settingsTabSubtitle: "Token Plan 的 API Key 与独立刷新频率"
            ),
            FetcherDescriptor(
                id: ProviderKind.codexChatGpt.providerID,
                displayName: "ChatGPT Plan",
                kind: .codexChatGpt,
                iconSystemName: "sparkles",
                accentColor: .chatgpt,
                makeFetcher: { config in CodexFetcher(authPath: config.authPath) },
                settingsTabTitle: "ChatGPT",
                settingsTabSubtitle: "本地 Codex 登录信息与刷新频率"
            ),
            FetcherDescriptor(
                id: ProviderKind.antigravity.providerID,
                displayName: "Google Antigravity",
                kind: .antigravity,
                iconSystemName: "paperplane.circle.fill",
                accentColor: .antigravity,
                makeFetcher: { _ in AntigravityFetcher() },
                settingsTabTitle: "Antigravity",
                settingsTabSubtitle: "复用本地 Antigravity / agy CLI 登录态"
            ),
            FetcherDescriptor(
                id: ProviderKind.glmCodingPlan.providerID,
                displayName: "GLM Coding Plan",
                kind: .glmCodingPlan,
                iconSystemName: "chevron.left.forwardslash.chevron.right",
                accentColor: .glm,
                makeFetcher: { config in
                    GlmCodingPlanFetcher(apiKey: config.usableAPIKey ?? "")
                },
                settingsTabTitle: "GLM",
                settingsTabSubtitle: "智谱 GLM Coding Plan 的 API Key 与刷新频率"
            ),
            FetcherDescriptor(
                id: ProviderKind.deepseek.providerID,
                displayName: "DeepSeek",
                kind: .deepseek,
                iconSystemName: "creditcard.fill",
                accentColor: .deepseek,
                makeFetcher: { config in
                    DeepseekFetcher(apiKey: config.usableAPIKey ?? "")
                },
                settingsTabTitle: "DeepSeek",
                settingsTabSubtitle: "DeepSeek API Key 与余额查询刷新频率"
            ),
        ]
    }
}
