import Foundation

/// Every control of the Masques, Sélection, Color Range, range-mask and Select & Mask UI, with how a voice or a
/// model reaches it (the W2 reachability rule, I1). M4's PanelInventoryTests reads it against the catalog.
///
/// Ids are "<tool>.<group>.<item>"; the views tag their controls with the same ids, and an `openTool:<id>` effect
/// (grammar or Live) opens the control's tool in the right mode. `param` is "key=value" for an enumeration value
/// and the bare key otherwise (numbers, booleans, colours, text, refs).
public enum MaskPanelInventory {
    public enum Reach: String, Sendable {
        /// A catalog operation, parameter and value reach it (every dial, toggle, menu item and slider).
        case operation
        /// Brush strokes, lasso points, handle drags and the eyedropper tap: a grammar rule or a Live reply opens the tool.
        case gestureOnly
        /// The overlay style and colour and the sheets' preview modes: they change no document state.
        case viewOnly
    }

    public struct Control: Sendable, Equatable {
        /// "masks.new.sky", "masks.range.low", "select.use.generate".
        public var id: String
        /// A PhotoEditorSession.Tool raw value.
        public var uiTool: String
        public var reach: Reach
        /// .operation: required; .gestureOnly: the op whose grammar or reply opens the tool.
        public var op: OpID?
        /// "where=sky", "low", "use=generate".
        public var param: String?

        public init(_ id: String, uiTool: String, reach: Reach, op: OpID? = nil, param: String? = nil) {
            self.id = id
            self.uiTool = uiTool
            self.reach = reach
            self.op = op
            self.param = param
        }

        /// The key of `param` ("where" for "where=sky").
        public var paramKey: String? {
            param.map { String($0.split(separator: "=", maxSplits: 1).first ?? Substring($0)) }
        }

        /// The value of `param`, nil for a bare key ("sky" for "where=sky").
        public var paramValue: String? {
            guard let param, let index = param.firstIndex(of: "=") else { return nil }
            return String(param[param.index(after: index)...])
        }
    }

    /// The control with that id, nil when there is none.
    public static func control(_ id: String) -> Control? {
        index[id]
    }

