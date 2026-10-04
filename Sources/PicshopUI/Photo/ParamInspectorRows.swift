#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

// D18 (W3, §7.6): inspector rows generated from the catalog's ParamSpec (`InspectorModel.rows`), drawn by control kind,
// so a parameter the voice can set is a row the panel shows, with the same label and the same formatting. A row writes
// through the op's instant path when it has one (a drag is one undo step on the interaction hooks, a tap one step);
// any other row runs `OperationCall(op, args: fixedArgs + [param: value], source: .ui)` through the executor, the path
// the voice uses.

/// Where generated rows read their values and send their edits.
struct ParamRowBinding {
    var value: (InspectorRowModel) -> OpValue?
    var begin: (InspectorRowModel) -> Void = { _ in }
    var change: (InspectorRowModel, OpValue) -> Void
    var end: (InspectorRowModel) -> Void = { _ in }
    /// The PhotoPanelInventory id of the row (its accessibility identifier).
    var controlID: (InspectorRowModel) -> String = { $0.id }
    var isEnabled: (InspectorRowModel) -> Bool = { _ in true }
}

/// Generated rows, grouped under sticky headers when the rows carry groups (Lumière, Couleur, Détail, Effets).
/// `custom` draws a row the generic kinds do not (curves, gradient stops, the blend picker); nil leaves it out.
struct ParamInspectorRows: View {
    let rows: [InspectorRowModel]
    let binding: ParamRowBinding
    var custom: (InspectorRowModel) -> AnyView? = { _ in nil }

    var body: some View {
        let language: OpLanguage = psPrefersFrench ? .fr : .en
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let group = row.group, index == 0 || rows[index - 1].group != group {
                    InspectorGroupHeader(title: group(language))
                        .padding(.top, index == 0 ? 0 : PSSpacing.small)
                }
                if let view = custom(row) {
                    view
                } else if !Self.isCustom(row) {
                    ParamInspectorRow(row: row, binding: binding)
                }
            }
        }
    }

    static func isCustom(_ row: InspectorRowModel) -> Bool {
        if case .custom = row.control { return true }
        return false
    }
}

/// One generated row: a slider (InspectorSliderRow: drag, double tap to neutral, VoiceOver adjust), a stepper, a
/// segmented control or a menu, a switch, or a colour well.
struct ParamInspectorRow: View {
    let row: InspectorRowModel
    let binding: ParamRowBinding

    var body: some View {
        let language: OpLanguage = psPrefersFrench ? .fr : .en
        let label = row.label(language)
        let value = binding.value(row)
        let id = binding.controlID(row)
        let enabled = binding.isEnabled(row)
        switch row.control {
        case .slider(let range, _, let neutral, _):
            InspectorSliderRow(label: label, value: value?.double ?? neutral, range: range, neutral: neutral, controlID: id,
                               format: { InspectorModel.format(.number($0), row: row, language: language) },
                               onBegin: { binding.begin(row) },
                               onChange: { binding.change(row, .number($0)) },
                               onEnd: { binding.end(row) })
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        case .stepper(let range):
            InspectorStepperRow(label: label, value: Int((value?.double ?? Double(range.lowerBound)).rounded()), range: range, controlID: id) {
                binding.change(row, .number(Double($0)))
            }
            .disabled(!enabled)
        case .segmented(let options):
            InspectorChoiceRow(label: label, options: options.map { InspectorChoiceRow.Option(value: $0.value, title: $0.label(language)) },
                               selection: value?.string, asMenu: false, controlID: id, isEnabled: enabled) {
                binding.change(row, .string($0))
            }
        case .menu(let options):
            InspectorChoiceRow(label: label, options: options.map { InspectorChoiceRow.Option(value: $0.value, title: $0.label(language)) },
                               selection: value?.string, asMenu: true, controlID: id, isEnabled: enabled) {
                binding.change(row, .string($0))
            }
        case .toggle:
            InspectorToggleRow(label: label, isOn: Self.bool(value) ?? false, controlID: id, isEnabled: enabled) {
                binding.change(row, .bool($0))
            }
        case .color:
            InspectorColorRow(label: label, color: value?.string.flatMap { PSColor(hex: $0) } ?? .white, supportsOpacity: false, controlID: id) {
                binding.change(row, .string($0.hexString))
            }
            .disabled(!enabled)
        case .custom:
            EmptyView()
        }
    }

    static func bool(_ value: OpValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }
}

// MARK: - The session's rows (layer properties, transform, fill and adjustment layers)

