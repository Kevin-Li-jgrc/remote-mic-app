import AppKit
import Foundation
import Testing
@testable import RemoteMic

struct DeepSeekSessionNavigationTests {
    @Test func navigationFocusWaitsForConfirmedSelectionAndRequiresTheSameApp() throws {
        let action = try #require(ButtonAction(rawValue: "nextDeepSeekSession"))
        var callback: ((pid_t) -> Void)?
        var requested: [DeepSeekSessionDirection] = []
        var focused = 0
        var currentBundle = "com.deepseek.dsh"
        let handled = KeyboardInjector.send(action,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Example.app") },
            applicationFocuser: { _, app, pid, _ in
                #expect(app == .deepSeekHarness)
                #expect(pid == 4242)
                focused += 1
            }, frontmostApplication: { (currentBundle, 4242) },
            sessionNavigator: { direction, completion in requested.append(direction); callback = completion },
            accessibilityTrusted: { true })
        #expect(handled)
        #expect(requested == [.next])
        #expect(focused == 0)
        let confirm = try #require(callback)
        confirm(1111)
        #expect(focused == 0)
        confirm(4242)
        #expect(focused == 1)
        currentBundle = "com.apple.finder"
        confirm(4242)
        #expect(focused == 1)
        #expect(!action.allowsRepeat)
        #expect(!KeyboardInjector.send(action, sessionNavigator: { _, _ in Issue.record("Permission-denied navigation must not start") }, accessibilityTrusted: { false }))
    }

    @Test func crossesEmptyWorkspacesAndStopsAtBothEdges() {
        #expect(DeepSeekSessionNavigation.destination(counts: [2, 0, 3], selected: .init(workspace: 0, session: 1), direction: .next) == .init(workspace: 2, session: 0))
        #expect(DeepSeekSessionNavigation.destination(counts: [2, 0, 3], selected: .init(workspace: 2, session: 0), direction: .previous) == .init(workspace: 0, session: 1))
        #expect(DeepSeekSessionNavigation.destination(counts: [2, 0, 3], selected: .init(workspace: 0, session: 0), direction: .previous) == nil)
        #expect(DeepSeekSessionNavigation.destination(counts: [2, 0, 3], selected: .init(workspace: 2, session: 2), direction: .next) == nil)
        #expect(DeepSeekSessionNavigation.destination(counts: [0], selected: .init(workspace: 0, session: 0), direction: .next) == nil)
    }

    @Test func expandsEveryWorkspaceAndHiddenSessionsBeforeSelecting() {
        var groups = [DeepSeekSessionNavigation.Workspace(expanded: true, selected: [true], hasMore: false),
                      .init(expanded: false, selected: [], hasMore: false),
                      .init(expanded: true, selected: [], hasMore: true)]
        var activated: DeepSeekSessionNavigation.Location?
        var time = 0.0
        let outcome = DeepSeekSessionNavigation.run(direction: .next,
            surface: .init(snapshot: { groups }, expandWorkspace: { index in
                groups[index].expanded = true
                return true
            }, expandMore: { index in
                groups[index].hasMore = false
                groups[index].selected = [false, false]
                return true
            }, select: { location in
                activated = location
                groups[0].selected = [false]
                groups[location.workspace].selected[location.session] = true
                return true
            }), valid: { true }, now: { time }, wait: { time += 0.05 })
        #expect(outcome == .selected(.init(workspace: 2, session: 0)))
        #expect(activated == .init(workspace: 2, session: 0))
        #expect(groups.allSatisfy { $0.expanded })
        #expect(!groups[2].hasMore)
    }

    @Test func unconfirmedExpansionAndSelectionCannotReportSuccess() {
        var time = 0.0
        var selections = 0
        let surface = DeepSeekSessionNavigation.Surface(
            snapshot: { [.init(expanded: false, selected: [true, false], hasMore: false)] },
            expandWorkspace: { _ in true }, expandMore: { _ in true },
            select: { _ in selections += 1; return true })
        let result = DeepSeekSessionNavigation.run(direction: .next, surface: surface,
            valid: { true }, now: { time }, wait: { time += 0.05 })
        #expect(result == .failed("expansion_unconfirmed"))
        #expect(selections == 0)
        time = 0
        let unchanged = DeepSeekSessionNavigation.Surface(
            snapshot: { [.init(expanded: true, selected: [true, false], hasMore: false)] },
            expandWorkspace: { _ in false }, expandMore: { _ in false }, select: { _ in true })
        #expect(DeepSeekSessionNavigation.run(direction: .next, surface: unchanged,
            valid: { true }, now: { time }, wait: { time += 0.05 }) == .failed("selection_unconfirmed"))
    }

    @Test func contextChangeDuringSnapshotCannotExpandAnOldWindow() {
        var valid = true
        var expanded = false
        let surface = DeepSeekSessionNavigation.Surface(snapshot: {
            valid = false
            return [.init(expanded: false, selected: [], hasMore: false)]
        }, expandWorkspace: { _ in expanded = true; return true }, expandMore: { _ in false }, select: { _ in false })
        let result = DeepSeekSessionNavigation.run(direction: .next, surface: surface, valid: { valid })
        #expect(result == .cancelled)
        #expect(!expanded)
    }

    @Test func appSwitchDuringExpansionCancelsBeforeSelectingAnything() {
        var time = 0.0
        var valid = true
        var activated = false
        var groups = [DeepSeekSessionNavigation.Workspace(expanded: false, selected: [true, false], hasMore: false)]
        let surface = DeepSeekSessionNavigation.Surface(snapshot: { groups }, expandWorkspace: { index in
            groups[index].expanded = true; return true
        }, expandMore: { _ in false }, select: { _ in activated = true; return true })
        let result = DeepSeekSessionNavigation.run(direction: .next, surface: surface,
            valid: { valid }, now: { time }, wait: { time += 0.05; valid = false })
        #expect(result == .cancelled)
        #expect(!activated)
    }

    @Test func invalidContextAndAmbiguousSelectionNeverActivateARow() {
        var activated = false
        let surface = DeepSeekSessionNavigation.Surface(
            snapshot: { [.init(expanded: true, selected: [true, true], hasMore: false)] },
            expandWorkspace: { _ in false }, expandMore: { _ in false },
            select: { _ in activated = true; return true })
        #expect(DeepSeekSessionNavigation.run(direction: .next, surface: surface, valid: { false }) == .cancelled)
        #expect(DeepSeekSessionNavigation.run(direction: .next, surface: surface, valid: { true }) == .failed("selection_ambiguous"))
        #expect(!activated)
    }
}
