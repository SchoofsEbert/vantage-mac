import CoreGraphics

/// Two windows Snap Assist put side by side (or one above the other), which keep sharing the
/// edge between them: resizing one across it resizes the other. All frames in AX space.
struct WindowPair: Equatable, Sendable {
    enum Layout: Sendable {
        case sideBySide
        case stacked
    }

    /// What a pair does after one of its windows moved or changed size.
    enum Outcome: Equatable {
        /// Still lined up, or a window took a size between two that are.
        case keep
        /// The partner follows the shared edge to this frame.
        case resize(CGWindowID, to: CGRect)
        /// A window left the pair: moved away, resized from an outer edge, or filled the screen.
        case unpair
    }

    /// Below this a partner would rather go than shrink further.
    static let minimumExtent: CGFloat = 100

    let layout: Layout
    /// Left or top.
    private(set) var first: CGWindowID
    /// Right or bottom.
    private(set) var second: CGWindowID
    /// Where each window was placed. Only their outer edges count: those stay put while the
    /// shared edge moves.
    private(set) var firstFrame: CGRect
    private(set) var secondFrame: CGRect

    /// The pair a Snap Assist pick makes, unless the two didn't end up sharing an edge, as when
    /// the picked window wouldn't shrink to fit.
    init?(snapped: CGWindowID, at snappedFrame: CGRect, picked: CGWindowID, at pickedFrame: CGRect, action: SnapAction) {
        let snappedFirst: Bool
        switch action {
        case .left: (layout, snappedFirst) = (.sideBySide, true)
        case .right: (layout, snappedFirst) = (.sideBySide, false)
        case .top: (layout, snappedFirst) = (.stacked, true)
        case .bottom: (layout, snappedFirst) = (.stacked, false)
        case .maximize, .restore, .nextDisplay, .previousDisplay: return nil
        }
        guard snapped != picked else { return nil }
        (first, firstFrame) = snappedFirst ? (snapped, snappedFrame) : (picked, pickedFrame)
        (second, secondFrame) = snappedFirst ? (picked, pickedFrame) : (snapped, snappedFrame)
        guard Self.meet(sharedEdge(of: firstFrame, isFirst: true), sharedEdge(of: secondFrame, isFirst: false)) else { return nil }
    }

    func contains(_ windowID: CGWindowID) -> Bool {
        windowID == first || windowID == second
    }

    func partner(of windowID: CGWindowID) -> CGWindowID? {
        windowID == first ? second : windowID == second ? first : nil
    }

    /// The edge a snap of the window hugs, for placing it again.
    func edge(of windowID: CGWindowID) -> SnapAction {
        switch (layout, windowID == first) {
        case (.sideBySide, true): .left
        case (.sideBySide, false): .right
        case (.stacked, true): .top
        case (.stacked, false): .bottom
        }
    }

    /// After `changed` took `frame`, with its partner at `partnerFrame`.
    func follow(_ changed: CGWindowID, to frame: CGRect, partnerFrame: CGRect) -> Outcome {
        guard let partner = partner(of: changed) else { return .keep }
        let isFirst = changed == first
        guard keepsOuterEdges(frame, isFirst: isFirst) else { return .unpair }
        let edge = sharedEdge(of: frame, isFirst: isFirst)
        guard !Self.meet(edge, sharedEdge(of: partnerFrame, isFirst: !isFirst)) else { return .keep }
        let outer = outerEdge(isFirst: !isFirst)
        let extent = isFirst ? outer - edge : edge - outer
        guard extent >= Self.minimumExtent else { return .unpair }
        let start = isFirst ? edge : outer
        let target = switch layout {
        case .sideBySide: CGRect(x: start, y: partnerFrame.minY, width: extent, height: partnerFrame.height)
        case .stacked: CGRect(x: partnerFrame.minX, y: start, width: partnerFrame.width, height: extent)
        }
        return .resize(partner, to: target)
    }

    /// Another window took this one's place, as a native tab does.
    mutating func replace(_ old: CGWindowID, with new: CGWindowID) {
        if first == old {
            first = new
        } else if second == old {
            second = new
        }
    }

    /// Both windows went somewhere new together, as to another display.
    mutating func moved(first firstFrame: CGRect, second secondFrame: CGRect) {
        self.firstFrame = firstFrame
        self.secondFrame = secondFrame
    }

    // MARK: - Edges

    private func sharedEdge(of frame: CGRect, isFirst: Bool) -> CGFloat {
        switch layout {
        case .sideBySide: isFirst ? frame.maxX : frame.minX
        case .stacked: isFirst ? frame.maxY : frame.minY
        }
    }

    /// The edge across from the shared one, where the window was placed.
    private func outerEdge(isFirst: Bool) -> CGFloat {
        switch layout {
        case .sideBySide: isFirst ? firstFrame.minX : secondFrame.maxX
        case .stacked: isFirst ? firstFrame.minY : secondFrame.maxY
        }
    }

    /// The three edges that aren't shared are where the window was placed.
    private func keepsOuterEdges(_ frame: CGRect, isFirst: Bool) -> Bool {
        let placed = isFirst ? firstFrame : secondFrame
        let outer = outerEdge(isFirst: isFirst)
        return switch layout {
        case .sideBySide:
            Self.meet(isFirst ? frame.minX : frame.maxX, outer)
                && Self.meet(frame.minY, placed.minY) && Self.meet(frame.maxY, placed.maxY)
        case .stacked:
            Self.meet(isFirst ? frame.minY : frame.maxY, outer)
                && Self.meet(frame.minX, placed.minX) && Self.meet(frame.maxX, placed.maxX)
        }
    }

    private static func meet(_ one: CGFloat, _ other: CGFloat) -> Bool {
        abs(one - other) <= SnapLayout.tolerance
    }
}
