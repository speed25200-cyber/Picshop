import XCTest
@testable import PicshopCore

/// UX 2.0 reachability (ux-spec §3.5.12, §6.4): every photo tool, precise mode, panel-inventory control and W4 tool
/// has exactly one home; every legacy panel stays reachable through a live tool in the new frame; the bar holds
/// the seven named categories; labels come from the glossary and fit the length rule.
final class ToolLayoutTests: XCTestCase {
    private let layout = ToolLayout.photo

    // MARK: Homes

    func testEveryPhotoToolHasExactlyOneHome() {
        let ids = layout.legacyTools + ToolLayout.photoPreciseModes + ToolLayout.photoW4Tools + ["export", "canvas"]
        for id in ids {
            let primary = layout.homes(of: id).filter { !$0.isShortcut }
            XCTAssertEqual(primary.count, 1, "\(id) has \(primary.count) homes")
        }
    }

    func testEveryPanelInventoryControlHasExactlyOneHome() {
        let controls = PhotoPanelInventory.controls + MaskPanelInventory.controls
        XCTAssertFalse(controls.isEmpty)
        for control in controls {
            let own = layout.homes(of: control.id).filter { !$0.isShortcut }
            if own.isEmpty {
                let toolHomes = layout.homes(of: control.uiTool).filter { !$0.isShortcut }
                XCTAssertEqual(toolHomes.count, 1, "\(control.id): its tool \(control.uiTool) has \(toolHomes.count) homes")
            } else {
                XCTAssertEqual(own.count, 1, "\(control.id) has \(own.count) homes")
            }
            XCTAssertNotNil(layout.home(ofControl: control.id, uiTool: control.uiTool), control.id)
        }
    }

    func testEveryHomePointsAtSomethingThatExists() {
        for home in layout.homes {
            switch home.place {
            case .strip(let category, let tool):
                XCTAssertNotNil(layout.categories.first { $0.id == category }, "\(home.id): no category \(category)")
                XCTAssertEqual(layout.category(containingTool: tool)?.id, category, "\(home.id): \(tool) is not in \(category)")
            case .pill(let pill, let tool):
                XCTAssertNotNil(layout.pills.first { $0.id == pill }, "\(home.id): no pill \(pill)")
                XCTAssertEqual(layout.category(containingTool: tool)?.id, pill, "\(home.id): \(tool) is not in \(pill)")
            case .documentMenu(let item):
                XCTAssertNotNil(layout.menuItem(item), "\(home.id): no menu item \(item)")
            case .topBar(let control):
                XCTAssertTrue(["back", "title", "undo", "redo", "export"].contains(control), "\(home.id): \(control)")
            case .canvas:
                break
            case .contextBar(let selection, let item):
                XCTAssertTrue(layout.contextBars[selection]?.contains { $0.id == item } ?? false, "\(home.id): no \(item) in \(selection)")
            }
        }
    }

    /// Never break existing features: each panel that works today is the host of a live tool in the new frame.
    func testEveryLegacyPanelIsHostedByALiveTool() {
        XCTAssertEqual(layout.legacyTools.count, 16)
        XCTAssertEqual(Set(layout.legacyTools).count, layout.legacyTools.count)
        for legacy in layout.legacyTools {
            XCTAssertFalse(layout.tools(hostedBy: legacy).isEmpty, "\(legacy) is not reachable in the new frame")
            XCTAssertNotNil(layout.tool(forLegacy: legacy), legacy)
        }
        for tool in layout.allTools {
            if let host = tool.host { XCTAssertTrue(layout.legacyTools.contains(host), "\(tool.id): unknown host \(host)") }
            if tool.kind == .panel, tool.status.isLive { XCTAssertNotNil(tool.host, "\(tool.id): a live panel needs a host") }
        }
    }

