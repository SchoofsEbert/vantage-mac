@testable import Vantage
import CoreGraphics
import Foundation
import Testing

@Suite("Window Pairs")
struct WindowPairTests {
    /// A 1440×875 visible area below a 25-point menu bar.
    private let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private var left: CGRect { SnapLayout.frame(for: .left, step: 0, in: area) }
    private var right: CGRect { SnapLayout.frame(for: .right, step: 0, in: area) }

    private func sideBySide() throws -> WindowPair {
        try #require(WindowPair(snapped: 1, at: left, picked: 2, at: right, action: .left))
    }

    @Test("A snap and its pick make a pair, left or top first")
    func pairing() throws {
        let pair = try sideBySide()
        #expect(pair.first == 1 && pair.second == 2 && pair.layout == .sideBySide)
        let snappedRight = try #require(WindowPair(snapped: 1, at: right, picked: 2, at: left, action: .right))
        #expect(snappedRight.first == 2 && snappedRight.second == 1)
        let top = SnapLayout.frame(for: .top, step: 0, in: area)
        let bottom = SnapLayout.frame(for: .bottom, step: 0, in: area)
        let stacked = try #require(WindowPair(snapped: 1, at: bottom, picked: 2, at: top, action: .bottom))
        #expect(stacked.layout == .stacked && stacked.first == 2 && stacked.edge(of: 1) == .bottom)
    }

    @Test("Windows that don't meet, or a snap that leaves no rest, aren't paired")
    func noPair() {
        let tooWide = CGRect(x: 600, y: 25, width: 840, height: 875)
        #expect(WindowPair(snapped: 1, at: left, picked: 2, at: tooWide, action: .left) == nil)
        #expect(WindowPair(snapped: 1, at: area, picked: 2, at: right, action: .maximize) == nil)
        #expect(WindowPair(snapped: 1, at: left, picked: 1, at: right, action: .left) == nil)
    }

    @Test("Dragging the shared edge resizes the partner to meet it")
    func followsSharedEdge() throws {
        let pair = try sideBySide()
        let wider = CGRect(x: 0, y: 25, width: 900, height: 875)
        #expect(pair.follow(1, to: wider, partnerFrame: right) == .resize(2, to: CGRect(x: 900, y: 25, width: 540, height: 875)))
        let narrowerRight = CGRect(x: 1000, y: 25, width: 440, height: 875)
        #expect(pair.follow(2, to: narrowerRight, partnerFrame: left) == .resize(1, to: CGRect(x: 0, y: 25, width: 1000, height: 875)))
    }

    @Test("Stacked windows follow the edge between them")
    func followsStacked() throws {
        let top = SnapLayout.frame(for: .top, step: 0, in: area)
        let bottom = SnapLayout.frame(for: .bottom, step: 0, in: area)
        let pair = try #require(WindowPair(snapped: 1, at: top, picked: 2, at: bottom, action: .top))
        let taller = CGRect(x: 0, y: 25, width: 1440, height: 600)
        #expect(pair.follow(1, to: taller, partnerFrame: bottom) == .resize(2, to: CGRect(x: 0, y: 625, width: 1440, height: 275)))
    }

    @Test("The partner keeps its own height, as Terminal rounds it")
    func partnerKeepsCrossSize() throws {
        let terminal = CGRect(x: 720, y: 25, width: 720, height: 868)
        let pair = try #require(WindowPair(snapped: 1, at: left, picked: 2, at: terminal, action: .left))
        let wider = CGRect(x: 0, y: 25, width: 800, height: 875)
        #expect(pair.follow(1, to: wider, partnerFrame: terminal) == .resize(2, to: CGRect(x: 800, y: 25, width: 640, height: 868)))
    }

    @Test("Edges that still meet, and echoes of the partner's own resize, change nothing")
    func keeps() throws {
        let pair = try sideBySide()
        #expect(pair.follow(1, to: left, partnerFrame: right) == .keep)
        let nudged = CGRect(x: 0, y: 25, width: 721, height: 875)
        #expect(pair.follow(1, to: nudged, partnerFrame: right) == .keep)
        #expect(pair.follow(3, to: left, partnerFrame: right) == .keep)
    }

