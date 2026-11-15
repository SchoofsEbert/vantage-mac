import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "Pairs")

/// Keeps the windows of each `WindowPair` together, from Accessibility notifications: a resize
/// across the shared edge resizes the partner, minimizing one minimizes both, and bringing one
/// forward brings both.
///
/// Only touched on the snapper's queue, so a snap and the notifications it causes are handled
/// in order. Notifications arrive on the main thread and only hop over.
final class WindowPairs: @unchecked Sendable {
    private struct Member {
        let window: AXElement
        let app: AXElement
        let pid: pid_t
    }

    private let queue: DispatchQueue
    private var pairs: [WindowPair] = []
    private var members: [CGWindowID: Member] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    /// Windows and apps with a notification waiting: a drag sends a stream of them, and only
    /// the frames when the queue gets to it count.
    private var pendingWindows: Set<CGWindowID> = []
    private var pendingApps: Set<pid_t> = []
    /// Windows that seemed to leave their pair, to look at again.
    private var confirming: Set<CGWindowID> = []
    /// Windows Vantage just resized to follow their partner: their own notifications are
    /// echoes, and answering them would fight the drag.
    private var echoesUntil: [CGWindowID: ContinuousClock.Instant] = [:]
    /// Windows the user is dragging: they lead, and their partner never pushes back meanwhile.
    private var leadingUntil: [CGWindowID: ContinuousClock.Instant] = [:]

    // MARK: Drag
    /// The last time a partner followed. A drag ends once this has been quiet for `dragQuiet`.
    private var lastFollow: ContinuousClock.Instant?
    private var isDragQuietCheckScheduled = false
    /// Apps whose enhanced user interface is off for the drag, and whether it was on.
    private var dragApps: [pid_t: (app: AXElement, wasEnhanced: Bool)] = [:]
    /// Partners that wouldn't take the size: when the drag ends, the leader's edge goes back to
    /// meet them. Leader to partner.
    private var refused: [CGWindowID: CGWindowID] = [:]

