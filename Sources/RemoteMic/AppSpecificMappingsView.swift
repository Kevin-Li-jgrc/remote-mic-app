import AppKit
import SwiftUI

struct AppSpecificMappingsView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore
    @State private var target: AppMappingTarget = .codex
    @State private var editingSlot: AppMappingSlot?
    @State private var currentBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("app_mapping.title").font(.system(size: 18, weight: .semibold))
            Toggle("app_mapping.enabled", isOn: $settings.appSpecificMappings.enabled)
                .font(.system(size: 14))
            Text("app_mapping.description").font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(localization.text("app_mapping.current") + "：" + currentTargetName)
                .font(.system(size: 13, weight: .medium))
            Text("app_mapping.tv").font(.system(size: 13, weight: .medium))
            Text("app_mapping.switch").font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Picker("app_mapping.target", selection: $target) {
                ForEach(AppMappingTarget.allCases) { item in
                    Text(item.name).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: target) { _ in editingSlot = nil }
            if target == .deepSeek {
                Text("app_mapping.deepseek_pending").font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AppMappingSlot.allCases) { slot in
                HStack(spacing: 12) {
                    Text(localization.text(slot.titleKey)).font(.system(size: 13))
                    Spacer()
                    Text(bindingName(slot))
                        .font(.system(size: 13, weight: .medium))
                    Button("app_mapping.edit") { editingSlot = editingSlot == slot ? nil : slot }
                    Button("app_mapping.clear") {
                        settings.appSpecificMappings.setShortcut(nil, target: target, slot: slot)
                    }
                }
            }
            if let slot = editingSlot {
                Divider()
                Text(localization.text(slot.titleKey)).font(.system(size: 14, weight: .semibold))
                KeyboardShortcutPicker(
                    shortcut: settings.appSpecificMappings.shortcut(target: target, slot: slot),
                    showsStandardKeyboardInitially: true
                ) { shortcut in
                    settings.appSpecificMappings.setShortcut(shortcut, target: target, slot: slot)
                    editingSlot = nil
                }
            }
            Text("app_mapping.common").font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            currentBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    private func bindingName(_ slot: AppMappingSlot) -> String {
        let binding = settings.appSpecificMappings.binding(target: target, slot: slot)
        if let shortcut = binding.shortcut { return shortcut.displayName(using: localization) }
        if binding.action == .newDeepSeekSession { return localization.text("app_mapping.new_workspace_session") }
        if binding.action.deepSeekSessionDirection != nil { return localization.text("app_mapping.sidebar_navigation") }
        return localization.text("app_mapping.unset")
    }

    private var currentTargetName: String {
        guard settings.appSpecificMappings.enabled else { return localization.text("app_mapping.off") }
        return AppMappingTarget.allCases.first { $0.bundleIdentifier == currentBundleIdentifier }?.name
            ?? localization.text("app_mapping.base")
    }
}
