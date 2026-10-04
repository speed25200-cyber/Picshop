import XCTest
@testable import PicshopCore

/// D17: every LayerEdit (applied, then unchanged when repeated, refused where it does not apply), the lock table
/// through the document, and the structure edits: duplicate, via copy and via cut, the merges, flatten, stamp, group
/// and ungroup, add image. Every structure edit leaves a normalised tree and selects its result.
final class LayerEditingTests: XCTestCase {
    private typealias W3 = W3Documents

    private func raster(_ n: Int, width: Double, height: Double) -> MediaAsset {
        MediaAsset(id: W3.id(n), kind: .image, relativePath: "media/raster-\(n).png", pixelSize: PSSize(width: width, height: height))
    }

    /// base, a masked image, an image above it, a fill, an adjustment, a group with a text child.
    private var sample: PhotoDocument {
        var document = W3.base(81, title: "edits")
        var masked = W3.image(8102, "Tasse")
        masked.maskStack = W3.stack
        var child = W3.text(8106, "Titre")
        child.parentID = W3.id(8107)
        document.layers += [masked, W3.image(8103, "Logo", W3.logo),
                            Layer(id: W3.id(8104), name: "Couleur", content: .fill(.black)),
                            Layer(id: W3.id(8105), name: "Lumière", content: .adjustment(.neutral), recipeKind: .light),
                            child, Layer(id: W3.id(8107), name: "Groupe 1", content: .group(LayerFolder()))]
        return DocumentCodec.migrated(document)
    }

