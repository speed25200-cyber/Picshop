#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

// The Layers inspector's header menus (W3, §7.6). Every item runs one session path (one history step), and carries the
// id PhotoPanelInventory gives its control, so the voice and the panels name the same thing.

/// ＋: Photo…, Calque de remplissage ▸, Calque de réglage ▸, Groupe, Calque par copier ▸, Calque par couper ▸, Texte,
/// Forme.
struct LayerAddMenu: View {
    let session: PhotoEditorSession

    var body: some View {
        let pro = session.proLayersEnabled
        Menu {
            Button {
                session.openImageLayerPicker()
            } label: {
                Label(L("Photo…"), systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("layers.add.photo")
            Menu {
                Button {
                    session.addFillLayer(gradient: false)
                } label: {
                    Label(L("Solid colour"), systemImage: "square.fill")
                }
                .accessibilityIdentifier("layers.add.fill.solid")
                if pro {
                    Button {
                        session.addFillLayer(gradient: true)
                    } label: {
                        Label(L("Gradient"), systemImage: "square.bottomhalf.filled")
                    }
                    .accessibilityIdentifier("layers.add.fill.gradient")
                }
            } label: {
                Label(L("Fill layer"), systemImage: "drop.fill")
            }
            Menu {
                ForEach(AdjustmentLayerKind.allCases, id: \.self) { kind in
                    Button {
                        session.addAdjustmentLayer(kind)
                    } label: {
                        Label(Self.name(kind), systemImage: PhotoEditorSession.adjustmentSymbol(kind))
                    }
                    .disabled(kind == .lut && !session.canAddLUTLayer)
                    .accessibilityIdentifier("layers.add.adjustment.\(kind.rawValue)")
                }
            } label: {
                Label(L("Adjustment layer"), systemImage: "circle.lefthalf.filled")
            }
            if pro {
                Button {
                    session.groupLayers(session.actedLayers.filter { $0 != session.document.baseLayerID })
                } label: {
                    Label(L("Group"), systemImage: "folder.badge.plus")
                }
                .disabled(!canGroup)
                .accessibilityIdentifier("layers.add.group")
                LayerViaMenu(session: session, cut: false)
                LayerViaMenu(session: session, cut: true)
            }
            Divider()
            Button {
                session.activeTool = .text
            } label: {
                Label(L("Text"), systemImage: "textformat")
            }
            .accessibilityIdentifier("layers.add.text")
            Button {
                session.activeTool = .shapes
            } label: {
                Label(L("Shape"), systemImage: "square.on.circle")
            }
            .accessibilityIdentifier("layers.add.shape")
        } label: {
            LayerHeaderGlyph(symbol: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(L("Add a layer"))
    }

    /// Grouper needs a layer other than the photo.
    private var canGroup: Bool {
        session.actedLayers.contains { $0 != session.document.baseLayerID && session.document.layer(id: $0)?.isGroup == false }
    }

    static func name(_ kind: AdjustmentLayerKind) -> String {
        psPrefersFrench ? kind.frenchName : kind.englishName
    }
}

/// « Calque par copier ▸ » / « Calque par couper ▸ »: from the selection, the subject or one of the active image
/// layer's masks (« depuis : Sélection · Sujet · Masque a1 »).
struct LayerViaMenu: View {
    let session: PhotoEditorSession
    let cut: Bool

    var body: some View {
        let document = session.document
        let masks = document.localAdjustments
        Menu {
            Section(L("From")) {
                Button {
                    session.layerVia(cut: cut, from: .selection)
                } label: {
                    Label(L("Selection"), systemImage: "lasso")
                }
                .disabled(document.selection == nil)
                .accessibilityIdentifier("layers.add.via.selection")
                Button {
                    session.layerVia(cut: cut, from: .subject)
                } label: {
                    Label(L("Subject"), systemImage: "person.crop.rectangle")
                }
                .accessibilityIdentifier("layers.add.via.subject")
                ForEach(masks, id: \.id) { mask in
                    Button {
                        session.layerVia(cut: cut, from: .mask(mask.id))
                    } label: {
                        Label(String(format: L("Mask %@"), session.maskName(mask)), systemImage: "circle.rectangle.dashed")
                    }
                    .accessibilityIdentifier("layers.add.via.mask")
                }
            }
        } label: {
            Label(cut ? L("Layer via cut") : L("Layer via copy"), systemImage: cut ? "scissors" : "doc.on.doc")
        }
        .accessibilityIdentifier(cut ? "layers.add.viaCut" : "layers.add.viaCopy")
    }
}

/// ⋯: Dupliquer, Fusionner avec le calque inférieur, Fusionner les calques visibles, Tampon des calques visibles,
/// Aplatir l'image, Grouper / Dissocier, Transformer, Supprimer.
struct LayerMoreMenu: View {
    let session: PhotoEditorSession

    var body: some View {
        let document = session.document
        let selected = document.selectedLayer
        let isBase = selected?.id == document.baseLayerID
        let pro = session.proLayersEnabled
        let acted = session.actedLayers
        Menu {
            Button {
                session.duplicateLayers(acted)
            } label: {
                Label(L("Duplicate"), systemImage: "plus.square.on.square")
            }
            .disabled(acted.isEmpty)
            .accessibilityIdentifier("layers.more.duplicate")
            if pro {
                Button {
                    if let id = selected?.id { session.mergeDown(id) }
                } label: {
                    Label(L("Merge down"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(selected == nil || isBase)
                .accessibilityIdentifier("layers.more.mergeDown")
                Button {
                    session.mergeVisible()
                } label: {
                    Label(L("Merge visible layers"), systemImage: "square.stack.3d.down.forward")
                }
                .disabled(document.layers.count < 2)
                .accessibilityIdentifier("layers.more.mergeVisible")
                Button {
                    session.stampVisible()
                } label: {
                    Label(L("Stamp visible layers"), systemImage: "square.stack.3d.up")
                }
                .disabled(document.layers.count < 2)
                .accessibilityIdentifier("layers.more.stamp")
                Button {
                    session.requestFlatten()
                } label: {
                    Label(L("Flatten image"), systemImage: "square.3.layers.3d.down.right")
                }
                .disabled(document.layers.count < 2)
                .accessibilityIdentifier("layers.more.flatten")
                if let selected, selected.isGroup {
                    Button {
                        session.ungroup(selected.id)
                    } label: {
                        Label(L("Ungroup"), systemImage: "folder.badge.minus")
                    }
                    .accessibilityIdentifier("layers.more.ungroup")
                } else {
                    Button {
                        session.groupLayers(acted.filter { $0 != document.baseLayerID })
                    } label: {
                        Label(L("Group"), systemImage: "folder.badge.plus")
                    }
                    .disabled(selected == nil || isBase)
                    .accessibilityIdentifier("layers.more.group")
                }
            }
            if FeatureFlags.isOn(.freeTransform) {
                Button {
                    if let id = selected?.id { session.beginTransformMode(id) }
                } label: {
                    Label(L("Transform"), systemImage: "skew")
                }
                .disabled(selected == nil || isBase || !(selected?.isImage == true || selected?.isText == true || selected?.isShape == true))
                .accessibilityIdentifier("layers.more.transform")
            }
            Divider()
            Button(role: .destructive) {
                session.requestDeleteLayers(acted.filter { $0 != document.baseLayerID })
            } label: {
                Label(L("Delete"), systemImage: "trash")
            }
            .disabled(selected == nil || isBase)
            .accessibilityIdentifier("layers.more.delete")
        } label: {
            LayerHeaderGlyph(symbol: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(L("More layer actions"))
    }
}

/// A round 34-point header control (the chip fill; never glass on glass).
struct LayerHeaderGlyph: View {
    let symbol: String
    var isActive = false

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(isActive ? Color.psOnAction : Color.psTextPrimary)
            .frame(width: PanelChipStyle.height, height: PanelChipStyle.height)
            .background(Circle().fill(isActive ? Color.psActionPrimary : Color.psFillControl))
            .frame(minWidth: PSMetrics.control, minHeight: PSMetrics.control)
            .contentShape(Rectangle())
    }
}
#endif
