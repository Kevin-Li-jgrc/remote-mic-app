import AppKit
import Foundation
import Testing
@testable import RemoteMic

struct AppSpecificMappingsTests {
    @Test func disabledMappingDoesNotOverrideAnything() {
        let mappings = AppSpecificMappings()
        for target in AppMappingTarget.allCases {
            for button in RemoteButton.allCases {
                for trigger in ButtonTrigger.allCases {
                    #expect(mappings.resolve(bundleIdentifier: target.bundleIdentifier,
                        button: button, trigger: trigger) == nil)
                }
            }
        }
    }

    @Test func exactAppMatchingAndUnknownAppFallback() {
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        #expect(mappings.resolve(bundleIdentifier: "com.openai.codex", button: .left,
            trigger: .singleClick)?.shortcut?.keyCode == 123)
        #expect(mappings.resolve(bundleIdentifier: "com.openai.codex", button: .right,
            trigger: .singleClick)?.shortcut?.modifierFlags == [.command, .option])
        for identifier in [String?](arrayLiteral: nil, "com.openai.codex.fake", "com.apple.Safari") {
            #expect(mappings.resolve(bundleIdentifier: identifier, button: .left,
                trigger: .singleClick) == nil)
        }
    }

    @Test func tvIsAlwaysPlainTabIncludingUnknownApplications() {
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        for identifier in [String?](arrayLiteral: nil, "com.openai.codex", "com.deepseek.dsh", "com.apple.Safari") {
            let action = mappings.resolve(bundleIdentifier: identifier, button: .tv, trigger: .singleClick)
            #expect(action?.shortcut?.keyCode == 48)
            #expect(action?.shortcut?.modifierFlags.isEmpty == true)
            #expect(mappings.resolve(bundleIdentifier: identifier, button: .tv,
                trigger: .doubleClick)?.action == .disabled)
            #expect(mappings.resolve(bundleIdentifier: identifier, button: .tv,
                trigger: .longPress)?.action == .escape)
        }
    }

    @Test func menuDoubleSelectsTheOtherAppAndOtherAppsStartWithDeepSeek() {
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        for (identifier, expected) in [("com.openai.codex", "com.deepseek.dsh"),
                                       ("com.deepseek.dsh", "com.openai.codex"),
                                       ("com.apple.finder", "com.deepseek.dsh")] {
            let action = mappings.resolve(bundleIdentifier: identifier, button: .menu, trigger: .doubleClick)
            #expect(action?.action.presetApplication?.bundleIdentifier == expected)
            #expect(action?.allowsSingleClickRepeat == false)
        }
        #expect(mappings.resolve(bundleIdentifier: nil, button: .menu,
            trigger: .doubleClick)?.action.presetApplication?.bundleIdentifier == "com.deepseek.dsh")
        mappings.enabled = false
        #expect(mappings.resolve(bundleIdentifier: "com.openai.codex", button: .menu,
            trigger: .doubleClick) == nil)
    }

    @Test func deepSeekUnknownShortcutsAreDisabledAndEditable() {
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        for slot in [AppMappingSlot.newChat, .attention, .review] {
            #expect(mappings.resolve(bundleIdentifier: "com.deepseek.dsh", button: slot.button,
                trigger: slot.trigger)?.action == .disabled)
        }
        mappings.setShortcut(.init(keyCode: 124, modifierFlags: [.command], keyLabel: "→"),
            target: .deepSeek, slot: .nextChat)
        #expect(mappings.resolve(bundleIdentifier: "com.deepseek.dsh", button: .right,
            trigger: .singleClick)?.shortcut?.modifierFlags == .command)
        #expect(mappings.resolve(bundleIdentifier: "com.openai.codex", button: .right,
            trigger: .singleClick)?.shortcut?.modifierFlags == [.command, .option])
    }

    @Test func deepSeekSessionNavigationDefaultsRespectCustomAndDisabledSlots() {
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        #expect(mappings.resolve(bundleIdentifier: "com.deepseek.dsh", button: .left, trigger: .singleClick)?.action.rawValue == "previousDeepSeekSession")
        #expect(mappings.resolve(bundleIdentifier: "com.deepseek.dsh", button: .right, trigger: .singleClick)?.action.rawValue == "nextDeepSeekSession")
        mappings.setShortcut(.init(keyCode: 124, modifierFlags: .command, keyLabel: "Right"), target: .deepSeek, slot: .nextChat)
        #expect(mappings.resolve(bundleIdentifier: "com.deepseek.dsh", button: .right, trigger: .singleClick)?.action == .customShortcut)
        mappings.setShortcut(nil, target: .deepSeek, slot: .previousChat)
        #expect(mappings.resolve(bundleIdentifier: "com.deepseek.dsh", button: .left, trigger: .singleClick)?.action == .disabled)
        #expect(mappings.resolve(bundleIdentifier: "com.openai.codex", button: .left, trigger: .singleClick)?.shortcut?.keyCode == 123)
    }

    @Test func commonActionsAndSecondaryGesturesDoNotLeakOldBindings() {
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        for target in AppMappingTarget.allCases {
            #expect(mappings.resolve(bundleIdentifier: target.bundleIdentifier, button: .up,
                trigger: .singleClick)?.action == .scrollUp)
            #expect(mappings.resolve(bundleIdentifier: target.bundleIdentifier, button: .ok,
                trigger: .singleClick)?.action == .returnKey)
            #expect(mappings.resolve(bundleIdentifier: target.bundleIdentifier, button: .back,
                trigger: .singleClick)?.action == .deleteBackward)
            #expect(mappings.resolve(bundleIdentifier: target.bundleIdentifier, button: .home,
                trigger: .doubleClick)?.action == .disabled)
        }
    }

    @Test func settingsResolveLiveFrontmostAppAndPersistOnlyNewKey() throws {
        let name = "AppSpecificMappingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.arrowLeft, for: .left)
        let baseData = defaults.data(forKey: "buttonBindings")
        settings.appSpecificMappings.enabled = true
        settings.frontmostBundleIdentifierProvider = { "com.deepseek.dsh" }
        #expect(settings.configuredAction(for: .left, trigger: .singleClick).action.rawValue == "previousDeepSeekSession")
        settings.frontmostBundleIdentifierProvider = { "com.openai.codex" }
        #expect(settings.configuredAction(for: .left, trigger: .singleClick).shortcut?.keyCode == 123)
        settings.frontmostBundleIdentifierProvider = { "com.apple.Safari" }
        #expect(settings.configuredAction(for: .left, trigger: .singleClick).action == .arrowLeft)
        #expect(defaults.data(forKey: "buttonBindings") == baseData)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.appSpecificMappings.enabled)
        settings.appSpecificMappings.enabled = false
        #expect(settings.configuredAction(for: .tv, trigger: .singleClick).action == .appSwitcher)
    }

    @Test func corruptConfigurationFailsClosed() throws {
        let name = "AppSpecificMappingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: "appSpecificMappings.v1")
        #expect(!AppSettings(defaults: defaults).appSpecificMappings.enabled)
    }
    @Test func automaticMappingSuppressesOldOpaqueGestures() throws {
        let name = "AppSpecificMappingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.appSpecificMappings.enabled = true
        settings.frontmostBundleIdentifierProvider = { "com.deepseek.dsh" }
        let snapshot = settings.interactionSnapshot(for: .tv, opaque: { _ in true })
        #expect(!snapshot.hasOpaqueBinding)
        #expect(!snapshot.recognizesDouble)
        #expect(snapshot.recognizesLong)
        #expect(snapshot.single.shortcut?.keyCode == 48)
    }

}
