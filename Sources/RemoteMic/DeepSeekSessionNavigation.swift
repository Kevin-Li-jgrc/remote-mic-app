import AppKit
import ApplicationServices
import Foundation

enum DeepSeekSessionDirection: String { case previous, next }

enum DeepSeekSessionNavigation {
    struct Location: Equatable { let workspace: Int; let session: Int }
    struct Workspace: Equatable {
        var expanded: Bool
        var selected: [Bool]
        var hasMore: Bool
    }
    struct Surface {
        var snapshot: () -> [Workspace]?
        var expandWorkspace: (Int) -> Bool
        var expandMore: (Int) -> Bool
        var select: (Location) -> Bool
    }
    enum Outcome: Equatable {
        case selected(Location), boundary, cancelled, failed(String)
    }

    static func destination(counts: [Int], selected: Location, direction: DeepSeekSessionDirection) -> Location? {
        guard counts.allSatisfy({ $0 >= 0 }), counts.indices.contains(selected.workspace),
              (0..<counts[selected.workspace]).contains(selected.session) else { return nil }
        let positions = counts.enumerated().flatMap { workspace, count in
            (0..<count).map { Location(workspace: workspace, session: $0) }
        }
        guard let index = positions.firstIndex(of: selected) else { return nil }
        let next = index + (direction == .next ? 1 : -1)
        return positions.indices.contains(next) ? positions[next] : nil
    }

    private static func selections(_ groups: [Workspace]) -> [Location] {
        groups.enumerated().flatMap { workspace, group in
            group.selected.enumerated().compactMap { $0.element ? Location(workspace: workspace, session: $0.offset) : nil }
        }
    }

    static func run(direction: DeepSeekSessionDirection, surface: Surface, valid: () -> Bool,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    wait: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) -> Outcome {
        let deadline = now() + 3
        var originalSelection: Location?
        var originalWorkspaceCount: Int?
        for _ in 0..<128 {
            guard valid() else { return .cancelled }
            guard now() < deadline else { return .failed("timeout") }
            guard let groups = surface.snapshot(), !groups.isEmpty, groups.count <= 128,
                  groups.reduce(0, { $0 + $1.selected.count }) <= 4000 else { return .failed("sidebar_unavailable") }
            if let count = originalWorkspaceCount, count != groups.count { return .failed("sidebar_changed") }
            originalWorkspaceCount = groups.count
            let selected = selections(groups)
            guard selected.count <= 1 else { return .failed("selection_ambiguous") }
            if let originalSelection, let current = selected.first, current != originalSelection { return .cancelled }
            if originalSelection == nil { originalSelection = selected.first }
            if let index = groups.firstIndex(where: { !$0.expanded || $0.hasMore }) {
                guard valid() else { return .cancelled }
                guard now() < deadline else { return .failed("timeout") }
                let opening = !groups[index].expanded
                let accepted = opening ? surface.expandWorkspace(index) : surface.expandMore(index)
                guard accepted else { return .failed("expansion_unavailable") }
                var confirmed = false
                while now() < deadline {
                    guard valid() else { return .cancelled }
                    wait()
                    guard let updated = surface.snapshot(), updated.count == groups.count else { return .failed("sidebar_changed") }
                    if opening ? updated[index].expanded : !updated[index].hasMore {
                        confirmed = true; break
                    }
                }
                guard confirmed else { return .failed("expansion_unconfirmed") }
                continue
            }
            guard let current = selected.first else { return .failed("selection_missing") }
            guard let target = destination(counts: groups.map { $0.selected.count }, selected: current, direction: direction)
            else { return .boundary }
            guard valid() else { return .cancelled }
            guard now() < deadline else { return .failed("timeout") }
            guard surface.select(target) else { return .failed("selection_unavailable") }
            while now() < deadline {
                guard valid() else { return .cancelled }
                wait()
                guard let updated = surface.snapshot() else { return .failed("sidebar_unavailable") }
                if selections(updated) == [target] { return .selected(target) }
            }
            return .failed("selection_unconfirmed")
        }
        return .failed("expansion_limit")
    }

    private static let queue = DispatchQueue(label: "SayAll.deepseek-session-navigation")
    private static let lock = NSLock()
    private static var busy = false

    static func request(_ direction: DeepSeekSessionDirection, completion: @escaping (pid_t) -> Void) {
        let operation = UUID().uuidString
        let prefix = "SESSION NAV operation_id=\(operation)"
        lock.lock()
        guard !busy else {
            lock.unlock()
            AppLogger.shared.write("\(prefix) phase=completed result=ignored reason=busy")
            return
        }
        busy = true
        lock.unlock()
        AppLogger.shared.write("\(prefix) phase=requested direction=\(direction.rawValue) scope=all_workspaces")
        queue.async {
            defer { lock.lock(); busy = false; lock.unlock() }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == AppMappingTarget.deepSeek.bundleIdentifier else {
                AppLogger.shared.write("\(prefix) phase=completed result=cancelled reason=target_changed"); return
            }
            let pid = app.processIdentifier
            let adapter = DeepSeekSessionAccessibility(processIdentifier: pid)
            let valid = {
                AXIsProcessTrusted() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && adapter.isCurrentWindow
            }
            guard adapter.prepare(valid: valid) else {
                AppLogger.shared.write("\(prefix) phase=completed result=failed reason=sidebar_unavailable"); return
            }
            let outcome = run(direction: direction, surface: adapter.surface, valid: valid)
            switch outcome {
            case .selected:
                guard valid() else {
                    AppLogger.shared.write("\(prefix) phase=completed result=cancelled reason=target_changed"); return
                }
                completion(pid)
                AppLogger.shared.write("\(prefix) phase=completed result=selection_confirmed focus=requested focus_result=unknown")
            case .boundary:
                AppLogger.shared.write("\(prefix) phase=completed result=unchanged reason=boundary")
            case .cancelled:
                AppLogger.shared.write("\(prefix) phase=completed result=cancelled reason=context_changed")
            case .failed(let reason):
                AppLogger.shared.write("\(prefix) phase=completed result=failed reason=\(reason)")
            }
        }
    }
}

