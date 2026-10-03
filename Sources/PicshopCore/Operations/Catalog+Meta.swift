import Foundation

/// The catalog's entries in order, and the one navigation step a model may write (seek).
/// Undo, redo, compare, versions and styles are tools or dialogue, never apply_edits steps,
/// so they have no entry.
enum CatalogMeta {
    static var all: [OperationSpec] { [seek] }

    static var seek: OperationSpec {
        legacy(.seek, in: [.video], .cut, .refDependent,
               title: t("Go to time", "Aller à un instant"), summary: t("Moves the playhead", "Déplace la tête de lecture")) { s in
            s.params = [Step.seconds(.required, doc: "the time")]
            s.triggers = [
                .fr: ["va à", "secondes", "reviens au début", "place la tête de lecture"],
                .en: ["go to", "jump to", "seconds", "back to the start"],
            ]
            s.examples = [
                fr("va à 10 secondes", ["seconds": 10]),
                fr("reviens au début", ["seconds": 0]),
                en("jump to 30 seconds", ["seconds": 30]),
            ]
            s.verify = [.unverifiable("only the playhead moves")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "cut"
        }
    }
}

extension OperationCatalog {
    /// Every entry, photo first, then video, PDF and meta. Retrieval breaks ties in this order.
    static var entries: [OperationSpec] {
        CatalogPhotoTone.all + CatalogPhotoColor.all + CatalogPhotoRetouch.all + CatalogPhotoGeometry.all + CatalogPhotoText.all
            + CatalogPhotoTable.all + CatalogPhotoLayers.all + CatalogVideoEdit.all + CatalogVideoMagic.all + CatalogVideoAudio.all
            + CatalogPDF.all + CatalogMeta.all
    }
}