    func testHostControlsAreInventoryControlsOfTheirHost() {
        let controls = Dictionary((PhotoPanelInventory.controls + MaskPanelInventory.controls).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tool in layout.allTools {
            guard let id = tool.hostControl else { continue }
            guard let control = controls[id] else { return XCTFail("\(tool.id): no control \(id)") }
            XCTAssertEqual(control.uiTool, tool.host, "\(tool.id): \(id) belongs to \(control.uiTool)")
        }
    }

    func testThePrimaryHomeOfALegacyToolIsOneOfTheToolsItHostsWhenThatToolIsLive() {
        for legacy in layout.legacyTools {
            guard let home = layout.primaryHome(of: legacy), home.status.isLive else { continue }
            switch home.place {
            case .strip(_, let toolID), .pill(_, let toolID):
                let tool = layout.tool(toolID)
                XCTAssertEqual(tool?.host, legacy, "\(legacy) lives at \(toolID), hosted by \(tool?.host ?? "nothing")")
            case .documentMenu, .topBar, .canvas, .contextBar:
                XCTFail("\(legacy): a legacy panel's home is a strip")
            }
        }
    }

    // MARK: Bar, strips, ids

    func testTheBarHoldsTheSevenNamedCategoriesInOrder() {
        XCTAssertEqual(layout.bar().map(\.id), ["magic", "adjust", "filters", "crop", "retouch", "text", "select"])
        XCTAssertEqual(ToolLayout.bar(for: .photo).map(\.term), ["magic", "adjust", "filters", "crop", "retouch", "text", "selection"])
        XCTAssertEqual(layout.pills.map(\.id), ["layers"])
        XCTAssertEqual(layout.strip(category: "adjust").map(\.id),
                       ["adjust.light", "adjust.color", "adjust.effects", "adjust.detail", "adjust.curves", "adjust.levels", "adjust.blur"])
        XCTAssertEqual(layout.strip(category: "crop").map(\.id), ["crop.format", "crop.straighten", "crop.perspective"])
        XCTAssertEqual(layout.strip(category: "retouch").map(\.id), ["retouch.remove", "retouch.brushes", "retouch.cutout"])
        XCTAssertEqual(ToolLayout.bar(for: .photo, selection: .text).first?.id, "text.edit")
        XCTAssertTrue(ToolLayout.bar(for: .photo, selection: .clip).isEmpty)
    }

    func testIDsAreUniqueAndPrefixedByTheirCategory() {
        let tools = layout.allTools.map(\.id)
        XCTAssertEqual(Set(tools).count, tools.count)
        for category in layout.categories + layout.pills {
            for tool in category.tools { XCTAssertTrue(tool.id.hasPrefix(category.id + "."), tool.id) }
        }
        let menu = layout.documentMenu.flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(menu).count, menu.count)
        let context = layout.contextBars.values.flatMap { $0 }.map(\.id)
        XCTAssertEqual(Set(context).count, context.count)
        for (selection, items) in layout.contextBars {
            // Destructive items come last (§4.8).
            if let first = items.firstIndex(where: \.isDestructive) {
                XCTAssertTrue(items[first...].allSatisfy(\.isDestructive), "\(selection)")
            }
        }
    }

    func testOnlyMagieSelectionAndCalquesOpenEmpty() {
        let empty = (layout.categories + layout.pills).filter(\.opensEmpty).map(\.id)
        XCTAssertEqual(Set(empty), ["magic", "select", "layers"])
    }

    func testIncrementOneShipsTheRedesignedToolsLive() {
        for id in ["adjust.light", "adjust.color", "adjust.effects", "adjust.curves", "adjust.levels", "filters.suggested", "crop.format",
                   "retouch.remove", "text.text", "text.shapes", "layers.list", "select.zones"] {
            XCTAssertEqual(layout.tool(id)?.status, .live, id)
        }
        XCTAssertEqual(layout.tool("retouch.reshape")?.status, .pending(wave: 4))
        XCTAssertEqual(layout.menuItem("allTools")?.status, .live)
        XCTAssertEqual(layout.menuItem("history")?.status, .live)
    }

    // MARK: Labels

    func testEveryLabelIsAGlossaryTerm() {
        var terms = layout.categories.map(\.term) + layout.pills.map(\.term) + layout.allTools.map(\.term)
        terms += layout.contextBars.values.flatMap { $0 }.map(\.term)
        terms += layout.documentMenu.flatMap(\.items).map(\.term) + layout.documentMenu.compactMap(\.term)
        for term in terms { XCTAssertNotNil(UXGlossary.term(term), "no glossary term \(term)") }
    }

    /// §5.1 rule 6: bar, strip and category labels ≤ 12 characters per line, at most 2 lines; category labels on
    /// one line; context-bar items ≤ 14. Magie's action tiles are wider (96 points) and exempt.
    func testLabelsFitTheLengthRule() {
        for french in [true, false] {
            for category in layout.categories + layout.pills {
                let label = UXGlossary.text(category.term, french: french)
                XCTAssertLessThanOrEqual(label.count, 12, label)
                for tool in category.tools where !(category.id == "magic" && tool.kind == .action) {
                    let text = UXGlossary.text(tool.term, french: french)
                    XCTAssertTrue(Self.fitsTwoLines(text, width: 12), "« \(text) » (\(tool.id))")
                }
            }
            for item in layout.contextBars.values.flatMap({ $0 }) {
                let text = UXGlossary.text(item.term, french: french)
                XCTAssertLessThanOrEqual(text.count, 14, text)
            }
        }
    }

    func testVideoAndPDFTablesAreEmptyUntilTheirLanesLand() {
        XCTAssertEqual(ToolLayout.of(.video).kind, .video)
        XCTAssertEqual(ToolLayout.of(.pdf).kind, .pdf)
        XCTAssertTrue(ToolLayout.bar(for: .video).isEmpty)
        XCTAssertEqual(ToolLayout.of(.photo), layout)
    }

    /// Greedy word wrap into lines of at most `width` characters, two lines at most.
    static func fitsTwoLines(_ text: String, width: Int) -> Bool {
        var lines: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            guard word.count <= width else { return false }
            if let last = lines.last, last.count + 1 + word.count <= width {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines.count <= 2
    }
}