extension PhotoEditorSession {
    /// The Properties section of the selected layer (§7.6): Opacité, Fond, Fusion, Écrêtage, Verrouillage, and
    /// Transfert for a group. The base photo has its lock only.
    func layerPropertyRows(for layer: Layer) -> [InspectorRowModel] {
        let catalog = OperationCatalog.shared
        let isBase = layer.id == document.baseLayerID
        var rows: [InspectorRowModel] = []
        if !isBase {
            if let spec = catalog.spec("layerOpacity") { rows += InspectorModel.rows(for: spec) }
            if !layer.isGroup, let spec = catalog.spec("layerProperties") {
                rows += InspectorModel.rows(for: spec).filter { $0.param == "fill" }
            }
            if let spec = catalog.spec("layerBlend") { rows += InspectorModel.rows(for: spec) }
            if proLayersEnabled, !layer.isGroup, let spec = catalog.spec("layerClip") { rows += InspectorModel.rows(for: spec) }
        }
        if let spec = catalog.spec("layerProperties") {
            let properties = InspectorModel.rows(for: spec)
            rows += properties.filter { $0.param == "lock" }.map(Self.lockRow)
            if layer.isGroup { rows += properties.filter { $0.param == "passThrough" } }
        }
        return rows
    }

    /// Verrouillage as the contract's segmented control, in « Aucun · Position · Pixels · Transparence · Tout » order.
    static func lockRow(_ row: InspectorRowModel) -> InspectorRowModel {
        guard case .menu(let options) = row.control else { return row }
        var copy = row
        let order = PhotoPanelInventory.lockChoices.map(\.value)
        copy.control = .segmented(order.compactMap { value in options.first { $0.value == value } })
        return copy
    }

    /// The transform rows (`layerTransform`: X, Y, Échelle, Largeur, Hauteur, Rotation, Inclinaison X/Y).
    var transformRows: [InspectorRowModel] {
        guard let spec = OperationCatalog.shared.spec("layerTransform") else { return [] }
        let rows = InspectorModel.rows(for: spec)
        return PhotoPanelInventory.transformRows.compactMap { param in rows.first { $0.param == param } }
    }

    /// A fill layer's rows (`fillLayer`, the edit op with the layer bound, never `addFillLayer`): the colour of a solid
    /// fill; a gradient's colours, style, angle, scale, reverse and dither (its stops are GradientEditor's).
    func fillLayerRows(for layer: Layer) -> [InspectorRowModel] {
        guard let spec = OperationCatalog.shared.spec("fillLayer") else { return [] }
        let rows = InspectorModel.rows(for: spec)
        switch layer.content {
        case .fill: return rows.filter { $0.param == "color" }
        case .gradientFill: return rows
        default: return []
        }
    }

    /// A « Lumière » adjustment layer's rows: `adjust` expanded by parameter (D18), its own dials.
    var lightRows: [InspectorRowModel] {
        guard let spec = OperationCatalog.shared.spec("adjust") else { return [] }
        return InspectorModel.rows(for: spec, expanding: "parameter")
    }

    /// The binding of a layer's generated rows.
    func layerRowBinding(_ layerID: UUID) -> ParamRowBinding {
        ParamRowBinding(value: { [weak self] row in self?.layerRowValue(row, layerID: layerID) },
                        begin: { [weak self] row in self?.beginLayerRow(row, layerID: layerID) },
                        change: { [weak self] row, value in self?.changeLayerRow(row, value: value, layerID: layerID) },
                        end: { [weak self] row in self?.endLayerRow(row) },
                        controlID: { row in Self.layerControlID(row) },
                        isEnabled: { [weak self] row in self?.layerRowEnabled(row, layerID: layerID) ?? false })
    }

    /// The inventory id of a generated row.
    static func layerControlID(_ row: InspectorRowModel) -> String {
        switch (row.op.raw, row.param) {
        case ("layerOpacity", "opacity"): return "layers.props.opacity"
        case ("layerProperties", let param): return "layers.props.\(param)"
        case ("layerClip", _): return "layers.props.clip"
        case ("layerTransform", let param): return "layers.transform.\(param)"
        case ("fillLayer", let param): return "layers.fill.\(param)"
        case ("adjust", _): return "layers.adjustment.light.\(row.fixedArgs["parameter"]?.string ?? row.param)"
        default: return row.id
        }
    }