    private static let echoWindow: Duration = .milliseconds(250)
    private static let leadWindow: Duration = .milliseconds(300)
    private static let dragQuiet: Duration = .milliseconds(300)
    private static let dragQuietDelay: DispatchTimeInterval = .milliseconds(300)
    private static let unpairDelay: DispatchTimeInterval = .milliseconds(200)
    private static let raiseRecheck: DispatchTimeInterval = .milliseconds(150)
    private static let tabSwitchDelay: DispatchTimeInterval = .milliseconds(300)

    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]
    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification]
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    /// After a partner followed, with the frame each window took, so snapping counts them as
    /// placed by Vantage.
    var onFollowed: ((CGWindowID, CGRect) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        // Apps that quit or crash don't say their windows went.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            guard let self else { return }
            queue.async {
                self.removeAll(of: pid)
            }
        }
        // Dragging a window to another Space switches to it.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async {
                self.removeSplitAcrossSpaces()
            }
        }
    }

    func pair(containing windowID: CGWindowID) -> WindowPair? {
        pairs.first { $0.contains(windowID) }
    }

    // MARK: - Pairing

    /// Pairs the window Snap Assist placed with the one snapped before, replacing any pair
    /// either was in. Nothing changes unless both windows can be watched.
    func add(_ pair: WindowPair, windows: [CGWindowID: (window: AXElement, app: AXElement, pid: pid_t)]) {
        guard let first = windows[pair.first], let second = windows[pair.second] else { return }
        for id in [pair.first, pair.second] {
            remove(containing: id)
        }
        let added = [(pair.first, first), (pair.second, second)]
        guard added.allSatisfy({ observe($0.1.window, pid: $0.1.pid, app: $0.1.app) }) else {
            for (_, member) in added {
                stopObserving(member.window, pid: member.pid, app: member.app)
            }
            logger.warning("Couldn't watch both windows, so they aren't paired.")
            return
        }
        for (id, member) in added {
            members[id] = Member(window: member.window, app: member.app, pid: member.pid)
        }
        pairs.append(pair)
        logger.debug("Paired windows \(pair.first) and \(pair.second).")
        published()
    }

    /// Ends the pair the window is in, if any.
    func remove(containing windowID: CGWindowID) {
        guard let index = pairs.firstIndex(where: { $0.contains(windowID) }) else { return }
        let pair = pairs.remove(at: index)
        for id in [pair.first, pair.second] {
            echoesUntil[id] = nil
            leadingUntil[id] = nil
            refused[id] = nil
            confirming.remove(id)
            guard let member = members.removeValue(forKey: id) else { continue }
            stopObserving(member.window, pid: member.pid, app: member.app)
        }
        logger.debug("Unpaired windows \(pair.first) and \(pair.second).")
        published()
    }

    func removeAll() {
        while let pair = pairs.first {
            remove(containing: pair.first)
        }
    }

    private func removeAll(of pid: pid_t) {
        for (id, member) in members where member.pid == pid {
            remove(containing: id)
        }
    }

    /// The partner of a window, with what it takes to move it.
    func partner(of windowID: CGWindowID) -> (id: CGWindowID, window: AXElement, app: AXElement, pair: WindowPair)? {
        guard let pair = pair(containing: windowID), let id = pair.partner(of: windowID), let member = members[id] else { return nil }
        return (id, member.window, member.app, pair)
    }

    /// After both windows of a pair went to another display together.
    func moved(_ windowID: CGWindowID, to frame: CGRect, partnerTo partnerFrame: CGRect) {
        guard let index = pairs.firstIndex(where: { $0.contains(windowID) }) else { return }
        let isFirst = pairs[index].first == windowID
        pairs[index].moved(first: isFirst ? frame : partnerFrame, second: isFirst ? partnerFrame : frame)
    }

    // MARK: - Notifications

    private func observe(_ window: AXElement, pid: pid_t, app: AXElement) -> Bool {
        let observer: AXObserver
        if let existing = observers[pid] {
            observer = existing
        } else {
            var created: AXObserver?
            guard AXObserverCreate(pid, pairNotificationCallback, &created) == .success, let created else { return false }
            observer = created
            observers[pid] = observer
            for name in Self.appNotifications {
                AXObserverAddNotification(observer, app.ref, name as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        // Destroyed is what ends a pair when a window closes: without it, no pair.
        var watchesDestroyed = false
        for name in Self.windowNotifications {
            let error = AXObserverAddNotification(observer, window.ref, name as CFString, nil)
            if name == kAXUIElementDestroyedNotification {
                watchesDestroyed = error == .success || error == .notificationAlreadyRegistered
            }
        }
        return watchesDestroyed
    }

    private func stopObserving(_ window: AXElement, pid: pid_t, app: AXElement) {
        guard let observer = observers[pid] else { return }
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(observer, window.ref, name as CFString)
        }
        guard !members.values.contains(where: { $0.pid == pid }) else { return }
        observers[pid] = nil
        for name in Self.appNotifications {
            AXObserverRemoveNotification(observer, app.ref, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// From the main thread.
    func notified(_ element: AXElement, _ name: String) {
        queue.async {
            self.handle(element, name)
        }
    }

    private func handle(_ element: AXElement, _ name: String) {
        if Self.appNotifications.contains(name) {
            guard let pid = element.pid, pendingApps.insert(pid).inserted else { return }
            queue.async {
                self.pendingApps.remove(pid)
                self.focusChanged(pid: pid)
            }
            return
        }
        guard let id = members.first(where: { $0.value.window == element })?.key else { return }
        switch name {
        case kAXUIElementDestroyedNotification:
            // A tab switched away from, or closed, goes the same way: give its tab group a
            // moment to show the next tab in its place.
            queue.asyncAfter(deadline: .now() + Self.tabSwitchDelay) {
                self.windowWent(id)
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            setMinimized(name == kAXWindowMiniaturizedNotification, partnerOf: id)
        default:
            guard pendingWindows.insert(id).inserted else { return }
            queue.async {
                self.pendingWindows.remove(id)
                self.follow(id)
            }
        }
    }

    // MARK: - Following the shared edge

    /// The partner follows the shared edge, or the pair ends.
    private func follow(_ id: CGWindowID) {
        let now = ContinuousClock.now
        if let until = echoesUntil[id], now < until { return }
        guard let member = members[id], let partner = partner(of: id) else { return }
        // The partner is being dragged: it leads, this one only follows.
        if let until = leadingUntil[partner.id], now < until { return }
        guard let frame = member.window.frame else {
            windowWent(id)
            return
        }
        guard let partnerFrame = partner.window.frame else {
            if windowWent(partner.id) {
                follow(id)
            }
            return
        }
        switch partner.pair.follow(id, to: frame, partnerFrame: partnerFrame) {
        case .keep:
            break
        case .unpair:
            confirmUnpair(id)
        case .resize(let partnerID, let target):
            let isDragStart = lastFollow.map { now - $0 > Self.dragQuiet } ?? true
            if isDragStart, endIfSplitAcrossSpaces(id, partnerID) { return }
            leadingUntil[id] = now + Self.leadWindow
            echoesUntil[partnerID] = now + Self.echoWindow
            let taken = resize(partner.window, of: partner.app, pid: members[partnerID]?.pid, to: target, from: partnerFrame)
            if let taken, !SnapLayout.isClose(taken, target) {
                refused[id] = partnerID
            } else {
                refused[id] = nil
            }
            onFollowed?(id, frame)
            onFollowed?(partnerID, taken ?? target)
            dragStepped()
        }
    }

    /// Some apps set position and size one after the other, and the frame between the two
    /// looks moved away: look again a moment later before ending the pair.
    private func confirmUnpair(_ id: CGWindowID) {
        guard confirming.insert(id).inserted else { return }
        queue.asyncAfter(deadline: .now() + Self.unpairDelay) {
            self.confirming.remove(id)
            guard let member = self.members[id], let partner = self.partner(of: id) else { return }
            guard let frame = member.window.frame, let partnerFrame = partner.window.frame,
                  partner.pair.follow(id, to: frame, partnerFrame: partnerFrame) != .unpair else {
                self.remove(containing: id)
                return
            }
            self.follow(id)
        }
    }

    /// Resizes a partner with as few calls as it takes, during a drag: only the size, and the
    /// position only when its edge toward the pair is its origin. Growing moves first, shrinking
    /// sizes first, so a screen edge never pushes it back. Returns the frame it took.
    private func resize(_ window: AXElement, of app: AXElement, pid: pid_t?, to target: CGRect, from current: CGRect) -> CGRect? {
        if let pid {
            suspendEnhancedUserInterface(of: app, pid: pid)
        }
        let movesOrigin = abs(target.minX - current.minX) > SnapLayout.tolerance || abs(target.minY - current.minY) > SnapLayout.tolerance
        let grows = target.width * target.height > current.width * current.height
        if movesOrigin, grows {
            window.setPosition(target.origin)
        }
        window.setSize(target.size)
        if movesOrigin, !grows {
            window.setPosition(target.origin)
        }
        return window.frame
    }

    /// Chrome and Electron apps animate every change while their enhanced user interface is
    /// on, and turning it back on rebuilds their whole tree: keep it off for the whole drag.
    private func suspendEnhancedUserInterface(of app: AXElement, pid: pid_t) {
        guard dragApps[pid] == nil else { return }
        let enhanced = app.attribute(Self.enhancedUserInterfaceAttribute) as? Bool == true
        if enhanced {
            app.set(Self.enhancedUserInterfaceAttribute, to: kCFBooleanFalse)
        }
        dragApps[pid] = (app, enhanced)
    }

    private func dragStepped() {
        lastFollow = .now
        guard !isDragQuietCheckScheduled else { return }
        isDragQuietCheckScheduled = true
        queue.asyncAfter(deadline: .now() + Self.dragQuietDelay) {
            self.isDragQuietCheckScheduled = false
            self.dragMayHaveEnded()
        }
    }

    /// Once no partner has followed for a moment: enhanced user interfaces back on, and a
    /// window whose partner wouldn't shrink gets its edge put back against the partner, so
    /// the two don't overlap.
    private func dragMayHaveEnded() {
        guard let lastFollow, ContinuousClock.now - lastFollow >= Self.dragQuiet else {
            dragStepped()
            return
        }
        for (_, entry) in dragApps where entry.wasEnhanced {
            entry.app.set(Self.enhancedUserInterfaceAttribute, to: kCFBooleanTrue)
        }
        dragApps = [:]
        let refused = refused
        self.refused = [:]
        for (leader, partnerID) in refused {
            guard let member = members[leader], let partner = members[partnerID], let pair = pair(containing: leader),
                  let frame = member.window.frame, let partnerFrame = partner.window.frame,
                  case .resize(leader, let target) = pair.follow(partnerID, to: partnerFrame, partnerFrame: frame) else { continue }
            echoesUntil[leader] = .now + Self.echoWindow
            let taken = WindowSnapper.move(member.window, of: member.app, to: target, action: pair.edge(of: leader), area: target)
            onFollowed?(leader, taken ?? target)
        }
    }
}

// MARK: - Acting together

extension WindowPairs {

    private func setMinimized(_ minimized: Bool, partnerOf id: CGWindowID) {
        guard let partner = partner(of: id),
              partner.window.attribute(kAXMinimizedAttribute) as? Bool != minimized else { return }
        partner.window.set(kAXMinimizedAttribute, to: minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// An app's focused window changed, or the app came forward.
    private func focusChanged(pid: pid_t) {
        guard !pairs.isEmpty else { return }
        let app = AXElement.application(pid)
        guard let focused = app.element(kAXFocusedWindowAttribute), let id = focused.windowID else { return }
        if pair(containing: id) == nil {
            adoptTab(focused, id: id, pid: pid, app: app)
        }
        bringForward(focused, id: id, pid: pid)
    }

    /// Native tabs are windows of their own: switching tabs hides the paired one and shows
    /// another in its place. That one takes over in the pair.
    private func adoptTab(_ window: AXElement, id: CGWindowID, pid: pid_t, app: AXElement) {
        let sameApp = members.filter { $0.value.pid == pid }.map(\.key)
        guard !sameApp.isEmpty else { return }
        let onScreen = WindowList.appWindows(withIDs: sameApp, onScreenOnly: true)
        guard let old = sameApp.first(where: { onScreen[$0] == nil && fitsSlot(of: $0, window) }) else { return }
        takeOver(old, by: window, id: id, app: app)
    }

    /// A paired window closed, went off screen or hid as a tab does: the app's window now in
    /// its place takes over (a tab switch sends nothing else to go by), or the pair ends.
    /// - Returns: Whether another window took over.
    @discardableResult
    private func windowWent(_ id: CGWindowID) -> Bool {
        guard let member = members[id] else { return false }
        if let focused = member.app.element(kAXFocusedWindowAttribute), let focusedID = focused.windowID,
           focusedID != id, pair(containing: focusedID) == nil, fitsSlot(of: id, focused),
           takeOver(id, by: focused, id: focusedID, app: member.app) {
            return true
        }
        remove(containing: id)
        return false
    }

    /// Whether `window` sits where the paired window `id` was, beside its partner.
    private func fitsSlot(of id: CGWindowID, _ window: AXElement) -> Bool {
        guard let partner = partner(of: id), let frame = window.frame, let partnerFrame = partner.window.frame else { return false }
        return partner.pair.follow(id, to: frame, partnerFrame: partnerFrame) != .unpair
    }

    @discardableResult
    private func takeOver(_ old: CGWindowID, by window: AXElement, id: CGWindowID, app: AXElement) -> Bool {
        guard let member = members[old], let index = pairs.firstIndex(where: { $0.contains(old) }),
              observe(window, pid: member.pid, app: app) else { return false }
        if let observer = observers[member.pid] {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, member.window.ref, name as CFString)
            }
        }
        members[old] = nil
        members[id] = Member(window: window, app: app, pid: member.pid)
        pairs[index].replace(old, with: id)
        logger.debug("Window \(id) takes over from \(old) in its pair.")
        published()
        return true
    }

    /// When a paired window comes forward, its partner comes too, unless nothing covers it.
    private func bringForward(_ focused: AXElement, id: CGWindowID, pid: pid_t) {
        guard let partner = partner(of: id),
              partner.window.attribute(kAXMinimizedAttribute) as? Bool != true,
              partner.app.attribute(kAXHiddenAttribute) as? Bool != true else { return }
        guard !endIfSplitAcrossSpaces(id, partner.id) else { return }
        guard Self.isCovered(partner.id, besides: id) else { return }
        let sameApp = members[partner.id]?.pid == pid
        raise(partner.window, besides: focused, sameApp: sameApp)
        // A raised window of another app goes right behind the active app's top window. Before
        // a click has brought the clicked window up, that's still the one covering the partner.
        queue.asyncAfter(deadline: .now() + Self.raiseRecheck) {
            guard self.members[partner.id] != nil, Self.isCovered(partner.id, besides: id) else { return }
            self.raise(partner.window, besides: focused, sameApp: sameApp)
        }
    }

    private func raise(_ window: AXElement, besides focused: AXElement, sameApp: Bool) {
        // Raising a window of an app in the back doesn't switch apps. Making an app frontmost
        // instead would raise all its windows.
        window.perform(kAXRaiseAction)
        // Within one app the raise takes focus: give it back.
        if sameApp {
            focused.perform(kAXRaiseAction)
            focused.set(kAXMainAttribute, to: kCFBooleanTrue)
        }
    }

    /// A window moved to another Space ends its pair: macOS lets nothing take the partner along.
    /// - Returns: Whether the pair ended.
    @discardableResult
    private func endIfSplitAcrossSpaces(_ id: CGWindowID, _ partnerID: CGWindowID) -> Bool {
        guard WindowList.areOnDifferentSpaces(id, partnerID) else { return false }
        logger.debug("Windows \(id) and \(partnerID) are on different Spaces; unpairing.")
        remove(containing: id)
        return true
    }

    /// Moving a window to another Space, by dragging or in Mission Control, sends nothing.
    func removeSplitAcrossSpaces() {
        for pair in pairs {
            endIfSplitAcrossSpaces(pair.first, pair.second)
        }
    }

    private static func isCovered(_ windowID: CGWindowID, besides other: CGWindowID) -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return isCovered(windowID, besides: other, in: windowList)
    }

    /// Whether another visible app window in front of `windowID` overlaps it. `windowList` is
    /// front to back, as the window server gives it; a window not in it (another Space) isn't
    /// covered.
    static func isCovered(_ windowID: CGWindowID, besides other: CGWindowID, in windowList: [[String: Any]]) -> Bool {
        let ids = windowList.map { $0[kCGWindowNumber as String] as? CGWindowID }
        guard let index = ids.firstIndex(of: windowID), let bounds = bounds(of: windowList[index]) else { return false }
        return windowList[..<index].contains { info in
            guard info[kCGWindowNumber as String] as? CGWindowID != other,
                  info[kCGWindowLayer as String] as? Int == 0,
                  // Invisible helper windows (Zoom, Teams, some Electron apps).
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let frame = Self.bounds(of: info) else { return false }
            let overlap = frame.intersection(bounds)
            return !overlap.isNull && overlap.width > SnapLayout.tolerance && overlap.height > SnapLayout.tolerance
        }
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    // MARK: - For Mission Control

    private func published() {
        let pairs = pairs
        Task { @MainActor in
            PairBadges.shared.pairs = pairs
        }
    }
}

/// Accessibility calls this on the main run loop.
private let pairNotificationCallback: AXObserverCallback = { _, element, notification, _ in
    WindowSnapper.shared.pairs.notified(AXElement(element), notification as String)
}