    private func assertStructure(_ document: PhotoDocument, _ result: (outcome: LayerEditOutcome, layerID: UUID?), selects id: UUID?,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.outcome, .applied, file: file, line: line)
        XCTAssertTrue(document.isNormalizedLayerTree, file: file, line: line)
        XCTAssertTrue(document.layers.allSatisfy { $0.refPrefix == nil || $0.refNumber != nil }, "every layer numbered", file: file, line: line)
        if let id { XCTAssertEqual(document.selectedLayerID, id, file: file, line: line) }
    }

    // MARK: Layer edits

    func testEachLayerEditAppliesOnceThenIsUnchanged() {
        let id = W3.id
        let linear = MaskStack(components: [MaskComponent(id: id(8190), .linear(LinearGradientSpec(start: PSPoint(x: 0, y: 0), end: PSPoint(x: 1, y: 1))))])
        let edits: [(LayerEdit, UUID)] = [
            (.opacity(0.4), id(8102)), (.fillOpacity(0.3), id(8102)), (.blendMode(.screen), id(8102)), (.visible(false), id(8102)),
            (.lock([.transparency]), id(8102)), (.lockAll(true), id(8102)), (.clipped(true), id(8103)), (.rename("Nouveau nom"), id(8102)),
            (.transform(LayerTransform(center: PSPoint(x: 0.3, y: 0.6), scale: 0.4, rotation: 12)), id(8102)),
            (.transform(LayerTransform(center: PSPoint(x: 0.2, y: 0.7), scale: 1.5, rotation: -8)), id(8106)),
            (.maskStack(linear), id(8103)), (.maskEdit(.setComponentMode(id(80), .subtract)), id(8102)), (.maskEnabled(false), id(8102)),
            (.maskLinked(false), id(8102)), (.solidFill(.red), id(8104)), (.gradient(.twoColor(.red, .blue)), id(8104)),
            (.adjustments(Adjustments([.exposure: 0.5])), id(8105)), (.folder(LayerFolder(passThrough: false)), id(8107)),
            (.recipeKind(.curves), id(8105)),
        ]
        var covered: Set<String> = []
        for (edit, target) in edits {
            var document = sample
            XCTAssertEqual(document.applyLayerEdit(edit, to: target), .applied, "\(edit)")
            let once = document
            XCTAssertEqual(document.applyLayerEdit(edit, to: target), .unchanged, "\(edit)")
            XCTAssertEqual(document.layers, once.layers, "\(edit)")
            covered.insert(String(describing: edit).components(separatedBy: "(").first ?? "")
        }
        XCTAssertEqual(covered.count, 18, "every LayerEdit case")
    }

    func testEditsLandWhereTheyShould() throws {
        var document = sample
        // A text layer's centre and rotation go to its element; its scale stays on the layer.
        document.applyLayerEdit(.transform(LayerTransform(center: PSPoint(x: 0.2, y: 0.7), scale: 1.5, rotation: -8)), to: W3.id(8106))
        let text = try XCTUnwrap(document.layer(id: W3.id(8106)))
        XCTAssertEqual(text.textElement?.center, PSPoint(x: 0.2, y: 0.7))
        XCTAssertEqual(text.textElement?.rotation, -8)
        XCTAssertEqual(text.transform.scale, 1.5)
        XCTAssertEqual(text.transform.center, PSPoint(x: 0.5, y: 0.5))
        // Values are clamped, a skew too; names trimmed to 60 characters.
        document.applyLayerEdit(.opacity(3), to: W3.id(8102))
        XCTAssertEqual(document.layer(id: W3.id(8102))?.opacity, 1)
        document.applyLayerEdit(.transform(LayerTransform(skewX: 120)), to: W3.id(8103))
        XCTAssertEqual(document.layer(id: W3.id(8103))?.transform.skewX, 80)
        document.applyLayerEdit(.rename(String(repeating: "é", count: 80) + "  "), to: W3.id(8103))
        XCTAssertEqual(document.layer(id: W3.id(8103))?.name.count, 60)
        XCTAssertEqual(document.applyLayerEdit(.rename("   "), to: W3.id(8103)), .unchanged)
        // A gradient is stored normalised.
        document.applyLayerEdit(.gradient(GradientFill(style: .linear, stops: [GradientStop(location: 2, color: .red)])), to: W3.id(8104))
        guard case .gradientFill(let gradient) = document.layer(id: W3.id(8104))?.content else { return XCTFail("a gradient") }
        XCTAssertEqual(gradient.stops.count, 2)
        // A legacy mask becomes a stack on the first mask edit.
        var legacy = W3.layerMasks
        XCTAssertEqual(legacy.applyLayerEdit(.maskEnabled(false), to: W3.id(606)), .applied)
        XCTAssertNil(legacy.layer(id: W3.id(606))?.mask)
        XCTAssertEqual(legacy.layer(id: W3.id(606))?.maskStack?.components.count, 1)
    }

    func testUnlinkingKeepsTheMaskOnTheSamePixels() throws {
        var document = sample
        let before = try XCTUnwrap(document.layer(id: W3.id(8102)))
        document.applyLayerEdit(.transform(LayerTransform(center: PSPoint(x: 0.35, y: 0.55), scale: 0.6, rotation: 25)), to: before.id)
        let placed = try XCTUnwrap(document.layer(id: before.id))
        let size = W3.cup.pixelSize
        let toCanvas = LayerPlacement.map(for: placed, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        let centreInContent = PSPoint(x: 0.4, y: 0.5)
        XCTAssertEqual(document.applyLayerEdit(.maskLinked(false), to: before.id), .applied)
        let unlinked = try XCTUnwrap(document.layer(id: before.id)?.maskStack)
        guard case .radial(let spec) = unlinked.components[0].kind else { return XCTFail("radial") }
        let expected = toCanvas.apply(centreInContent)
        XCTAssertEqual(spec.center.x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(spec.center.y, expected.y, accuracy: 1e-9)
        // And back.
        XCTAssertEqual(document.applyLayerEdit(.maskLinked(true), to: before.id), .applied)
        guard case .radial(let back) = document.layer(id: before.id)?.maskStack?.components[0].kind else { return XCTFail("radial") }
        XCTAssertEqual(back.center.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(back.center.y, 0.5, accuracy: 1e-9)
    }

    func testRefusals() {
        var document = sample
        let base = document.baseLayerID!
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.5), to: W3.id(8199)), .refused(.notFound))
        XCTAssertEqual(document.applyLayerEdit(.transform(LayerTransform(scale: 0.5)), to: base), .refused(.baseLayer))
        XCTAssertEqual(document.applyLayerEdit(.clipped(true), to: base), .refused(.baseLayer))
        XCTAssertEqual(document.applyLayerEdit(.clipped(true), to: W3.id(8106)), .refused(.noValidClipBase), "bottom of its group")
        XCTAssertEqual(document.applyLayerEdit(.fillOpacity(0.5), to: W3.id(8107)), .refused(.notApplicable))
        XCTAssertEqual(document.applyLayerEdit(.transform(.identity), to: W3.id(8104)), .refused(.notApplicable))
        XCTAssertEqual(document.applyLayerEdit(.solidFill(.red), to: W3.id(8102)), .refused(.notApplicable))
        XCTAssertEqual(document.applyLayerEdit(.adjustments(.neutral), to: W3.id(8104)), .refused(.notApplicable))
        XCTAssertEqual(document.applyLayerEdit(.folder(LayerFolder()), to: W3.id(8102)), .refused(.notAGroup))
        XCTAssertEqual(document.applyLayerEdit(.maskEnabled(false), to: W3.id(8103)), .refused(.notFound))
        XCTAssertEqual(document.applyLayerEdit(.maskEdit(.setAmount(0.5)), to: W3.id(8102)), .refused(.notApplicable))
        XCTAssertEqual(document.applyLayerEdit(.maskEdit(.removeComponent(W3.id(8199))), to: W3.id(8102)), .refused(.notFound))
        // The messages exist in both languages.
        for refusal in LayerEditRefusal.allCases {
            XCTAssertFalse(PhotoDocument.refusalMessage(refusal, layerName: "Tasse", french: true).isEmpty)
            XCTAssertFalse(PhotoDocument.refusalMessage(refusal, layerName: nil, french: false).isEmpty)
        }
        XCTAssertTrue(PhotoDocument.refusalMessage(.locked, layerName: "Tasse", french: true).contains("« Tasse »"))
    }

    func testTheLockTableThroughTheDocument() {
        typealias Attempt = (LayerMutation, (inout PhotoDocument, UUID) -> Bool)
        let attempts: [Attempt] = [
            (.content, { $0.apply(.adjust(.exposure, value: 0.3), to: $1) }),
            (.alpha, { $0.applyStructureEdit(.applyMask($1, raster: W3.cup)).outcome == .applied }),
            (.placement, { $0.applyLayerEdit(.transform(LayerTransform(scale: 0.3)), to: $1) == .applied }),
            (.properties, { $0.applyLayerEdit(.opacity(0.3), to: $1) == .applied }),
            (.mask, { $0.applyLayerEdit(.maskEnabled(false), to: $1) == .applied }),
            (.order, { $0.applyStructureEdit(.move($1, to: .top)).outcome == .applied }),
            (.delete, { $0.applyStructureEdit(.remove($1)).outcome == .applied }),
        ]
        XCTAssertEqual(Set(attempts.map(\.0)), Set(LayerMutation.allCases))
        for row in LayerLockTests.table {
            for (mutation, attempt) in attempts {
                var document = sample
                let target = W3.id(8102)
                document.update(layerID: target) { layer in
                    if row.lock == .all { layer.isLocked = true } else { layer.lockOptions = row.lock }
                }
                let before = document
                let applied = attempt(&document, target)
                XCTAssertEqual(applied, !row.refused.contains(mutation), "\(row.name) \(mutation)")
                if !applied { XCTAssertEqual(document, before, "\(row.name) \(mutation): a refusal changes nothing") }
            }
        }
    }

    func testBundleWideVisibilityOpacityAndBlend() {
        var document = W3.refsAndBundles
        let cells = (0..<6).map { W3.id(910 + $0) }
        XCTAssertEqual(document.applyLayerEdit(.visible(false), to: cells[2]), .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.isVisible == false })
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.5), to: cells[0]), .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.opacity == 0.5 })
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.5), to: cells[5]), .unchanged)
        // Rename acts on the one cell.
        XCTAssertEqual(document.applyLayerEdit(.rename("A1"), to: cells[0]), .applied)
        XCTAssertEqual(document.layer(id: cells[1])?.name, "1")
    }

    // MARK: Structure edits

    func testDuplicatingAGroupGivesFreshIdsWithTheParentRemapped() throws {
        var document = W3.groupsIsolated
        let original = document.layers.map(\.id)
        let result = document.applyStructureEdit(.duplicate(W3.id(104)))
        let copyID = try XCTUnwrap(result.layerID)
        assertStructure(document, result, selects: copyID)
        XCTAssertFalse(original.contains(copyID))
        let copy = try XCTUnwrap(document.layer(id: copyID))
        XCTAssertTrue(copy.isGroup)
        XCTAssertEqual(copy.name, "Groupe 1 copie")
        let children = document.children(of: copyID)
        XCTAssertEqual(children.map(\.name), ["Logo", "Tasse"])
        XCTAssertTrue(children.allSatisfy { !original.contains($0.id) })
        XCTAssertEqual(children[1].maskStack, W3.stack)
        // The copy sits above the original group, the original untouched.
        XCTAssertEqual(document.layers.prefix(4).map(\.id), original)
        XCTAssertEqual(document.children(of: W3.id(104)).map(\.id), [W3.id(102), W3.id(103)])
        XCTAssertEqual(document.layers.count, 7)
    }

    func testDuplicatingALayerFreshensItsOperationsAndLocalAdjustments() throws {
        var document = sample
        let local = LocalAdjustment(id: W3.id(8180), stack: W3.stack, adjustments: Adjustments([.exposure: 0.4]))
        document.setLocalAdjustment(local, on: W3.id(8102))
        document.apply(.adjust(.contrast, value: 0.2), to: W3.id(8102))
        let source = try XCTUnwrap(document.layer(id: W3.id(8102)))
        let result = document.applyStructureEdit(.duplicate(source.id))
        let copy = try XCTUnwrap(result.layerID.flatMap(document.layer(id:)))
        assertStructure(document, result, selects: copy.id)
        XCTAssertEqual(copy.name, "Tasse copie")
        XCTAssertEqual(document.index(of: copy.id), document.index(of: source.id).map { $0 + 1 })
        XCTAssertEqual(copy.edits.operations.count, source.edits.operations.count)
        XCTAssertTrue(zip(copy.edits.operations, source.edits.operations).allSatisfy { $0.id != $1.id })
        XCTAssertNotEqual(document.localAdjustments(on: copy.id).first?.id, local.id)
        XCTAssertEqual(document.localAdjustments(on: copy.id).first?.adjustments, local.adjustments)
        XCTAssertNotEqual(copy.refNumber, source.refNumber)
    }

    func testLayerViaCopyKeepsTheAssetAndEditsAndIntersectsTheMasks() throws {
        var document = sample
        document.apply(.adjust(.exposure, value: 0.3), to: W3.id(8102))
        let source = try XCTUnwrap(document.layer(id: W3.id(8102)))
        let region = MaskStack(components: [MaskComponent(id: W3.id(8191), .linear(LinearGradientSpec(start: PSPoint(x: 0, y: 0), end: PSPoint(x: 0, y: 1))))])
        let result = document.applyStructureEdit(.viaCopy(source: source.id, region: region, name: nil))
        let layer = try XCTUnwrap(result.layerID.flatMap(document.layer(id:)))
        assertStructure(document, result, selects: layer.id)
        XCTAssertEqual(layer.name, "Tasse · Dégradé")
        XCTAssertEqual(layer.content, source.content)
        XCTAssertEqual(layer.transform, source.transform)
        XCTAssertEqual(layer.edits.operations.map(\.kind), source.edits.operations.map(\.kind))
        XCTAssertNotEqual(layer.edits.operations.first?.id, source.edits.operations.first?.id)
        let stack = try XCTUnwrap(layer.maskStack)
        XCTAssertEqual(stack.components.count, 2)
        XCTAssertEqual(stack.components[0], region.components[0])
        XCTAssertEqual(stack.components[1].kind, W3.stack.components[0].kind)
        XCTAssertEqual(stack.components[1].mode, .intersect)
        XCTAssertEqual(document.index(of: layer.id), document.index(of: source.id).map { $0 + 1 })
        XCTAssertEqual(document.layer(id: source.id), source, "via copy leaves the source alone")
        // Without a mask on the source, the region alone; a name given wins.
        var plain = sample
        let named = plain.applyStructureEdit(.viaCopy(source: W3.id(8103), region: region, name: "Haut"))
        XCTAssertEqual(named.layerID.flatMap(plain.layer(id:))?.maskStack, region)
        XCTAssertEqual(named.layerID.flatMap(plain.layer(id:))?.name, "Haut")
        // Refusals.
        XCTAssertEqual(plain.applyStructureEdit(.viaCopy(source: W3.id(8103), region: MaskStack(), name: nil)).outcome, .refused(.emptyRegion))
        XCTAssertEqual(plain.applyStructureEdit(.viaCopy(source: W3.id(8104), region: region, name: nil)).outcome, .refused(.notAnImageLayer))
    }

    func testLayerViaCutSubtractsOnTheSource() throws {
        var document = sample
        let region = MaskStack(components: [MaskComponent(id: W3.id(8192), .linear(LinearGradientSpec(start: PSPoint(x: 0, y: 0), end: PSPoint(x: 1, y: 0))))])
        let result = document.applyStructureEdit(.viaCut(source: W3.id(8102), region: region, name: nil))
        assertStructure(document, result, selects: result.layerID)
        let source = try XCTUnwrap(document.layer(id: W3.id(8102))?.maskStack)
        XCTAssertEqual(source.components.count, 2)
        XCTAssertEqual(source.components[0], W3.stack.components[0])
        XCTAssertEqual(source.components[1].kind, region.components[0].kind)
        XCTAssertEqual(source.components[1].mode, .subtract)
        // Without a stack, the source keeps 1 − region.
        let plain = document.applyStructureEdit(.viaCut(source: W3.id(8103), region: region, name: nil))
        XCTAssertEqual(plain.outcome, .applied)
        var inverted = region
        inverted.isInverted = true
        XCTAssertEqual(document.layer(id: W3.id(8103))?.maskStack, inverted)
    }

    func testMergeDownKeepsTheLowerLayersIdentityAndPlacesTheCroppedRaster() throws {
        var document = W3.base(82, title: "merge")
        document.layers += [Layer(id: W3.id(8202), name: "Tasse", content: .image(W3.cup), transform: LayerTransform(scale: 0.5), opacity: 0.7,
                                  blendMode: .multiply),
                            W3.text(8203, "Haut")]
        document = DocumentCodec.migrated(document)
        let lower = try XCTUnwrap(document.layer(id: W3.id(8202)))
        let merged = raster(8290, width: 1000, height: 600)
        let bounds = PSRect(x: 0.1, y: 0.2, width: 0.25, height: 0.2)
        let result = document.applyStructureEdit(.mergeDown(W3.id(8203), raster: merged), rasterBounds: bounds)
        assertStructure(document, result, selects: lower.id)
        XCTAssertEqual(result.layerID, lower.id)
        XCTAssertNil(document.layer(id: W3.id(8203)))
        let layer = try XCTUnwrap(document.layer(id: lower.id))
        XCTAssertEqual(layer.name, "Tasse")
        XCTAssertEqual(layer.blendMode, .multiply)
        XCTAssertEqual(layer.opacity, 0.7)
        XCTAssertEqual(layer.refNumber, lower.refNumber)
        XCTAssertEqual(layer.content, .image(merged))
        XCTAssertTrue(layer.edits.isEmpty)
        let quad = LayerPlacement.quad(for: layer, contentSize: merged.pixelSize, canvasSize: document.canvasSize, isBase: false)
        let corners = [PSPoint(x: 0.1, y: 0.2), PSPoint(x: 0.35, y: 0.2), PSPoint(x: 0.35, y: 0.4), PSPoint(x: 0.1, y: 0.4)]
        for (got, want) in zip(quad, corners) {
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
        // Onto a text layer: it becomes an image and takes the next image number.
        var onText = W3.base(83, title: "merge text")
        onText.layers += [W3.image(8302, "Tasse"), W3.text(8303, "Bas"), W3.image(8304, "Haut", W3.logo)]
        onText = DocumentCodec.migrated(onText)
        XCTAssertEqual(onText.applyStructureEdit(.mergeDown(W3.id(8304), raster: merged)).outcome, .applied)
        XCTAssertEqual(onText.layer(id: W3.id(8303))?.refNumber, 2, "the next image number once X (i2) is gone")
        XCTAssertEqual(onText.layer(id: W3.id(8302))?.refNumber, 1)
        XCTAssertEqual(onText.layer(id: W3.id(8303))?.refPrefix, "i")
        // Nothing below in the same parent, or an adjustment: refused.
        var grouped = W3.groupsIsolated
        XCTAssertEqual(grouped.applyStructureEdit(.mergeDown(W3.id(102), raster: merged)).outcome, .refused(.notApplicable))
        XCTAssertEqual(grouped.applyStructureEdit(.mergeDown(grouped.baseLayerID!, raster: merged)).outcome, .refused(.baseLayer))
    }

    func testMergeSelectedReplacesTheChosenLayersAtTheTopmostPlace() throws {
        var document = W3.base(84, title: "merge selected")
        document.layers += [W3.image(8402, "A"), W3.text(8403, "B"), Layer(id: W3.id(8404), name: "C", content: .shape(ShapeElement(kind: .ellipse)),
                                                                            opacity: 0.5, blendMode: .screen)]
        document = DocumentCodec.migrated(document)
        let merged = raster(8490, width: 4000, height: 3000)
        let result = document.applyStructureEdit(.mergeLayers([W3.id(8402), W3.id(8404)], raster: merged))
        assertStructure(document, result, selects: W3.id(8404))
        XCTAssertEqual(document.layers.map(\.id), [document.baseLayerID!, W3.id(8403), W3.id(8404)])
        let layer = try XCTUnwrap(document.layer(id: W3.id(8404)))
        XCTAssertEqual(layer.content, .image(merged))
        XCTAssertEqual(layer.blendMode, .normal)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.name, "C")
        XCTAssertEqual(layer.refPrefix, "i")
        XCTAssertEqual(document.applyStructureEdit(.mergeLayers([W3.id(8403)], raster: merged)).outcome, .refused(.notApplicable))
    }

    func testFlattenDiscardsHiddenLayersAndMergeVisibleKeepsThem() throws {
        var document = W3.base(85, title: "flatten")
        document.layers += [W3.image(8502, "Visible"), Layer(id: W3.id(8503), name: "Caché", content: .fill(.red), isVisible: false)]
        document = DocumentCodec.migrated(document)
        let picture = raster(8590, width: 4000, height: 3000)
        var visible = document
        let merged = visible.applyStructureEdit(.mergeVisible(raster: picture))
        assertStructure(visible, merged, selects: visible.baseLayerID)
        XCTAssertEqual(visible.layers.map(\.id), [document.baseLayerID!, W3.id(8503)])
        XCTAssertEqual(visible.layers[0].content, .image(picture))
        var flat = document
        let flattened = flat.applyStructureEdit(.flatten(raster: picture))
        assertStructure(flat, flattened, selects: flat.baseLayerID)
        XCTAssertEqual(flat.layers.count, 1)
        XCTAssertEqual(flat.layers[0].id, document.baseLayerID)
        XCTAssertEqual(flat.layers[0].content, .image(picture))
        XCTAssertEqual(flat.layers[0].transform, .identity)
        XCTAssertEqual(flat.layers[0].refNumber, 0)
    }

    func testStampAddsOnTop() throws {
        var document = sample
        let picture = raster(8690, width: 4000, height: 3000)
        let result = document.applyStructureEdit(.stamp(raster: picture, name: "Tampon"))
        assertStructure(document, result, selects: result.layerID)
        let top = try XCTUnwrap(document.layers.last)
        XCTAssertEqual(top.id, result.layerID)
        XCTAssertEqual(top.name, "Tampon")
        XCTAssertEqual(top.content, .image(picture))
        XCTAssertNil(top.parentID)
        let quad = LayerPlacement.quad(for: top, contentSize: picture.pixelSize, canvasSize: document.canvasSize, isBase: false)
        XCTAssertEqual(quad[0].x, 0, accuracy: 1e-12)
        XCTAssertEqual(quad[2].y, 1, accuracy: 1e-12)
    }

    func testGroupAndUngroupFoldTheOpacity() throws {
        var document = W3.base(87, title: "group")
        document.layers += [Layer(id: W3.id(8702), name: "A", content: .image(W3.cup), opacity: 0.8), W3.text(8703, "Milieu"),
                            Layer(id: W3.id(8704), name: "B", content: .fill(.blue), opacity: 0.5)]
        document = DocumentCodec.migrated(document)
        let grouped = document.applyStructureEdit(.group([W3.id(8702), W3.id(8704)], name: nil))
        let groupID = try XCTUnwrap(grouped.layerID)
        assertStructure(document, grouped, selects: groupID)
        XCTAssertEqual(document.layer(id: groupID)?.name, "Groupe 1")
        XCTAssertEqual(document.layers.map(\.id), [document.baseLayerID!, W3.id(8703), W3.id(8702), W3.id(8704), groupID])
        XCTAssertEqual(document.layer(id: W3.id(8702))?.opacity, 0.8, "grouping changes no opacity")
        // Nested and base groupings are refused.
        XCTAssertEqual(document.applyStructureEdit(.group([groupID], name: nil)).outcome, .refused(.nestedGroup))
        XCTAssertEqual(document.applyStructureEdit(.group([document.baseLayerID!], name: nil)).outcome, .refused(.baseLayer))
        // A hidden group at 50 %: ungrouping folds its opacity and visibility into the children.
        document.applyLayerEdit(.opacity(0.5), to: groupID)
        document.applyLayerEdit(.visible(false), to: groupID)
        let ungrouped = document.applyStructureEdit(.ungroup(groupID))
        assertStructure(document, ungrouped, selects: W3.id(8704))
        XCTAssertNil(document.layer(id: groupID))
        XCTAssertEqual(document.layer(id: W3.id(8702))?.opacity ?? 0, 0.4, accuracy: 1e-12)
        XCTAssertEqual(document.layer(id: W3.id(8704))?.opacity ?? 0, 0.25, accuracy: 1e-12)
        XCTAssertEqual(document.layer(id: W3.id(8702))?.isVisible, false)
        XCTAssertEqual(document.layers.map(\.id), [document.baseLayerID!, W3.id(8703), W3.id(8702), W3.id(8704)])
        XCTAssertEqual(document.applyStructureEdit(.ungroup(W3.id(8702))).outcome, .refused(.notAGroup))
    }

    func testAddImageFits() throws {
        let canvas = W3.base(88, title: "add").canvasSize
        let cases: [(ImageLayerFit, PSSize)] = [(.fit, PSSize(width: 1800, height: 2400)), (.fill, PSSize(width: 4000, height: 4000 * 4 / 3)),
                                                (.original, PSSize(width: 1200, height: 1600))]
        for (fit, expected) in cases {
            var document = W3.base(88, title: "add")
            let result = document.applyStructureEdit(.addImage(W3.cup, name: "Tasse", fit: fit, placement: .top))
            let layer = try XCTUnwrap(result.layerID.flatMap(document.layer(id:)))
            assertStructure(document, result, selects: layer.id)
            let bounds = LayerPlacement.bounds(for: layer, contentSize: W3.cup.pixelSize, canvasSize: canvas, isBase: false)
            XCTAssertEqual(bounds.width * canvas.width, expected.width, accuracy: 1e-6, "\(fit)")
            XCTAssertEqual(bounds.height * canvas.height, expected.height, accuracy: 1e-6, "\(fit)")
            XCTAssertEqual(bounds.midX, 0.5, accuracy: 1e-12)
            XCTAssertEqual(layer.refNumber, 1)
        }
    }

    func testAddRemoveMoveAndTheUnitCap() throws {
        var document = sample
        // Into a group, above and below.
        let added = Layer(id: W3.id(8150), name: "Ajout", content: .fill(.white))
        let into = document.applyStructureEdit(.add(added, placement: .into(groupID: W3.id(8107))))
        assertStructure(document, into, selects: added.id)
        XCTAssertEqual(document.layer(id: added.id)?.parentID, W3.id(8107))
        XCTAssertEqual(document.applyStructureEdit(.add(added, placement: .top)).outcome, .refused(.notApplicable), "an id already there")
        XCTAssertEqual(document.applyStructureEdit(.add(Layer(name: "x", content: .fill(.red)), placement: .below(document.baseLayerID!))).outcome,
                       .refused(.baseLayer))
        XCTAssertEqual(document.applyStructureEdit(.add(Layer(name: "x", content: .fill(.red)), placement: .into(groupID: W3.id(8102)))).outcome,
                       .refused(.notAGroup))
        // Removing a group removes its children; the base cannot go.
        XCTAssertEqual(document.applyStructureEdit(.remove(document.baseLayerID!)).outcome, .refused(.baseLayer))
        let removed = document.applyStructureEdit(.remove(W3.id(8107)))
        XCTAssertEqual(removed.outcome, .applied)
        XCTAssertNil(document.layer(id: W3.id(8106)))
        XCTAssertNil(document.layer(id: added.id))
        // Moving below the base is refused; a move to where it is is unchanged.
        XCTAssertEqual(document.applyStructureEdit(.move(W3.id(8103), to: .index(0))).outcome, .applied)
        XCTAssertEqual(document.index(of: W3.id(8103)), 1, "nothing goes below the base")
        XCTAssertEqual(document.applyStructureEdit(.move(W3.id(8103), to: .index(1))).outcome, .unchanged)
        // 64 units at most; a table bundle is one.
        var full = W3.base(89, title: "full")
        for n in 1..<PhotoDocument.maxLayers { full.layers.append(Layer(name: "F\(n)", content: .fill(.black))) }
        XCTAssertEqual(full.layerUnitCount, PhotoDocument.maxLayers)
        XCTAssertEqual(full.applyStructureEdit(.add(Layer(name: "plus", content: .fill(.red)), placement: .top)).outcome, .refused(.tooManyLayers))
        XCTAssertEqual(full.applyStructureEdit(.duplicate(full.layers[3].id)).outcome, .refused(.tooManyLayers))
    }

    func testApplyMaskBakesIntoTheRaster() throws {
        var document = sample
        let baked = raster(8195, width: 600, height: 800)
        let result = document.applyStructureEdit(.applyMask(W3.id(8102), raster: baked), rasterBounds: PSRect(x: 0.2, y: 0.1, width: 0.15, height: 800.0 / 3000))
        assertStructure(document, result, selects: W3.id(8102))
        let layer = try XCTUnwrap(document.layer(id: W3.id(8102)))
        XCTAssertNil(layer.maskStack)
        XCTAssertEqual(layer.content, .image(baked))
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(document.applyStructureEdit(.applyMask(W3.id(8104), raster: baked)).outcome, .refused(.notAnImageLayer))
    }
}