    private static let index: [String: Control] = Dictionary(controls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: - Shared lists (the panels read them too, so the panels and the inventory never disagree)

    /// The sources of « Nouveau masque » and of the « + Ajouter / − Soustraire / ∩ Intersecter » menus, in menu
    /// order: an id suffix, and the region a voice names for it (`where`). The linear and radial gradients are the
    /// `top` and `center` regions' defaults, the three ranges those of `color`, `midtones` and `near`: the panel
    /// creates exactly what the voice creates.
    public static let maskSources: [(id: String, region: MaskRegion)] = [
        ("subject", .subject), ("background", .background), ("sky", .sky), ("people", .people),
        ("person", .person), ("face", .face), ("faceSkin", .faceSkin), ("eyes", .eyes), ("lips", .lips), ("teeth", .teeth),
        ("hair", .hair), ("bodySkin", .bodySkin),
        ("object", .object), ("vegetation", .vegetation), ("water", .water),
        ("linear", .top), ("radial", .center),
        ("colorRange", .color), ("luminanceRange", .midtones), ("depthRange", .near),
        ("selection", .selection),
    ]

    /// The Sélection tool's modes: an id suffix and the `what` a voice names (nil: a gesture-only mode).
    public static let selectModes: [(id: String, what: String?)] = [
        ("subject", "subject"), ("sky", "sky"), ("object", "object"), ("quick", nil), ("wand", "wand"), ("lasso", nil), ("colorRange", "color"),
    ]

    /// The colour-range presets of ColorRangeSheet, in the sheet's order: an id suffix and the region that reaches it
    /// (`where`/`what`), or nil for a hue family, reached through `color` (the handler maps a named hue to its preset).
    public static let colorRangePresets: [(id: String, region: MaskRegion?)] = [
        ("skinTones", .skinTones), ("reds", nil), ("oranges", nil), ("yellows", nil), ("greens", nil), ("cyans", nil),
        ("blues", nil), ("magentas", nil), ("shadows", .shadows), ("midtones", .midtones), ("highlights", .highlights),
    ]

    /// ColorRangeSheet's preview modes.
    public static let colorRangePreviews = ["none", "grayscale", "black", "white", "tint"]
    /// SelectAndMaskSheet's view modes.
    public static let refineViews = ["overlay", "onBlack", "onWhite", "blackAndWhite", "outline"]
    /// The overlay menu: the six MaskOverlayStyle raw values, then « Aucune ».
    public static let overlayStyles = ["tint", "rubylith", "outline", "onBlack", "onWhite", "blackAndWhite", "none"]
    /// The curve presets the mask's « Courbe » row offers (ToneCurve.Preset raw values, the catalog's `curve` values).
    public static let curvePresets = ["sCurve", "strongS", "matte", "fade", "brighten", "darken", "invert", "linear"]
    /// « Utiliser la sélection pour »: the `use` values in menu order.
    public static let selectionUses = ["adjust", "mask", "erase", "fill", "recolor", "blur", "cutout", "generate"]

    // MARK: - The inventory

    public static let controls: [Control] = masksControls() + colorRangeControls(tool: "masks") + selectControls() + colorRangeControls(tool: "select")

    private static let maskAdjust: OpID = "maskAdjust"
    private static let maskEdit: OpID = "maskEdit"
    private static let maskDelete: OpID = "maskDelete"
    private static let select: OpID = "select"
    private static let selectionModify: OpID = "selectionModify"
    private static let selectionApply: OpID = "selectionApply"

    private static func masksControls() -> [Control] {
        func op(_ id: String, _ op: OpID, _ param: String?) -> Control { Control("masks.\(id)", uiTool: "masks", reach: .operation, op: op, param: param) }
        func gesture(_ id: String, _ op: OpID = maskAdjust) -> Control { Control("masks.\(id)", uiTool: "masks", reach: .gestureOnly, op: op) }
        func view(_ id: String) -> Control { Control("masks.\(id)", uiTool: "masks", reach: .viewOnly) }
        var list: [Control] = []
        // « Nouveau masque » (and the empty state's tiles, which are the same controls).
        for source in maskSources {
            list.append(op("new.\(source.id)", maskAdjust, "where=\(source.region.rawValue)"))
        }
        list.append(gesture("new.brush"))
        list.append(op("new.person.index", maskAdjust, "index"))
        // An object, tapped or framed on the canvas.
        list.append(gesture("object.tap"))
        list.append(gesture("object.box"))
        // The mask list.
        list += [
            op("list.select", maskEdit, "show"),
            op("list.visible", maskEdit, "visible"),
            op("list.rename", maskEdit, "name"),
            op("list.duplicate", maskEdit, "duplicate"),
            op("list.invert", maskEdit, "invert"),
            op("list.refresh", maskEdit, "refresh"),
            op("list.delete", maskDelete, "ref"),
        ]
        // The selected mask's components: add, subtract or intersect a source; each component's mode, inversion, deletion.
        for mode in CombineMode.allCases {
            list.append(op("component.\(mode.rawValue)", maskEdit, "combine=\(mode.rawValue)"))
            list.append(op("component.mode.\(mode.rawValue)", maskEdit, "componentMode=\(mode.rawValue)"))
        }
        for source in maskSources {
            list.append(op("component.source.\(source.id)", maskEdit, "where=\(source.region.rawValue)"))
        }
        list.append(gesture("component.source.brush", maskEdit))
        list += [
            op("component.invert", maskEdit, "componentInvert"),
            op("component.delete", maskEdit, "componentDelete"),
            op("colorRange.component.fuzziness", maskEdit, "fuzziness"),
        ]
        // Stack rows.
        list += [
            op("stack.feather", maskEdit, "feather"),
            op("stack.expand", maskEdit, "expand"),
            op("stack.density", maskEdit, "density"),
            op("stack.invert", maskEdit, "invert"),
        ]
        // The adjustment: every dial but vignette, the amount, the local colour, the curve and the HSL subset.
        for parameter in MaskAccessibility.dialOrder {
            list.append(op("dial.\(parameter.rawValue)", maskAdjust, "parameter=\(parameter.rawValue)"))
        }
        list += [
            op("amount", maskEdit, "amount"),
            op("color.wheel", maskAdjust, "localColor"),
            op("color.amount", maskAdjust, "localColorAmount"),
        ]
        for preset in curvePresets {
            list.append(op("curve.preset.\(preset)", maskAdjust, "curve=\(preset)"))
        }
        list.append(gesture("curve.points"))
        for band in ColorMixer.Band.allCases {
            let name = band.englishName.lowercased()
            list.append(op("hsl.band.\(name)", maskAdjust, "band=\(name)"))
        }
        list += [
            op("hsl.hue", maskAdjust, "hue"),
            op("hsl.saturation", maskAdjust, "saturation"),
            op("hsl.luminance", maskAdjust, "luminance"),
        ]
        // Luminance and depth ranges.
        list += [
            op("range.low", maskEdit, "low"),
            op("range.high", maskEdit, "high"),
            op("range.smoothness", maskEdit, "smoothness"),
            gesture("range.eyedropper", maskEdit),
            view("range.preview.map"),
        ]
        // The brush and the canvas handles.
        list += [
            gesture("brush.paint"),
            gesture("brush.erase"),
            gesture("brush.size"),
            gesture("brush.feather"),
            gesture("brush.flow"),
            gesture("handles.linear"),
            gesture("handles.radial"),
        ]
        // The overlay.
        for style in overlayStyles { list.append(view("overlay.\(style)")) }
        list.append(view("overlay.color"))
        list.append(view("overlay.whileDragging"))
        return list
    }

    private static func selectControls() -> [Control] {
        func op(_ id: String, _ op: OpID, _ param: String?) -> Control { Control("select.\(id)", uiTool: "select", reach: .operation, op: op, param: param) }
        func gesture(_ id: String, _ op: OpID = select) -> Control { Control("select.\(id)", uiTool: "select", reach: .gestureOnly, op: op) }
        func view(_ id: String) -> Control { Control("select.\(id)", uiTool: "select", reach: .viewOnly) }
        var list: [Control] = []
        for mode in selectModes {
            if let what = mode.what {
                list.append(op("mode.\(mode.id)", select, "what=\(what)"))
            } else {
                list.append(gesture("mode.\(mode.id)"))
            }
        }
        list.append(op("all", select, "what=all"))
        // On the canvas.
        list += [
            gesture("object.tap"),
            gesture("object.box"),
            gesture("quick.stroke"),
            gesture("quick.erase"),
            gesture("quick.size"),
            gesture("wand.tap"),
            gesture("lasso.draw"),
        ]
        // Nouvelle / Ajouter / Soustraire / Intersecter.
        for mode in ["new"] + CombineMode.allCases.map(\.rawValue) {
            list.append(op("combine.\(mode)", select, "mode=\(mode)"))
        }
        // The wand's accessory.
        list += [
            op("wand.tolerance", select, "tolerance"),
            op("wand.sampleSize", select, "sampleSize"),
            op("wand.contiguous", select, "contiguous"),
        ]
        // Modify.
        list += [
            op("modify.invert", selectionModify, "invert"),
            op("modify.grow", selectionModify, "grow"),
            op("modify.shrink", selectionModify, "shrink"),
            op("modify.feather", selectionModify, "feather"),
            op("modify.smooth", selectionModify, "smooth"),
            op("refine", selectionModify, "refine"),
            op("deselect", selectionModify, "deselect"),
            op("chip.deselect", selectionModify, "deselect"),
        ]
        // « Utiliser la sélection pour ».
        for use in selectionUses {
            list.append(op("use.\(use)", selectionApply, "use=\(use)"))
        }
        list += [
            op("use.fill.color", selectionApply, "color"),
            op("use.recolor.color", selectionApply, "color"),
            op("use.blur.amount", selectionApply, "amount"),
            op("use.generate.prompt", selectionApply, "prompt"),
        ]
        // Select & Mask.
        list += [
            op("refine.radius", selectionModify, "radius"),
            op("refine.smooth", selectionModify, "smooth"),
            op("refine.feather", selectionModify, "feather"),
            op("refine.contrast", selectionModify, "contrast"),
            op("refine.shiftEdge", selectionModify, "shiftEdge"),
            op("refine.decontaminate", selectionModify, "decontaminate"),
            op("refine.output.selection", selectionModify, "refine"),
            op("refine.output.mask", selectionApply, "use=mask"),
        ]
        for mode in refineViews { list.append(view("refine.view.\(mode)")) }
        // The overlay.
        for style in overlayStyles { list.append(view("overlay.\(style)")) }
        list.append(view("overlay.color"))
        return list
    }

    /// ColorRangeSheet, opened from Masques (output « Masque local » first) or from Sélection (« Sélection » first).
    private static func colorRangeControls(tool: String) -> [Control] {
        let forMasks = tool == "masks"
        // Creating: maskAdjust for a mask, select for a selection; editing a mask's existing range: maskEdit.
        let create: OpID = forMasks ? maskAdjust : select
        let edit: OpID = forMasks ? maskEdit : select
        let regionKey = forMasks ? "where" : "what"
        func op(_ id: String, _ op: OpID, _ param: String?) -> Control {
            Control("\(tool).colorRange.\(id)", uiTool: tool, reach: .operation, op: op, param: param)
        }
        var list: [Control] = [
            Control("\(tool).colorRange.sample.add", uiTool: tool, reach: .gestureOnly, op: create),
            Control("\(tool).colorRange.sample.subtract", uiTool: tool, reach: .gestureOnly, op: create),
            op("sample.remove", edit, "color"),
            op("fuzziness", edit, "fuzziness"),
        ]
        for preset in colorRangePresets {
            if let region = preset.region {
                list.append(op("preset.\(preset.id)", create, "\(regionKey)=\(region.rawValue)"))
            } else {
                list.append(op("preset.\(preset.id)", create, "color"))
            }
        }
        for mode in colorRangePreviews {
            list.append(Control("\(tool).colorRange.preview.\(mode)", uiTool: tool, reach: .viewOnly))
        }
        list += [
            op("output.mask", maskAdjust, "where=color"),
            op("output.selection", select, "what=color"),
        ]
        return list
    }
}
