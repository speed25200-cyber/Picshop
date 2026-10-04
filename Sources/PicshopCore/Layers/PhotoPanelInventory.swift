import Foundation

/// Every control of every photo tool except Masques and Sélection (those are MaskPanelInventory), with how a voice
/// or a model reaches it (I1 at W3 level, the W2 rule on all photo panels). L3 fills it; L4's PanelInventoryTests
/// reads it against the catalog.
///
/// Ids are "<tool>.<group>.<item>" ("layers.add.fill.gradient", "export.format.psd", "canvas.layer.pick"); `uiTool` is
/// a PhotoEditorSession.Tool raw value, "export" (the export sheet) or "canvas" (gestures on the picture itself). The
/// views tag their controls with the same ids (`accessibilityIdentifier`), and an `openTool:<id>` effect opens the
/// control's tool in the mode its gesture needs. `param` is "key=value" for an enumeration value and the bare key
/// otherwise, as in MaskPanelInventory.
///
/// Reach (W3 §0):
/// - `.operation`: a catalog operation, parameter and value reach it. Generated ParamSpec rows reach it by
///   construction. The adjustment-layer and fill-layer panels name the edit operation (`fillLayer`, the tone and
///   colour ops), never a creation one: their rows bind the layer in `fixedArgs`.
/// - `.gestureOnly`: transform handle drags, the layer-mask brush, column drags, canvas picks, the eyedropper.
/// - `.viewOnly`: guides, overlays, thumbnails, the column's visibility, the transparency checkerboard.
public enum PhotoPanelInventory {
    public typealias Control = MaskPanelInventory.Control

    /// The control with that id, nil when there is none.
    public static func control(_ id: String) -> Control? {
        index[id]
    }

