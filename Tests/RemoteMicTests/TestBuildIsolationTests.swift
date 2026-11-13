import Foundation
import Testing
@testable import RemoteMic

struct TestBuildIsolationTests {
    @Test func testStorageDoesNotShareProductionDirectories() {
        for name in ["RemoteMic", "SayAll/Diagnostics/public-events.json"] {
            let isolated = TestBuildIsolation.directoryName(name, isolated: true)
            #expect(isolated.hasPrefix("SayAllAppSwitchingTest/"))
            #expect(isolated != name)
            #expect(TestBuildIsolation.directoryName(name, isolated: false) == name)
        }
    }
    @Test func isolatedBuildRefusesConcurrentProductionHardwareControl() {
        #expect(TestBuildIsolation.preventsConcurrentRun(isolated: true, productionRunning: true))
        #expect(!TestBuildIsolation.preventsConcurrentRun(isolated: true, productionRunning: false))
        #expect(!TestBuildIsolation.preventsConcurrentRun(isolated: false, productionRunning: true))
    }
    @Test func independentDefaultsKeepTvTabBeforeAndAfterDisablingAutomaticMatching() throws {
        let name = "TestBuildIsolationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        TestBuildIsolation.seedDefaults(in: defaults, isolated: true)
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.customMappingEnabled)
        #expect(settings.appSpecificMappings.enabled)
        #expect(settings.configuredBaseAction(for: .tv, trigger: .singleClick).shortcut?.keyCode == 48)
        #expect(settings.configuredBaseAction(for: .tv, trigger: .singleClick).shortcut?.modifierFlags.isEmpty == true)
        settings.appSpecificMappings.enabled = false
        #expect(settings.configuredAction(for: .tv, trigger: .singleClick).shortcut?.keyCode == 48)
    }

}
