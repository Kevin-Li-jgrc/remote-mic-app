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

    struct CreationSurface {
        var currentWorkspace: () -> Int?
        var begin: (Int) -> Bool
        var confirmedSelection: (Int) -> Location?
        var revealCurrentWorkspace: () -> Bool = { false }
    }

    static func runCreation(surface: CreationSurface, valid: () -> Bool,
                            now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            wait: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) -> Outcome {
        let deadline = now() + 5
        guard valid() else { return .cancelled }
        var capturedWorkspace: Int?
        for _ in 0..<128 {
            guard valid() else { return .cancelled }
            guard now() < deadline else { return .failed("timeout") }
            capturedWorkspace = surface.currentWorkspace()
            if capturedWorkspace != nil { break }
            guard valid() else { return .cancelled }
            guard now() < deadline else { return .failed("timeout") }
            guard surface.revealCurrentWorkspace() else { return .failed("workspace_unavailable") }
            wait()
        }
        guard let workspace = capturedWorkspace else { return .failed("workspace_unavailable") }
        guard valid() else { return .cancelled }
        guard now() < deadline else { return .failed("timeout") }
        guard surface.begin(workspace) else { return .failed("creation_unavailable") }
        while now() < deadline {
            guard valid() else { return .cancelled }
            let selected = surface.confirmedSelection(workspace)
            guard valid() else { return .cancelled }
            guard now() < deadline else { return .failed("creation_unconfirmed") }
            if let selected, selected.workspace == workspace { return .selected(selected) }
            wait()
        }
        return .failed("creation_unconfirmed")
    }

    static func requestCreation(completion: @escaping (pid_t) -> Void) {
        request(direction: nil, completion: completion)
    }

    private static let queue = DispatchQueue(label: "SayAll.deepseek-session-navigation")
    private static let lock = NSLock()
    private static var busy = false

    static func request(_ direction: DeepSeekSessionDirection, completion: @escaping (pid_t) -> Void) {
        request(direction: direction, completion: completion)
    }

    private static func request(direction: DeepSeekSessionDirection?, completion: @escaping (pid_t) -> Void) {
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
        let action = direction?.rawValue ?? "create"
        let scope = direction == nil ? "current_workspace" : "all_workspaces"
        AppLogger.shared.write("\(prefix) phase=requested direction=\(action) scope=\(scope)")
        queue.async {
            defer { lock.lock(); busy = false; lock.unlock() }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == AppMappingTarget.deepSeek.bundleIdentifier else {
                AppLogger.shared.write("\(prefix) phase=completed result=cancelled reason=target_changed"); return
            }
            let pid = app.processIdentifier
            let adapter = DeepSeekSessionAccessibility(processIdentifier: pid, lifetime: direction == nil ? 6 : 4)
            let valid = {
                AXIsProcessTrusted() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && adapter.isCurrentWindow
            }
            guard adapter.prepare(valid: valid) else {
                AppLogger.shared.write("\(prefix) phase=completed result=failed reason=sidebar_unavailable"); return
            }
            let outcome = direction.map { run(direction: $0, surface: adapter.surface, valid: valid) } ??
                runCreation(surface: adapter.creationSurface, valid: valid)
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
    private let expires: TimeInterval
    private var creationWorkspace: (index: Int, name: String, header: AXUIElement, rows: [AXUIElement])?
    private var groups: [Group] = []
    init(processIdentifier: pid_t, lifetime: TimeInterval = 4) {
        expires = ProcessInfo.processInfo.systemUptime + lifetime
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
    var creationSurface: DeepSeekSessionNavigation.CreationSurface {
        .init(currentWorkspace: { self.captureCreationWorkspace() },
              begin: { self.beginCreation($0) }, confirmedSelection: { self.confirmCreation($0) },
              revealCurrentWorkspace: { self.revealCreationWorkspace() })
    }

    private func labelIs(_ element: AXUIElement, _ labels: [String]) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute].contains { attributeName in
            guard let value = attribute(element, attributeName as CFString) as? String else { return false }
            return labels.contains { value.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    private func workspaceName(_ header: AXUIElement) -> String? {
        // The header's aggregate description can include hover-only controls. Use its visible label.
        guard let label = children(header).first(where: { role($0) == kAXStaticTextRole as String }) else { return nil }
        return attribute(label, kAXValueAttribute as CFString) as? String ??
            attribute(label, kAXTitleAttribute as CFString) as? String
    }

    private func captureCreationWorkspace() -> Int? {
        guard let values = snapshot() else { return nil }
        let selected = values.enumerated().flatMap { workspace, value in
            value.selected.enumerated().compactMap { $0.element ? (workspace, $0.offset) : nil }
        }
        guard selected.count == 1, let index = selected.first?.0, !values[index].hasMore,
              let name = workspaceName(groups[index].header), !name.isEmpty,
              groups.filter({ workspaceName($0.header) == name }).count == 1 else { return nil }
        creationWorkspace = (index, name, groups[index].header, groups[index].rows)
        return index
    }

    private func revealCreationWorkspace() -> Bool {
        guard let values = snapshot(), let index = values.firstIndex(where: { !$0.expanded || $0.hasMore }) else { return false }
        let header = groups[index].header
        let opening = !values[index].expanded
        guard canMutate else { return false }
        let accepted = opening ? expand(index) : groups[index].more.map(press) == true
        guard accepted else { return false }
        for _ in 0..<60 {
            guard canMutate, let updated = snapshot(), updated.count == values.count,
                  CFEqual(groups[index].header, header) else { return false }
            if opening ? updated[index].expanded : !updated[index].hasMore { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func beginCreation(_ index: Int) -> Bool {
        guard let captured = creationWorkspace, captured.index == index,
              let values = snapshot(), values.indices.contains(index),
              CFEqual(groups[index].header, captured.header),
              values[index].selected.contains(true),
              let create = find({ role($0) == kAXButtonRole as String &&
                  labelIs($0, ["新建会话", "New session", "New chat"]) }), canMutate,
              press(create) else { return false }
        // New session opens an empty page. Explicitly choose the captured workspace through its public picker.
        guard let picker = awaitElement({ role($0) == kAXPopUpButtonRole as String &&
            labelIs($0, ["选择工作区", "Select workspace", "Choose workspace"]) }), press(picker),
              let option = awaitElement({ role($0) == kAXMenuItemRole as String && labelIs($0, [captured.name]) }),
              press(option) else { return false }
        return true
    }

    private func awaitElement(_ matches: (AXUIElement) -> Bool) -> AXUIElement? {
        for _ in 0..<60 {
            guard canMutate else { return nil }
            if let element = find(matches) { return element }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func confirmCreation(_ index: Int) -> DeepSeekSessionNavigation.Location? {
        guard let captured = creationWorkspace, captured.index == index,
              let values = snapshot(), values.indices.contains(index),
              CFEqual(groups[index].header, captured.header), workspaceName(groups[index].header) == captured.name else { return nil }
        let selected = values.enumerated().flatMap { workspace, value in
            value.selected.enumerated().compactMap { $0.element ? DeepSeekSessionNavigation.Location(workspace: workspace, session: $0.offset) : nil }
        }
        guard selected.count == 1, let current = selected.first, current.workspace == index,
              !captured.rows.contains(where: { CFEqual($0, groups[index].rows[current.session]) }) else { return nil }
        return current
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