    @Test("Moving away, resizing from an outer edge or filling the screen ends the pair")
    func unpairs() throws {
        let pair = try sideBySide()
        let moved = left.offsetBy(dx: 40, dy: 0)
        #expect(pair.follow(1, to: moved, partnerFrame: right) == .unpair)
        let shorter = CGRect(x: 0, y: 25, width: 720, height: 600)
        #expect(pair.follow(1, to: shorter, partnerFrame: right) == .unpair)
        #expect(pair.follow(1, to: area, partnerFrame: right) == .unpair)
    }

    @Test("Snapping a paired window to a third keeps the pair, with the partner taking the rest")
    func cyclingKeepsPair() throws {
        let pair = try sideBySide()
        let third = SnapLayout.frame(for: .left, step: 1, in: area)
        #expect(pair.follow(1, to: third, partnerFrame: right) == .resize(2, to: CGRect(x: 480, y: 25, width: 960, height: 875)))
    }

    @Test("After a move to another display, the new frames count")
    func movedTogether() throws {
        var pair = try sideBySide()
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let newLeft = SnapLayout.frame(for: .left, step: 0, in: other)
        let newRight = SnapLayout.frame(for: .right, step: 0, in: other)
        pair.moved(first: newLeft, second: newRight)
        #expect(pair.follow(1, to: newLeft, partnerFrame: newRight) == .keep)
        let wider = CGRect(x: 1440, y: 0, width: 1000, height: 1055)
        #expect(pair.follow(1, to: wider, partnerFrame: newRight) == .resize(2, to: CGRect(x: 2440, y: 0, width: 920, height: 1055)))
    }

    @Test("A tab taking a window's place takes its side in the pair")
    func tabTakesOver() throws {
        var pair = try sideBySide()
        pair.replace(1, with: 5)
        #expect(pair.first == 5 && pair.partner(of: 2) == 5 && !pair.contains(1))
        let wider = CGRect(x: 0, y: 25, width: 900, height: 875)
        #expect(pair.follow(5, to: wider, partnerFrame: right) == .resize(2, to: CGRect(x: 900, y: 25, width: 540, height: 875)))
    }

    // MARK: - Coming forward

    private func info(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary,
        ]
    }

    @Test("A partner behind another window is covered; behind its own pair or a menu bar item it isn't")
    func covered() {
        let other = CGRect(x: 600, y: 100, width: 400, height: 400)
        #expect(WindowPairs.isCovered(2, besides: 1, in: [info(1, left), info(9, other), info(2, right)]))
        #expect(!WindowPairs.isCovered(2, besides: 1, in: [info(1, left), info(2, right), info(9, other)]))
        #expect(!WindowPairs.isCovered(2, besides: 1, in: [info(9, other, layer: 25), info(1, left), info(2, right)]))
        let elsewhere = CGRect(x: 0, y: 100, width: 300, height: 300)
        #expect(!WindowPairs.isCovered(2, besides: 1, in: [info(9, elsewhere), info(2, right)]))
        #expect(!WindowPairs.isCovered(2, besides: 1, in: [info(9, other)]))
        #expect(!WindowPairs.isCovered(2, besides: 1, in: [info(9, other, alpha: 0), info(2, right)]))
    }

    // MARK: - Mission Control

    @Test("Each paired window on show gets a badge with the half it takes")
    func badges() throws {
        let thumbnails: [(windowID: CGWindowID, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 100, height: 80)),
            (2, CGRect(x: 120, y: 0, width: 100, height: 80)),
            (7, CGRect(x: 360, y: 0, width: 100, height: 80)),
        ]
        let badges = PairBadges.badges(for: [try sideBySide()], thumbnails: thumbnails)
        #expect(badges.map(\.symbol) == ["rectangle.lefthalf.filled", "rectangle.righthalf.filled"])
        #expect(badges.map(\.thumbnail.minX) == [0, 120])
        let top = SnapLayout.frame(for: .top, step: 0, in: area)
        let bottom = SnapLayout.frame(for: .bottom, step: 0, in: area)
        let stacked = try #require(WindowPair(snapped: 2, at: bottom, picked: 7, at: top, action: .bottom))
        #expect(PairBadges.badges(for: [stacked], thumbnails: thumbnails).map(\.symbol)
            == ["rectangle.tophalf.filled", "rectangle.bottomhalf.filled"])
    }
}