    private static let index: [String: Control] = Dictionary(controls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: - Shared lists (the panels read them too, so the panels and the inventory never disagree)

    /// The lock segmented control (« Aucun · Position · Pixels · Transparence · Tout »): `layerProperties.lock` values.
    public static let lockChoices: [(value: String, lock: LayerLockOptions)] = [
        ("none", []), ("position", [.position]), ("pixels", [.pixels]), ("transparency", [.transparency]), ("all", .all),
    ]

    /// The `layerProperties.lock` value of a lock (a mixed partial lock reads as its strongest part).
    public static func lockValue(_ lock: LayerLockOptions) -> String {
        if lock.isSuperset(of: .all) { return "all" }
        if lock.contains(.pixels) { return "pixels" }
        if lock.contains(.position) { return "position" }
        if lock.contains(.transparency) { return "transparency" }
        return "none"
    }

    /// The export sheet's formats, in its strip's order.
    public static let exportFormats: [ExportFileFormat] = [.jpeg, .heic, .png, .tiff, .pdf, .psd]
    /// Every bit depth some format writes (`exportPhoto.bitDepth`).
    public static let exportBitDepths = [8, 10, 16]
    /// The size menu: `exportPhoto.size` values and the long side each one keeps (nil: the full size).
    public static let exportSizes: [(value: String, longSide: Int?)] = [("full", nil), ("4096", 4096), ("2048", 2048), ("1080", 1080)]
    /// The presets `exportPhoto.preset` opens the sheet on.
    public static let exportPresets = ["instagram", "print", "web"]
    /// The colour spaces of the sheet (`exportPhoto.colorSpace`).
    public static let exportColorSpaces = ["displayP3", "sRGB"]

    /// The photo recipes of Magie « Recettes » (vlogCleanup lives in the video Magic panel).
    public static let photoRecipes: [RecipeName] = [.instagramPost, .productPhoto, .portraitRetouch]
    /// Post Instagram's formats (`recipe.format`).
    public static let instagramFormats = ["portrait4x5", "square", "story9x16"]

    /// The transform mode chips (« Libre, Proportionnel, Incliner, Déformer, Perspective ») and the `layerTransform.mode`
    /// value each one has; « Proportionnel » is a drag modifier with no operation value.
    public static let transformModes: [(mode: TransformMode, value: String?)] = [
        (.free, "free"), (.uniform, nil), (.skew, "skew"), (.distort, "distort"), (.perspective, "perspective"),
    ]

    /// The transform rows: `layerTransform` params in the inspector's order (X, Y, Échelle, Largeur, Hauteur,
    /// Rotation, Inclinaison X/Y).
    public static let transformRows = ["x", "y", "scale", "scaleX", "scaleY", "rotation", "skewX", "skewY"]

    /// The curve presets of Courbes (ToneCurve.Preset raw values, the `curves.preset` values).
    public static let curvePresets = ["sCurve", "strongS", "matte", "fade", "brighten", "darken", "invert"]
    /// The tone channels.
    public static let toneChannels = ["rgb", "red", "green", "blue"]
    /// Levels' handles: `levels` params.
    public static let levelsHandles = ["black", "gamma", "white", "outBlack", "outWhite"]
    /// The colour wheels' ranges.
    public static let gradeRanges = ["shadows", "midtones", "highlights"]

    // MARK: - The inventory

    public static let controls: [Control] = layersControls() + layerPanelsControls() + toneControls() + colorControls() + looksControls()
        + retouchControls() + cropControls() + textAndShapeControls() + magicControls() + exportControls() + canvasControls()

    private static func op(_ id: String, _ tool: String, _ op: OpID, _ param: String? = nil) -> Control {
        Control(id, uiTool: tool, reach: .operation, op: op, param: param)
    }

    private static func gesture(_ id: String, _ tool: String, _ op: OpID? = nil, _ param: String? = nil) -> Control {
        Control(id, uiTool: tool, reach: .gestureOnly, op: op, param: param)
    }

    private static func view(_ id: String, _ tool: String) -> Control {
        Control(id, uiTool: tool, reach: .viewOnly)
    }

    // MARK: Calques: the column, the inspector's list, its menus and the multi-selection

    private static func layersControls() -> [Control] {
        let t = "layers"
        var list: [Control] = []
        // ＋ menu.
        list.append(op("layers.add.photo", t, "addImageLayer"))
        list.append(op("layers.add.fill.solid", t, "addFillLayer", "fill=solid"))
        list.append(op("layers.add.fill.gradient", t, "addFillLayer", "fill=gradient"))
        for kind in AdjustmentLayerKind.allCases {
            list.append(op("layers.add.adjustment.\(kind.rawValue)", t, "addAdjustmentLayer", "kind=\(kind.rawValue)"))
        }
        list.append(op("layers.add.group", t, "groupLayers", "refs"))
        list.append(op("layers.add.viaCopy", t, "layerVia", "mode=copy"))
        list.append(op("layers.add.viaCut", t, "layerVia", "mode=cut"))
        list.append(op("layers.add.via.selection", t, "layerVia", "useSelection"))
        list.append(op("layers.add.via.subject", t, "layerVia", "where=subject"))
        list.append(op("layers.add.via.mask", t, "layerVia", "ref"))
        list.append(op("layers.add.text", t, "addText", "text"))
        list.append(gesture("layers.add.shape", t))
        // ⋯ menu.
        list += [
            op("layers.more.duplicate", t, "duplicateLayer", "ref"),
            op("layers.more.mergeDown", t, "mergeLayers", "mode=down"),
            op("layers.more.mergeVisible", t, "mergeLayers", "mode=visible"),
            op("layers.more.stamp", t, "mergeLayers", "mode=stamp"),
            op("layers.more.flatten", t, "mergeLayers", "mode=flatten"),
            op("layers.more.group", t, "groupLayers", "refs"),
            op("layers.more.ungroup", t, "groupLayers", "ungroup"),
            op("layers.more.transform", t, "layerTransform", "mode=free"),
            op("layers.more.delete", t, "deleteLayer", "ref"),
        ]
        // Rows (inspector) and cells (column).
        list += [
            op("layers.row.select", t, "selectLayer", "ref"),
            op("layers.row.opacity", t, "layerOpacity", "opacity"),
            op("layers.row.visible", t, "layerVisibility", "visible"),
            op("layers.row.lock", t, "layerProperties", "lock"),
            op("layers.row.delete", t, "deleteLayer", "ref"),
            op("layers.row.collapse", t, "groupLayers", "collapse"),
            op("layers.row.mask.toggle", t, "layerMask", "action=disable"),
            gesture("layers.row.reorder", t, "layerOrder"),
            op("layers.column.select", t, "selectLayer", "ref"),
            op("layers.column.visible", t, "layerVisibility", "visible"),
            gesture("layers.column.reorder", t, "layerOrder"),
            view("layers.column.show", t),
            view("layers.thumbnail.size", t),
        ]
        // « Sélectionner » and the multi-selection bar: one history step per action.
        list += [
            op("layers.select.many", t, "groupLayers", "refs"),
            op("layers.selection.group", t, "groupLayers", "refs"),
            op("layers.selection.merge", t, "mergeLayers", "mode=selected"),
            op("layers.selection.duplicate", t, "duplicateLayer", "ref"),
            op("layers.selection.hide", t, "layerVisibility", "visible"),
            op("layers.selection.delete", t, "deleteLayer", "ref"),
        ]
        for alignment in LayerAlignment.allCases {
            list.append(op("layers.align.\(alignment.rawValue)", t, "layerTransform", "align=\(alignment.rawValue)"))
        }
        // The properties section (generated ParamSpec rows; the blend picker one entry per mode).
        list += [
            op("layers.props.opacity", t, "layerOpacity", "opacity"),
            op("layers.props.fill", t, "layerProperties", "fill"),
            op("layers.props.clip", t, "layerClip", "clip"),
            op("layers.props.passThrough", t, "layerProperties", "passThrough"),
            op("layers.props.name", t, "layerProperties", "name"),
        ]
        for mode in BlendMode.allCases {
            list.append(op("layers.props.blend.\(mode.rawValue)", t, "layerBlend", "mode=\(mode.rawValue)"))
        }
        for choice in lockChoices {
            list.append(op("layers.props.lock.\(choice.value)", t, "layerProperties", "lock=\(choice.value)"))
        }
        // Free transform: the rows, the mode chips, the handles, the actions.
        for row in transformRows {
            list.append(op("layers.transform.\(row)", t, "layerTransform", row))
        }
        for entry in transformModes {
            if let value = entry.value {
                list.append(op("layers.transform.mode.\(entry.mode.rawValue)", t, "layerTransform", "mode=\(value)"))
            } else {
                list.append(gesture("layers.transform.mode.\(entry.mode.rawValue)", t, "layerTransform"))
            }
        }
        list += [
            gesture("layers.transform.handles", t, "layerTransform"),
            op("layers.transform.corners", t, "layerTransform", "corners"),
            op("layers.transform.reset", t, "layerTransform", "fit=reset"),
            op("layers.transform.fit", t, "layerTransform", "fit=fit"),
            op("layers.transform.fill", t, "layerTransform", "fit=fill"),
            op("layers.transform.flip.horizontal", t, "layerTransform", "flip=horizontal"),
            op("layers.transform.flip.vertical", t, "layerTransform", "flip=vertical"),
            view("layers.guides.show", t),
        ]
        return list
    }

    // MARK: Calques: the layer mask, the fill and adjustment layer panels

    private static func layerPanelsControls() -> [Control] {
        let t = "layers"
        var list: [Control] = []
        // LayerMaskControls.
        list += [
            op("layers.mask.add.revealAll", t, "layerMask", "action=add"),
            op("layers.mask.add.hideAll", t, "layerMask", "reveal"),
            op("layers.mask.add.selection", t, "layerMask", "useSelection"),
            op("layers.mask.add.subject", t, "layerMask", "where=subject"),
            gesture("layers.mask.paint", t, "layerMask", "action=paint"),
            gesture("layers.mask.paint.erase", t, "layerMask"),
            gesture("layers.mask.brush.size", t, "layerMask"),
            gesture("layers.mask.brush.hardness", t, "layerMask"),
            gesture("layers.mask.brush.flow", t, "layerMask"),
            op("layers.mask.invert", t, "layerMask", "action=invert"),
            op("layers.mask.feather", t, "layerMask", "feather"),
            op("layers.mask.density", t, "layerMask", "density"),
            op("layers.mask.expand", t, "layerMask", "expand"),
            op("layers.mask.link", t, "layerProperties", "maskLinked"),
            op("layers.mask.disable", t, "layerMask", "action=disable"),
            op("layers.mask.enable", t, "layerMask", "action=enable"),
            op("layers.mask.apply", t, "layerMask", "action=apply"),
            op("layers.mask.delete", t, "layerMask", "action=delete"),
            view("layers.mask.overlay", t),
        ]
        // FillLayerPanel and GradientEditor (rows of `fillLayer`, the edit op).
        list += [
            op("layers.fill.color", t, "fillLayer", "color"),
            op("layers.fill.color2", t, "fillLayer", "color2"),
            op("layers.fill.stops", t, "fillLayer", "stops"),
            op("layers.fill.angle", t, "fillLayer", "angle"),
            op("layers.fill.scale", t, "fillLayer", "scale"),
            op("layers.fill.reverse", t, "fillLayer", "reverse"),
            op("layers.fill.dither", t, "fillLayer", "dither"),
            gesture("layers.fill.handles", t, "fillLayer"),
        ]
        for style in GradientFill.Style.allCases {
            list.append(op("layers.fill.style.\(style.rawValue)", t, "fillLayer", "style=\(style.rawValue)"))
        }
        // AdjustmentLayerPanel, by kind: the tone and colour edit ops with the layer bound.
        for parameter in AdjustmentParameter.allCases where parameter != .vignette {
            list.append(op("layers.adjustment.light.\(parameter.rawValue)", t, "adjust", "parameter=\(parameter.rawValue)"))
        }
        for preset in curvePresets {
            list.append(op("layers.adjustment.curves.preset.\(preset)", t, "curves", "preset=\(preset)"))
        }
        list.append(gesture("layers.adjustment.curves.points", t, "curves"))
        for handle in levelsHandles {
            list.append(op("layers.adjustment.levels.\(handle)", t, "levels", handle))
        }
        list.append(op("layers.adjustment.levels.auto", t, "levels", "auto"))
        for band in ColorMixer.Band.allCases {
            let name = band.englishName.lowercased()
            list.append(op("layers.adjustment.hsl.band.\(name)", t, "hsl", "band=\(name)"))
        }
        list += [
            op("layers.adjustment.hsl.hue", t, "hsl", "hue"),
            op("layers.adjustment.hsl.saturation", t, "hsl", "saturation"),
            op("layers.adjustment.hsl.luminance", t, "hsl", "luminance"),
        ]
        for range in gradeRanges {
            list.append(op("layers.adjustment.colorGrade.\(range)", t, "colorGrade", "range=\(range)"))
        }
        list += [
            op("layers.adjustment.colorGrade.hue", t, "colorGrade", "hue"),
            op("layers.adjustment.colorGrade.amount", t, "colorGrade", "amount"),
            op("layers.adjustment.colorGrade.luminance", t, "colorGrade", "luminance"),
            op("layers.adjustment.lut.intensity", t, "lutIntensity", "amount"),
            op("layers.adjustment.look.intensity", t, "applyLook", "amount"),
        ]
        for preset in FilterPreset.allCases where preset != .original {
            list.append(op("layers.adjustment.look.\(preset.rawValue)", t, "applyLook", "look=\(preset.rawValue)"))
        }
        return list
    }

    // MARK: Réglages, Courbes, Niveaux (each with its W3 target chip)

    private static func toneControls() -> [Control] {
        var list: [Control] = []
        for parameter in AdjustmentParameter.allCases {
            list.append(op("adjust.dial.\(parameter.rawValue)", "adjust", "adjust", "parameter=\(parameter.rawValue)"))
        }
        list += [
            op("adjust.auto", "adjust", "autoEnhance"),
            op("adjust.portraitLight", "adjust", "relight"),
            op("adjust.reset", "adjust", "adjust", "amountMode=absolute"),
            op("adjust.target", "adjust", "adjust", "layer"),
        ]
        for channel in toneChannels {
            list.append(op("curves.channel.\(channel)", "curves", "curves", "channel=\(channel)"))
            list.append(op("levels.channel.\(channel)", "levels", "levels", "channel=\(channel)"))
        }
        for preset in curvePresets {
            list.append(op("curves.preset.\(preset)", "curves", "curves", "preset=\(preset)"))
        }
        list += [
            gesture("curves.points", "curves", "curves"),
            op("curves.reset", "curves", "curves", "preset=linear"),
            view("curves.histogram", "curves"),
            op("curves.target", "curves", "curves", "layer"),
        ]
        for handle in levelsHandles {
            list.append(op("levels.\(handle)", "levels", "levels", handle))
        }
        list += [
            op("levels.auto", "levels", "autoTone"),
            op("levels.reset", "levels", "levels", "auto"),
            view("levels.preview.clipping", "levels"),
            view("levels.histogram", "levels"),
            op("levels.target", "levels", "levels", "layer"),
        ]
        return list
    }

    // MARK: Couleur (mixer, wheels, LUT)

    private static func colorControls() -> [Control] {
        var list: [Control] = []
        for band in ColorMixer.Band.allCases {
            let name = band.englishName.lowercased()
            list.append(op("color.mixer.band.\(name)", "color", "hsl", "band=\(name)"))
        }
        list += [
            op("color.mixer.hue", "color", "hsl", "hue"),
            op("color.mixer.saturation", "color", "hsl", "saturation"),
            op("color.mixer.luminance", "color", "hsl", "luminance"),
        ]
        for range in gradeRanges {
            list.append(op("color.wheels.\(range)", "color", "colorGrade", "range=\(range)"))
        }
        list += [
            op("color.wheels.hue", "color", "colorGrade", "hue"),
            op("color.wheels.amount", "color", "colorGrade", "amount"),
            op("color.wheels.luminance", "color", "colorGrade", "luminance"),
            op("color.wheels.balance", "color", "colorGrade", "balance"),
            gesture("color.lut.import", "color", "lutIntensity"),
            op("color.lut.intensity", "color", "lutIntensity", "amount"),
            op("color.lut.remove", "color", "removeLUT"),
            op("color.target", "color", "hsl", "layer"),
        ]
        return list
    }

    // MARK: Filtres

    private static func looksControls() -> [Control] {
        var list: [Control] = []
        for preset in FilterPreset.allCases {
            list.append(op("looks.preset.\(preset.rawValue)", "looks", "applyLook", "look=\(preset.rawValue)"))
        }
        list.append(op("looks.intensity", "looks", "applyLook", "amount"))
        return list
    }

    // MARK: Effacer, Précis, Détourage, Flou portrait

    private static func retouchControls() -> [Control] {
        [
            gesture("erase.tap", "erase", "removeObject"),
            gesture("erase.brush", "erase", "removeObject"),
            gesture("erase.brush.size", "erase", "removeObject"),
            op("erase.object", "erase", "removeObject", "target"),
            op("erase.all", "erase", "removeObject", "all"),
            op("erase.cleanUp", "erase", "cleanUp"),
            gesture("precise.wand", "precise"),
            gesture("precise.lasso", "precise"),
            op("precise.generate", "precise", "generativeFill", "text"),
            gesture("precise.pixelBrush", "precise"),
            gesture("precise.clone", "precise"),
            gesture("precise.brush.size", "precise"),
            gesture("precise.hardness", "precise"),
            gesture("precise.paintColor", "precise"),
            op("cutout.remove", "cutout", "removeBackground"),
            op("cutout.replace", "cutout", "replaceBackground", "background"),
            op("cutout.blur", "cutout", "blurBackground", "amount"),
            gesture("focus.tap", "focus", "lensFocus"),
            op("focus.aperture", "focus", "lensFocus", "aperture"),
            op("focus.remove", "focus", "lensFocus", "aperture"),
        ]
    }

    // MARK: Recadrer

    private static func cropControls() -> [Control] {
        var list: [Control] = []
        for aspect in AspectPreset.allCases {
            list.append(op("crop.aspect.\(aspect.rawValue)", "crop", "crop", "aspect=\(aspect.rawValue)"))
        }
        list += [
            gesture("crop.frame", "crop", "crop"),
            op("crop.straighten", "crop", "straighten", "degrees"),
            op("crop.perspective.vertical", "crop", "perspective", "vertical"),
            op("crop.perspective.horizontal", "crop", "perspective", "horizontal"),
            op("crop.best", "crop", "autoCrop"),
            op("crop.expand", "crop", "expandCanvas"),
            op("crop.rotate", "crop", "rotate", "degrees"),
            op("crop.flip.horizontal", "crop", "flip", "flipAxis=horizontal"),
            op("crop.flip.vertical", "crop", "flip", "flipAxis=vertical"),
            op("crop.rightWayUp", "crop", "resetOrientation"),
            op("crop.autoLevel", "crop", "straighten"),
        ]
        return list
    }

    // MARK: Texte, Formes

    private static func textAndShapeControls() -> [Control] {
        var list: [Control] = [
            op("text.add", "text", "addText", "text"),
            op("text.color", "text", "editText", "color"),
            op("text.delete", "text", "removeText", "ref"),
            gesture("text.move", "text", "moveText"),
            op("text.behind", "text", "textBehind"),
        ]
        for font in ["sans", "serif", "mono", "rounded"] {
            list.append(op("text.font.\(font)", "text", "editText", "font=\(font)"))
        }
        list += [
            gesture("shapes.place", "shapes"),
            gesture("shapes.kind", "shapes"),
            gesture("shapes.move", "shapes"),
            gesture("shapes.color", "shapes"),
            gesture("shapes.outline", "shapes"),
            op("shapes.opacity", "shapes", "layerOpacity", "opacity"),
            op("shapes.delete", "shapes", "deleteLayer", "ref"),
        ]
        return list
    }

    // MARK: Magie (Objets and the « Recettes » row)

    private static func magicControls() -> [Control] {
        var list: [Control] = [
            op("magic.object.erase", "magic", "removeObject", "target"),
            op("magic.object.move", "magic", "moveObject", "degrees"),
            op("magic.object.centre", "magic", "moveObject", "placement=center"),
            op("magic.object.blur", "magic", "blurObject", "target"),
            gesture("magic.object.tap", "magic", "removeObject"),
            op("magic.enhance", "magic", "autoEnhance"),
            op("magic.cleanup", "magic", "cleanUp"),
            op("magic.expand", "magic", "expandCanvas"),
            op("magic.behind", "magic", "textBehind"),
            op("magic.match", "magic", "matchColor"),
            op("magic.relight", "magic", "relight"),
            op("magic.cutout", "magic", "removeBackground"),
            op("magic.upscale", "magic", "upscale", "amount"),
        ]
        list += [
            op("magic.recipe.instagram", "magic", "recipe", "name=instagramPost"),
            op("magic.recipe.product", "magic", "recipe", "name=productPhoto"),
            op("magic.recipe.portrait", "magic", "recipe", "name=portraitRetouch"),
            op("magic.recipe.product.background", "magic", "recipe", "background"),
            op("magic.recipe.portrait.strength", "magic", "recipe", "strength"),
        ]
        for format in instagramFormats {
            list.append(op("magic.recipe.instagram.\(format)", "magic", "recipe", "format=\(format)"))
        }
        return list
    }

    // MARK: Exporter (the sheet)

    private static func exportControls() -> [Control] {
        let t = "export"
        var list: [Control] = []
        for format in exportFormats {
            list.append(op("export.format.\(format.rawValue)", t, "exportPhoto", "format=\(format.rawValue)"))
        }
        for depth in exportBitDepths {
            list.append(op("export.bitDepth.\(depth)", t, "exportPhoto", "bitDepth=\(depth)"))
        }
        for space in exportColorSpaces {
            list.append(op("export.colorSpace.\(space)", t, "exportPhoto", "colorSpace=\(space)"))
        }
        for size in exportSizes {
            list.append(op("export.size.\(size.value)", t, "exportPhoto", "size=\(size.value)"))
        }
        for preset in exportPresets {
            list.append(op("export.preset.\(preset)", t, "exportPhoto", "preset=\(preset)"))
        }
        list += [
            op("export.layers", t, "exportPhoto", "layers"),
            // Writing a file is the person's own tap (exportPhoto opens the sheet; it never exports silently).
            gesture("export.save.photos", t, "exportPhoto"),
            gesture("export.save.files", t, "exportPhoto"),
            gesture("export.share", t, "exportPhoto"),
            gesture("export.quality", t, "exportPhoto"),
            gesture("export.location", t, "exportPhoto"),
            gesture("export.cancel", t, "exportPhoto"),
        ]
        return list
    }

    // MARK: The picture itself

    private static func canvasControls() -> [Control] {
        [
            gesture("canvas.layer.pick", "canvas", "selectLayer"),
            gesture("canvas.layer.menu", "canvas", "selectLayer"),
            gesture("canvas.layer.drag", "canvas", "layerTransform"),
            view("canvas.transparency", "canvas"),
        ]
    }
}
