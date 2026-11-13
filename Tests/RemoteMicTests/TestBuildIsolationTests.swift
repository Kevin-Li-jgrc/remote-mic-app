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
}
