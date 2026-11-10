import SwiftUI

/// Shared provider-card selector for choosing a provider quota pool in the menu bar.
struct StatusBarQuotaSelector: View {
    let selectedSource: StatusBarQuotaSource?
    let options: [StatusBarQuotaOption]
    var iconSize: CGFloat = 11
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 3
    let onToggle: () -> Void
    let onSelect: (StatusBarQuotaSource) -> Void

    private var isSelected: Bool { selectedSource != nil }

    private var helpText: String {
        guard let selectedSource else {
            return "在状态栏显示该 Provider 主套餐；如需锁定单个 Plan、API Key 或活动套餐，请点额度标题旁的眼睛"
        }
        let title = options.first { $0.source == selectedSource }?.title ?? selectedSource.fallbackTitle
        return "状态栏显示：\(title)；点击取消，点额度标题旁的眼睛可锁定单个额度"
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isSelected ? "eye.fill" : "eye.slash")
                .font(.system(size: iconSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primaryLabel : Color.secondaryLabel.opacity(0.6))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    isSelected ? Color.primary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .contextMenu {
            ForEach(options) { option in
                Button {
                    onSelect(option.source)
                } label: {
                    Label(
                        option.title,
                        systemImage: selectedSource == option.source
                            ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        }
    }
}

/// Visible one-click pin for a specific Plan/API/entitlement row.
struct StatusBarQuotaSourcePinButton: View {
    let isSelected: Bool
    let title: String
    let action: () -> Void

    private var helpText: String {
        isSelected ? "状态栏当前显示：\(title)" : "在状态栏显示：\(title)"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "eye.fill" : "eye")
                .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primaryLabel : Color.secondaryLabel.opacity(0.75))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}
