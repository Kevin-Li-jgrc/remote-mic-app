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
}
