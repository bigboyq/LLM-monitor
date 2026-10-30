import SwiftUI
import AppKit

extension SettingsView {
    func intervalSliderField(label: String, value: Binding<Int>) -> some View {
        SettingsControlRow(label, alignment: .top) {
            VStack(alignment: .trailing, spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(value.wrappedValue) },
                        set: { value.wrappedValue = roundedProviderInterval(from: $0) }
                    ),
                    in: 0...3600,
                    label: { EmptyView() },
                    minimumValueLabel: {
                        Text("继承 (0 秒)").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                    },
                    maximumValueLabel: {
                        Text("1 小时").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                    }
                )

                Text(value.wrappedValue == 0
                     ? "当前：继承全局（\(Formatters.formatInterval(seconds: draft.globalInterval))）"
                     : "当前：\(Formatters.formatInterval(seconds: value.wrappedValue))")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
            }
            .frame(width: SettingsLayout.standardControlWidth)
        }
        .padding(.vertical, 4)
    }

    /// 通用掩码输入框（SecureField + 显示开关），用于 Device Key 等推送凭证。
    func secretField(text: Binding<String>, isVisible: Binding<Bool>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if isVisible.wrappedValue {
                    TextField("", text: text, prompt: Text(prompt))
                } else {
                    SecureField("", text: text, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(isVisible.wrappedValue ? "隐藏" : "显示")
        }
        .frame(width: SettingsLayout.standardControlWidth, alignment: .leading)
    }

    func apiKeyField(text: Binding<String>, isVisible: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if isVisible.wrappedValue {
                        TextField("", text: text, prompt: Text("sk-cp-..."))
                    } else {
                        SecureField("", text: text, prompt: Text("sk-cp-..."))
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(isVisible.wrappedValue ? "隐藏 API Key" : "显示 API Key")
            }
            // Q8: 检测误粘贴 'Bearer ' 前缀，给非阻断 soft warning；不阻止保存，
            // 不记录 key 到日志。未来 key 格式变化不会被这条规则阻止。
            if Self.hasBearerPrefix(text.wrappedValue) {
                Label("API Key 通常不需要 “Bearer ” 前缀，将按原值保存。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("若你是从 Authorization 头里复制的，去掉 “Bearer ” 前缀只保留 Key 本体通常更合适。")
            }
        }
        .frame(width: SettingsLayout.standardControlWidth, alignment: .leading)
    }

    /// Q8: 判断是否误粘贴了 `Bearer ` 前缀（不记录 key，仅布尔判定）。
    static func hasBearerPrefix(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bearer ")
    }

    func selectAuthFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            draft.chatgptAuthPath = tildePath(for: url.path)
        }
    }

    func trimmedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func roundedInterval(from value: Double) -> Int {
        let rounded = Int((value / 10).rounded() * 10)
        return min(3600, max(10, rounded))
    }

    func roundedProviderInterval(from value: Double) -> Int {
        let rounded = Int((value / 10).rounded() * 10)
        return min(3600, max(0, rounded))
    }

    func tildePath(for path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homePrefix) {
            return "~/" + String(path.dropFirst(homePrefix.count))
        }
        return path
    }
}
