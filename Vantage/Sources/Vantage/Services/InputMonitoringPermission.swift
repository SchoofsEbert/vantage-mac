import AppKit
import Observation

/// Whether tab swipes are on but Input Monitoring isn't allowed, for Settings to say so.
///
/// The swipe tap only listens, and a listening tap needs Input Monitoring: Accessibility, which
/// the main tap runs on, doesn't cover it. Without it macOS still creates the tap but never sends
/// it a touch, so this is the only sign. No notification when it changes: checked when swipes
/// are turned on and whenever Vantage comes forward (back from System Settings). Cheap to check.
@MainActor
@Observable
final class InputMonitoringPermission {
    static let shared = InputMonitoringPermission()
    private init() {}

    /// Nil until the first check.
    private(set) var isAllowed: Bool?
    private var wanted = false

    /// Tab swipes are on, and macOS won't send Vantage the touches.
    var isMissing: Bool {
        wanted && isAllowed == false
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let privacySettings = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
    )! // swiftlint:disable:this force_unwrapping

    func startObserving() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { InputMonitoringPermission.shared.settingsChanged() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { InputMonitoringPermission.shared.check() }
            }
        ]
        wanted = UserDefaults.standard.bool(.enableTabSwipe)
        check()
        if isAllowed == false {
            request()
        }
    }

    func check() {
        guard wanted else { return }
        let allowed = CGPreflightListenEventAccess()
        guard allowed != isAllowed else { return }
        let isFirstCheck = isAllowed == nil
        isAllowed = allowed
        if !isFirstCheck {
            NotificationCenter.default.post(name: .inputMonitoringChanged, object: nil)
        }
    }

    /// Asks macOS, which shows its prompt only the first time; after that, it's changed in
    /// Privacy settings.
    func request() {
        Task.detached {
            CGRequestListenEventAccess()
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(Self.privacySettings)
    }

    /// Defaults change for many reasons; only turning swipes on or off matters here.
    private func settingsChanged() {
        let wanted = UserDefaults.standard.bool(.enableTabSwipe)
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        check()
        if wanted, isAllowed == false {
            request()
        }
    }
}

extension Notification.Name {
    /// Input Monitoring was allowed or taken away: a tap made before only listens from now on if
    /// it's made again.
    static let inputMonitoringChanged = Notification.Name("InputMonitoringChanged")
}
