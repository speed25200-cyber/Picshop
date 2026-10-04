import XCTest
@testable import PicshopCore

/// AC-01 on Linux (ux-spec §6.4): every live task path uses only visible items and meets its « after » count.
final class TapPathCatalogTests: XCTestCase {
    func testEveryLivePathUsesOnlyVisibleItems() {
        for path in TapPathCatalog.paths where path.status.isLive {
            let layout = path.editor.map(ToolLayout.of)
            for step in path.steps {
                guard let id = step.itemID else { continue }
                XCTAssertTrue(Self.isVisible(id, in: layout), "\(path.id): « \(id) » is not a visible item")
            }
        }
    }

    func testEveryPathMeetsItsTarget() {
        let ids = TapPathCatalog.paths.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for path in TapPathCatalog.paths {
            XCTAssertGreaterThan(path.target, 0, path.id)
            XCTAssertLessThanOrEqual(path.taps, path.target, "\(path.id): \(path.taps) taps for a target of \(path.target)")
        }
        XCTAssertEqual(TapPathCatalog.path("P2")?.taps, 1)
        XCTAssertEqual(TapPathCatalog.path("P3")?.taps, 3)
        XCTAssertEqual(TapPathCatalog.path("H1")?.taps, 2)
    }

    func testTheIncrementOnePathsAreListed() {
        for id in ["H1", "H2", "H3", "H4", "H5", "H6", "P1", "P2", "P3", "P4", "P5", "P6", "P8", "P9", "P10", "P11", "P12"] {
            XCTAssertEqual(TapPathCatalog.path(id)?.status, .live, id)
        }
    }

    /// A probe id the screen shows: a bar, strip, pill or menu item of the editor's table, a context-bar item, or
    /// one of the shared components' and lanes' published ids.
    static func isVisible(_ id: String, in layout: ToolLayout?) -> Bool {
        if TapPathCatalog.knownItems.contains(id) { return true }
        guard let layout else { return false }
        if id.hasPrefix("bar.") { return layout.categories.contains { "bar." + $0.id == id } }
        if id.hasPrefix("pill.") { return layout.pills.contains { "pill." + $0.id == id } }
        if id.hasPrefix("strip.") { return layout.tool(String(id.dropFirst(6)))?.status.isLive ?? false }
        if id.hasPrefix("menu.") { return layout.menuItem(String(id.dropFirst(5)))?.status.isLive ?? false }
        return layout.contextBars.values.contains { items in items.contains { $0.id == id } }
    }
}