/// Reads only the public accessibility sidebar. Session names and contents are never logged.
private final class DeepSeekSessionAccessibility {
    private struct Group { let header: AXUIElement; let rows: [AXUIElement]; let more: AXUIElement? }
    private let processIdentifier: pid_t
    private let application: AXUIElement
    private let window: AXUIElement?
    private let expires = ProcessInfo.processInfo.systemUptime + 4
    private var groups: [Group] = []
    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = (value as! AXUIElement)
        } else { window = nil }
    }
    var isCurrentWindow: Bool {
        guard let window else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success &&
            value.map { CFEqual(window, $0) } == true
    }

    private var canMutate: Bool {
        AXIsProcessTrusted() && ProcessInfo.processInfo.systemUptime < expires &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier && isCurrentWindow
    }

    var surface: DeepSeekSessionNavigation.Surface {
        .init(snapshot: { self.snapshot() }, expandWorkspace: { self.expand($0) },
              expandMore: { self.groups.indices.contains($0) && self.groups[$0].more.map(self.press) == true },
              select: { location in
                  guard self.groups.indices.contains(location.workspace),
                        self.groups[location.workspace].rows.indices.contains(location.session) else { return false }
                  return self.press(self.groups[location.workspace].rows[location.session])
              })
    }
    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < expires else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] }
    private func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute as CFString) as? String ?? "" }
    private func text(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].compactMap { attribute(element, $0 as CFString) as? String }.joined(separator: " ")
    }
    private func bool(_ element: AXUIElement, _ name: CFString) -> Bool? { (attribute(element, name) as? NSNumber)?.boolValue }
    private func press(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              (names as? [String])?.contains(kAXPressAction as String) == true else { return false }
        guard canMutate else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    private func find(_ matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard let window else { return nil }
        var pending = [window]
        var index = 0
        while index < pending.count && index < 3000 && ProcessInfo.processInfo.systemUptime < expires {
            let node = pending[index]; index += 1
            if matches(node) { return node }
            pending.append(contentsOf: children(node))
        }
        return nil
    }
    private func outline() -> AXUIElement? {
        find { node in
            guard role(node) == kAXOutlineRole as String else { return false }
            let name = text(node).lowercased()
            return name.contains("会话") || name.contains("session") || name.contains("conversation")
        }
    }
    func prepare(valid: () -> Bool) -> Bool {
        guard valid() else { return false }
        if outline() != nil { return true }
        guard let toggle = find({ node in
            guard role(node) == kAXButtonRole as String else { return false }
            let label = text(node).lowercased()
            return label.contains("打开侧边栏") || label.contains("open sidebar") || label.contains("show sidebar")
        }), valid(), press(toggle) else { return false }
        for _ in 0..<20 {
            guard valid() else { return false }
            if outline() != nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
    private func hasActiveSearch() -> Bool {
        guard let field = find({ node in
            guard role(node) == kAXTextFieldRole as String else { return false }
            let label = text(node).lowercased()
            return label.contains("搜索会话名称") || label.contains("search sessions") || label.contains("search conversations")
        }) else { return false }
        return !(attribute(field, kAXValueAttribute as CFString) as? String ?? "").isEmpty
    }

    private func snapshot() -> [DeepSeekSessionNavigation.Workspace]? {
        guard !hasActiveSearch(), let tree = outline() else { return nil }
        var next: [Group] = []
        var values: [DeepSeekSessionNavigation.Workspace] = []
        for child in children(tree) {
            let directRow = role(child) == kAXRowRole as String
            let entries = directRow ? [child] : children(child)
            let rows = entries.filter { role($0) == kAXRowRole as String }
            guard let header = rows.first else { return nil }
            let sessions = Array(rows.dropFirst())
            let buttons = entries.filter { role($0) == kAXButtonRole as String }
            let more = buttons.first {
                let label = text($0).lowercased()
                return label.contains("展开其余") ||
                    ((label.contains("show") || label.contains("more")) && (label.contains("session") || label.contains("conversation")))
            }
            // Unknown direct controls could hide more sessions. Fail rather than claim a complete list.
            guard buttons.allSatisfy({ element in
                if let more, CFEqual(element, more) { return true }
                let label = text(element).lowercased()
                return label.contains("收起") || label.contains("collapse")
            }) else { return nil }
            let expanded = bool(header, kAXDisclosingAttribute as CFString) ??
                bool(header, kAXExpandedAttribute as CFString) ?? !directRow
            next.append(.init(header: header, rows: sessions, more: more))
            values.append(.init(expanded: expanded, selected: sessions.map { bool($0, kAXSelectedAttribute as CFString) == true }, hasMore: more != nil))
        }
        groups = next
        return values
    }
    private func expand(_ index: Int) -> Bool {
        guard groups.indices.contains(index) else { return false }
        let header = groups[index].header
        for name in [kAXDisclosingAttribute, kAXExpandedAttribute] {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(header, name as CFString, &settable) == .success, settable.boolValue, canMutate,
               AXUIElementSetAttributeValue(header, name as CFString, kCFBooleanTrue) == .success { return true }
        }
        return press(header)
    }
}
