import AppKit
import SwiftUI

/// In Mission Control, a small badge on each paired window with the half it takes, drawn with
/// the same symbols as macOS's own tiling menu, so the two read as one.
@MainActor
final class PairBadges {
    static let shared = PairBadges()
    private init() {}

    struct Badge: Equatable, Sendable {
        /// The thumbnail, in AppKit screen coordinates.
        let thumbnail: CGRect
        let symbol: String
    }

    /// Mission Control opens with an animation; look for the thumbnails once it's done.
    private static let openingDelay: Duration = .milliseconds(300)
    /// Mission Control re-lays out its thumbnails after a window closes; wait for that.
    private static let relayoutDelay: Duration = .milliseconds(450)

    /// Set by the snapper whenever a pair is made or ends.
    var pairs: [WindowPair] = [] {
        didSet {
            if pairs.isEmpty { hide() }
        }
    }

    var hasPairs: Bool { !pairs.isEmpty }

    private let canvas = OverlayCanvas()
    private var shown: [Badge] = []

    func missionControlDidOpen() {
        refresh(after: Self.openingDelay)
    }

    func layoutMayHaveChanged() {
        refresh(after: Self.relayoutDelay)
    }

    func hide() {
        shown = []
        canvas.tearDown()
    }

    private func refresh(after delay: Duration) {
        guard hasPairs, MissionControlSession.current != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let layout = await MissionControlThumbnails.shared.layout(maxAge: .zero)
            guard MissionControlSession.current != nil else { return }
            // A window moved to another Space in Mission Control ends its pair only once it closes.
            let together = pairs.filter { !WindowList.areOnDifferentSpaces($0.first, $0.second) }
            let badges = Self.badges(for: together, thumbnails: layout.thumbnails.map { ($0.window.windowID, $0.frame) })
            guard badges != shown || !canvas.isVisible else { return }
            shown = badges
            guard !badges.isEmpty else {
                canvas.hide()
                return
            }
            canvas.show { screen in
                let onScreen = badges.filter { NSMouseInRect(NSPoint(x: $0.thumbnail.midX, y: $0.thumbnail.midY), screen.frame, false) }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(onScreen.enumerated()), id: \.offset) { _, badge in
                        PairBadgeView(symbol: badge.symbol)
                            .padding(.bottom, 10)
                            .placed(in: OverlayCanvas.local(badge.thumbnail, in: screen.frame), alignment: .bottom)
                    }
                }
            }
        }
    }

    /// A badge on each thumbnail of a paired window, with the half that window takes.
    nonisolated static func badges(for pairs: [WindowPair], thumbnails: [(windowID: CGWindowID, frame: CGRect)]) -> [Badge] {
        let frames = Dictionary(thumbnails.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        return pairs.flatMap { pair in
            [pair.first, pair.second].compactMap { id in
                frames[id].map { Badge(thumbnail: $0, symbol: symbol(for: pair.edge(of: id))) }
            }
        }
    }

    nonisolated static func symbol(for edge: SnapAction) -> String {
        switch edge {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        case .maximize, .restore, .nextDisplay, .previousDisplay: "rectangle.split.2x1"
        }
    }
}

/// The half a paired window takes, on a small material disc like the window count chips.
struct PairBadgeView: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