    /// A row's value now: the document for properties, the transform readout (≤ 15 Hz) in transform mode.
    func layerRowValue(_ row: InspectorRowModel, layerID: UUID) -> OpValue? {
        guard let layer = document.layer(id: layerID) else { return nil }
        switch (row.op.raw, row.param) {
        case ("layerOpacity", "opacity"):
            return .number((layer.opacity * 100).rounded())
        case ("layerProperties", "fill"):
            return .number((layer.fillOpacity * 100).rounded())
        case ("layerProperties", "lock"):
            return .string(PhotoPanelInventory.lockValue(layer.ownLock))
        case ("layerProperties", "passThrough"):
            return .bool(layer.folder?.passThrough ?? true)
        case ("layerProperties", "maskLinked"):
            return .bool(layer.isMaskLinked)
        case ("layerBlend", "mode"):
            return .string(layer.blendMode.rawValue)
        case ("layerClip", "clip"):
            return .bool(layer.isClipped)
        case ("layerTransform", let param):
            return transformRowValue(param, layerID: layerID).map { .number($0) }
        case ("fillLayer", let param):
            return Self.fillValue(param, of: layer)
        case ("adjust", "amount"):
            guard let parameter = row.fixedArgs["parameter"]?.string.flatMap(AdjustmentParameter.init(rawValue:)) else { return nil }
            return .number(Self.adjustments(of: layerID, in: document)[parameter] * 100)
        default:
            return nil
        }
    }

    /// A transform row's value: the readout the drag updates at ≤ 15 Hz in transform mode, else the document.
    func transformRowValue(_ param: String, layerID: UUID) -> Double? {
        guard layerState.transformTarget == layerID else { return transformField(param, of: layerID) }
        let readout = layerState.transform
        let canvas = document.canvasSize
        switch param {
        case "x": return canvas.width > 0 ? readout.x / canvas.width * 1000 : nil
        case "y": return canvas.height > 0 ? readout.y / canvas.height * 1000 : nil
        case "scaleX": return readout.widthPercent
        case "scaleY": return readout.heightPercent
        case "rotation": return readout.rotation
        case "skewX": return readout.skewX
        case "skewY": return readout.skewY
        default: return transformField(param, of: layerID)
        }
    }

