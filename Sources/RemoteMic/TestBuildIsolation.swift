import Foundation

/// Opt-in artifact identity. Normal builds retain their historical paths and settings.
enum TestBuildIsolation {
    static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "com.kevin.sayall.app-switching-test" &&
            Bundle.main.object(forInfoDictionaryKey: "SayAllIsolatedTestBuild") as? Bool == true
    }

    static func directoryName(_ normal: String, isolated: Bool = isEnabled) -> String {
        isolated ? "SayAllAppSwitchingTest/\(normal)" : normal
    }

    static func preventsConcurrentRun(isolated: Bool, productionRunning: Bool) -> Bool {
        isolated && productionRunning
    }
    /// Seed only missing values in the isolated app's preferences. Existing saved choices always win.
    static func seedDefaults(in defaults: UserDefaults = .standard, isolated: Bool = isEnabled) {
        guard isolated else { return }
        var mappings = AppSpecificMappings()
        mappings.enabled = true
        var actions: [String: ButtonAction] = [:]
        var shortcuts: [String: CustomKeyboardShortcut] = [:]
        var secondary: [String: [String: ConfiguredButtonAction]] = [:]
        for button in RemoteButton.allCases {
            for trigger in ButtonTrigger.allCases {
                guard let binding = mappings.resolve(bundleIdentifier: "com.openai.codex",
                    button: button, trigger: trigger) else { continue }
                if trigger == .singleClick {
                    actions[button.rawValue] = binding.action
                    shortcuts[button.rawValue] = binding.shortcut
                } else {
                    secondary[button.rawValue, default: [:]][trigger.rawValue] = binding
                }
            }
        }
        let encoder = JSONEncoder()
        guard let actionData = try? encoder.encode(actions),
              let shortcutData = try? encoder.encode(shortcuts),
              let secondaryData = try? encoder.encode(secondary),
              let mappingData = try? encoder.encode(mappings) else { return }
        let values = ["buttonBindings": actionData, "buttonShortcuts": shortcutData,
            "secondaryButtonBindings": secondaryData, "appSpecificMappings.v1": mappingData]
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

}
