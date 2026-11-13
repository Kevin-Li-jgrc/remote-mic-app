import Foundation
import SayAllMCPKit
import Testing

struct IsolatedMCPPathsTests {
    @Test func standaloneHelperResolvesIsolationFromItsOwnEnclosingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("SayAll.app")
        let contents = app.appendingPathComponent("Contents")
        let helpers = contents.appendingPathComponent("Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.kevin.sayall.app-switching-test",
            "CFBundlePackageType": "APPL", "SayAllIsolatedTestBuild": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let paths = SayAllMCPPaths.defaults(executableURL: helpers.appendingPathComponent("SayAllMCP"))
        #expect(paths.transcriptRoot.path.contains("/SayAllAppSwitchingTest/RemoteMic/"))
        #expect(paths.accessRoot.path.contains("/SayAllAppSwitchingTest/RemoteMic/"))
        let ordinary = SayAllMCPPaths.defaults(executableURL: root.appendingPathComponent("SayAllMCP"))
        #expect(!ordinary.transcriptRoot.path.contains("SayAllAppSwitchingTest"))
    }
}