    /// A fill layer's value for a `fillLayer` param.
    static func fillValue(_ param: String, of layer: Layer) -> OpValue? {
        switch layer.content {
        case .fill(let color):
            return param == "color" ? .string(color.hexString) : nil
        case .gradientFill(let gradient):
            switch param {
            case "color": return gradient.stops.first.map { .string($0.color.hexString) }
            case "color2": return gradient.stops.last.map { .string($0.color.hexString) }
            case "style": return .string(gradient.style.rawValue)
            case "angle": return .number(gradient.angle)
            case "scale": return .number(gradient.scale)
            case "reverse": return .bool(gradient.reverse)
            case "dither": return .bool(gradient.dither)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The locks decide which rows can move (D7): a refused row is dimmed rather than refused at every tick.
    func layerRowEnabled(_ row: InspectorRowModel, layerID: UUID) -> Bool {
        switch row.op.raw {
        case "layerOpacity", "layerBlend", "layerClip":
            return LayerLockPolicy.allows(.properties, on: layerID, in: document)
        case "layerProperties":
            return row.param == "lock" || row.param == "maskLinked" || LayerLockPolicy.allows(.properties, on: layerID, in: document)
        case "layerTransform":
            return LayerLockPolicy.allows(.placement, on: layerID, in: document)
        case "fillLayer", "adjust":
            return LayerLockPolicy.allows(.content, on: layerID, in: document)
        default:
            return true
        }
    }

    /// A slider drag begins: one undo step on the snapshot of what it moves (D13).
    func beginLayerRow(_ row: InspectorRowModel, layerID: UUID) {
        switch (row.op.raw, row.param) {
        case ("layerOpacity", _):
            beginLayerPropertyDrag(layerID, label: "Opacity")
        case ("layerProperties", "fill"):
            beginLayerPropertyDrag(layerID, label: "Fill")
        case ("layerTransform", _):
            guard layerAllows(.placement, on: layerID) else { return }
            beginInteraction(label: Self.transformLabel, scope: .layerPlacement(layerID))
        case ("fillLayer", _):
            guard layerAllows(.content, on: layerID) else { return }
            beginInteraction(label: "Fill Layer", scope: .fillLayer(layerID))
        case ("adjust", _):
            guard let parameter = row.fixedArgs["parameter"]?.string.flatMap(AdjustmentParameter.init(rawValue:)), layerAllows(.content, on: layerID) else { return }
            beginInteraction(label: parameter.englishName, scope: .adjustmentLayer(layerID))
        default:
            break
        }
    }

    /// A row's new value: the instant path, or the op through the executor.
    func changeLayerRow(_ row: InspectorRowModel, value: OpValue, layerID: UUID) {
        switch (row.op.raw, row.param) {
        case ("layerOpacity", "opacity"):
            if let percent = value.double { setLayerOpacityValue(percent / 100, layerID: layerID) }
        case ("layerProperties", "fill"):
            if let percent = value.double { setLayerFill(percent / 100, layerID: layerID) }
        case ("layerProperties", "lock"):
            if let choice = value.string { setLock(choice, layerID: layerID) }
        case ("layerProperties", "passThrough"):
            if let flag = ParamInspectorRow.bool(value) { setPassThrough(flag, groupID: layerID) }
        case ("layerProperties", "maskLinked"):
            if let flag = ParamInspectorRow.bool(value) { setLayerMaskLinked(flag, layerID: layerID) }
        case ("layerBlend", "mode"):
            if let raw = value.string, let mode = PicshopCore.BlendMode(rawValue: raw) { setBlend(mode, layerID: layerID) }
        case ("layerClip", "clip"):
            if let flag = ParamInspectorRow.bool(value) { setClipped(flag, layerID: layerID) }
        case ("layerTransform", let param):
            if let number = value.double { setTransformField(param, value: number, layerID: layerID) }
        case ("fillLayer", let param):
            setFillLayerParam(param, value: value, layerID: layerID)
        case ("adjust", "amount"):
            guard let parameter = row.fixedArgs["parameter"]?.string.flatMap(AdjustmentParameter.init(rawValue:)), let percent = value.double else { return }
            setAdjustmentLayerDial(parameter, value: percent / 100, layerID: layerID)
        default:
            var args = row.fixedArgs
            args[row.param] = value
            if let layer = document.layer(id: layerID), let ref = Self.layerRef(layer, in: document) { args["ref"] = .string(ref) }
            perform(EditIntent(action: .operation, operation: OperationCall(row.op, args: args, source: .ui)))
        }
    }

    /// The drag ends: one commit.
    func endLayerRow(_ row: InspectorRowModel) {
        guard interaction != nil else { return }
        endInteraction()
        if row.op.raw == "layerTransform" { refreshTransformOverlay() }
    }

    /// A fill layer's colour, colours, style, angle, scale, reverse or dither (`LayerEdit.solidFill` / `.gradient`).
    func setFillLayerParam(_ param: String, value: OpValue, layerID: UUID) {
        guard let layer = document.layer(id: layerID), layer.isFill else { return }
        if interaction == nil, !layerAllows(.content, on: layerID) { return }
        interactiveEdit(label: "Fill Layer") { document in
            guard let current = document.layer(id: layerID) else { return }
            switch current.content {
            case .fill:
                guard param == "color", let hex = value.string, let color = PSColor(hex: hex) else { return }
                document.applyLayerEdit(.solidFill(color), to: layerID)
            case .gradientFill(var gradient):
                switch param {
                case "color", "color2":
                    // The well picks the colour; the stop keeps its own transparency (« Noir → transparent »).
                    guard let hex = value.string, var color = PSColor(hex: hex), !gradient.stops.isEmpty else { return }
                    let index = param == "color" ? 0 : gradient.stops.count - 1
                    color.alpha = gradient.stops[index].color.alpha
                    gradient.stops[index].color = color
                case "style":
                    guard let raw = value.string, let style = GradientFill.Style(rawValue: raw) else { return }
                    gradient.style = style
                case "angle":
                    guard let angle = value.double else { return }
                    gradient.angle = angle
                case "scale":
                    guard let scale = value.double else { return }
                    gradient.scale = scale.clamped(to: 10...150)
                case "reverse":
                    guard let flag = ParamInspectorRow.bool(value) else { return }
                    gradient.reverse = flag
                case "dither":
                    guard let flag = ParamInspectorRow.bool(value) else { return }
                    gradient.dither = flag
                default:
                    return
                }
                document.applyLayerEdit(.gradient(gradient), to: layerID)
            default:
                return
            }
        }
    }

    /// A « Lumière » adjustment layer's own dial (its `content`, through `LayerEdit.adjustments`).
    func setAdjustmentLayerDial(_ parameter: AdjustmentParameter, value: Double, layerID: UUID) {
        guard document.layer(id: layerID)?.isAdjustment == true else { return }
        if interaction == nil, !layerAllows(.content, on: layerID) { return }
        let clamped = value.clamped(to: parameter.range)
        interactiveEdit(label: parameter.englishName) { document in
            var dials = Self.adjustments(of: layerID, in: document)
            dials[parameter] = clamped
            document.applyLayerEdit(.adjustments(dials), to: layerID)
        }
    }
}
#endif
