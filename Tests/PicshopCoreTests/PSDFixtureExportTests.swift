import XCTest
@testable import PicshopCore

/// D16: the Core writer's PSD fixtures (the three-layer document at 8 and 16 bits, the 50 % alpha layer), each with a
/// sidecar `<name>.json` that `Scripts/validate_psd.py` compares with what psd-tools reads. With `PICSHOP_PSD_OUT` set
/// (CI's psd-validate job), both files land there; without it they are written to a temporary folder and checked here.
///
/// Sidecar schema (one object per PSD):
///   {"file": "<name>.psd", "width": Int, "height": Int, "depth": 8 | 16,
///    "layers": [Layer]}                      top level, bottom → top, the order psd-tools iterates
///   Layer = {"name": String, "kind": "pixel" | "group", "blend_key": 4 characters ("pass" for a pass-through group),
///            "opacity": 0…255, "fill_opacity": 0…255, "clipped": Bool, "visible": Bool, "has_mask": Bool,
///            "collapsed": Bool (groups only), "children": [Layer] (groups only, bottom → top)}
final class PSDFixtureExportTests: XCTestCase {
    /// The sidecar tree of a spec's layer list (markers turned into nesting).
    static func sidecarLayers(_ layers: [PSDLayer]) -> [[String: Any]] {
        var stack: [[[String: Any]]] = [[]]
        for layer in layers {
            switch layer.kind {
            case .groupEnd:
                stack.append([])
            case .groupOpen(let collapsed):
                let children = stack.count > 1 ? stack.removeLast() : []
                stack[stack.count - 1].append(entry(layer, kind: "group", extra: ["collapsed": collapsed, "children": children]))
            case .pixels:
                stack[stack.count - 1].append(entry(layer, kind: "pixel", extra: [:]))
            }
        }
        return stack.first ?? []
    }

    static func entry(_ layer: PSDLayer, kind: String, extra: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["name": layer.name, "kind": kind, "blend_key": layer.blendKey, "opacity": Int(layer.opacity),
                                     "fill_opacity": Int(layer.fillOpacity), "clipped": layer.clipped, "visible": layer.visible,
                                     "has_mask": layer.mask != nil]
        for (key, value) in extra { result[key] = value }
        return result
    }

    func testTheFixturesAreWrittenWithTheirSidecars() throws {
        let environment = ProcessInfo.processInfo.environment["PICSHOP_PSD_OUT"].flatMap { $0.isEmpty ? nil : $0 }
        let folder = environment.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("picshop-psd-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if environment == nil { try? FileManager.default.removeItem(at: folder) } }
        let work = FileManager.default.temporaryDirectory
        let fixtures: [(String, PSDDocumentSpec)] = [
            ("picshop-core-three-layers-8", PSDTestDocuments.threeLayers(depth: 8).spec),
            ("picshop-core-three-layers-16", PSDTestDocuments.threeLayers(depth: 16).spec),
            ("picshop-core-half-alpha-8", PSDTestDocuments.halfAlpha().spec),
        ]
        for (name, spec) in fixtures {
            let url = folder.appendingPathComponent("\(name).psd")
            try? FileManager.default.removeItem(at: url)
            try PSDWriter.write(spec, to: url, temporaryDirectory: work)
            let sidecar: [String: Any] = ["file": "\(name).psd", "width": spec.width, "height": spec.height, "depth": spec.depth,
                                          "layers": Self.sidecarLayers(spec.layers)]
            let json = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys, .prettyPrinted])
            try json.write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)
            // What the sidecar says is what Core's parser reads.
            let psd = try PSDFile(data: try Data(contentsOf: url))
            XCTAssertEqual(psd.width, spec.width, name)
            XCTAssertEqual(psd.depth, spec.depth, name)
            XCTAssertEqual(psd.layers.count, spec.layers.count, name)
            let readBack = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            let top = try XCTUnwrap(readBack["layers"] as? [[String: Any]])
            XCTAssertEqual(top.count, spec.layers.filter { layer in
                if case .groupEnd = layer.kind { return false }
                return true
            }.count - (name.contains("three") ? 2 : 0), "\(name): the group's two children are nested")
        }
        let three = Self.sidecarLayers(PSDTestDocuments.threeLayers(depth: 8).spec.layers)
        XCTAssertEqual(three.map { $0["name"] as? String }, ["Été", "Groupe 1", "Masqué"])
        let group = try XCTUnwrap(three.first { $0["kind"] as? String == "group" })
        XCTAssertEqual(group["blend_key"] as? String, "pass")
        XCTAssertEqual((group["children"] as? [[String: Any]])?.map { $0["name"] as? String }, ["Tasse", "Ombre"])
        XCTAssertEqual(three.last?["has_mask"] as? Bool, true)
    }
}
