import AppKit
import Foundation

enum AppMappingTarget: String, Codable, CaseIterable, Identifiable {
    case codex
    case deepSeek
    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "DeepSeek Harness" }
    var bundleIdentifier: String { self == .codex ? "com.openai.codex" : "com.deepseek.dsh" }
}

enum AppMappingSlot: String, Codable, CaseIterable, Identifiable {
    case previousChat, nextChat, newChat, attention, review
    var id: String { rawValue }
    var button: RemoteButton {
        switch self {
        case .previousChat: return .left
        case .nextChat: return .right
        case .newChat: return .home
        case .attention, .review: return .menu
        }
    }
    var trigger: ButtonTrigger {
        self == .newChat || self == .review ? .longPress : .singleClick
    }
    var titleKey: String {
        switch self {
        case .previousChat: return "app_mapping.slot.previous_chat"
        case .nextChat: return "app_mapping.slot.next_chat"
        case .newChat: return "app_mapping.slot.new_chat"
        case .attention: return "app_mapping.slot.attention"
        case .review: return "app_mapping.slot.review"
        }
    }
}

/// Public, local-only app matching. No private Plus component or third-party data is used.
struct AppSpecificMappings: Codable, Equatable {
    var enabled = false
    private var shortcuts: [String: CustomKeyboardShortcut] = [:]
    private var disabledSlots: Set<String> = []

    func shortcut(target: AppMappingTarget, slot: AppMappingSlot) -> CustomKeyboardShortcut? {
        let key = "\(target.rawValue).\(slot.rawValue)"
        if disabledSlots.contains(key) { return nil }
        if let saved = shortcuts[key] { return saved }
        guard target == .codex else { return nil }
        switch slot {
        case .previousChat: return .init(keyCode: 123, modifierFlags: [.command, .option], keyLabel: "←")
        case .nextChat: return .init(keyCode: 124, modifierFlags: [.command, .option], keyLabel: "→")
        case .newChat: return .init(keyCode: 45, modifierFlags: .command, keyLabel: "N")
        case .attention: return .init(keyCode: 0, modifierFlags: [.command, .option], keyLabel: "A")
        case .review: return .init(keyCode: 5, modifierFlags: [.control, .shift], keyLabel: "G")
        }
    }

    func binding(target: AppMappingTarget, slot: AppMappingSlot) -> ConfiguredButtonAction {
        if let shortcut = shortcut(target: target, slot: slot) {
            return .init(action: .customShortcut, shortcut: shortcut)
        }
        if target == .deepSeek, !disabledSlots.contains("\(target.rawValue).\(slot.rawValue)") {
            if slot == .previousChat { return .init(action: .previousDeepSeekSession, shortcut: nil) }
            if slot == .nextChat { return .init(action: .nextDeepSeekSession, shortcut: nil) }
            if slot == .newChat { return .init(action: .newDeepSeekSession, shortcut: nil) }
        }
        return .disabled
    }

    mutating func setShortcut(_ shortcut: CustomKeyboardShortcut?, target: AppMappingTarget, slot: AppMappingSlot) {
        let key = "\(target.rawValue).\(slot.rawValue)"
        shortcuts[key] = shortcut
        if shortcut == nil { disabledSlots.insert(key) } else { disabledSlots.remove(key) }
    }

    func resolve(bundleIdentifier: String?, button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction? {
        guard enabled else { return nil }
        if button == .menu, trigger == .doubleClick {
            return ConfiguredButtonAction(
                action: bundleIdentifier == AppMappingTarget.deepSeek.bundleIdentifier
                    ? .openCodex : .openDeepSeekHarness,
                shortcut: nil)
        }
        if button == .tv {
            switch trigger {
            case .singleClick:
                return ConfiguredButtonAction(action: .customShortcut,
                    shortcut: .init(keyCode: 48, modifierFlags: [], keyLabel: "Tab"))
            case .longPress:
                return ConfiguredButtonAction(action: .escape, shortcut: nil)
            case .doubleClick:
                return ConfiguredButtonAction(action: .disabled, shortcut: nil)
            }
        }
        guard let target = AppMappingTarget.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        if let slot = AppMappingSlot.allCases.first(where: { $0.button == button && $0.trigger == trigger }) {
            return binding(target: target, slot: slot)
        }
        guard trigger == .singleClick else { return ConfiguredButtonAction(action: .disabled, shortcut: nil) }
        let action: ButtonAction
        switch button {
        case .up: action = .scrollUp
        case .down: action = .scrollDown
        case .ok: action = .returnKey
        case .back: action = .deleteBackward
        case .home: action = target == .codex ? .openCodex : .focusInput
        case .volumeUp: action = .volumeUp
        case .volumeDown: action = .volumeDown
        default: action = .disabled
        }
        return ConfiguredButtonAction(action: action, shortcut: nil)
    }
}
