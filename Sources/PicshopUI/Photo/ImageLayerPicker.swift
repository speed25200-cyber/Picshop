#if canImport(SwiftUI) && canImport(UIKit) && canImport(PhotosUI)
import SwiftUI
import Photos
import PhotosUI
import PicshopCore

/// Photo… (W3, §7.8): the system photo picker over the editor. The picked image's data is loaded
/// (`loadTransferable(type: Data.self)`), then the session decodes, downsizes and writes it off the main actor
/// (`ImageLayerImporter.importImage`) and adds it above the selected layer at 80 % of the canvas's shorter side, with
/// transform mode on it. The library's identifier is kept, so the layer remembers where it came from.
struct ImageLayerPicker: ViewModifier {
    let session: PhotoEditorSession
    @State private var item: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: Binding(get: { session.layerState.showsImagePicker },
                                               set: { session.layerState.showsImagePicker = $0 }),
                          selection: $item, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: item) { _, picked in
                guard let picked else { return }
                item = nil
                let identifier = picked.itemIdentifier
                Task {
                    let data: Data?
                    do {
                        data = try await picked.loadTransferable(type: Data.self)
                    } catch {
                        data = nil
                    }
                    guard let data else {
                        Haptics.error()
                        session.showToast(L("That picture couldn't be read."), isError: true)
                        return
                    }
                    await session.addImageLayer(data: data, localIdentifier: identifier)
                }
            }
    }
}

extension View {
    /// The image-layer picker, presented by `layerState.showsImagePicker`.
    func imageLayerPicker(_ session: PhotoEditorSession) -> some View {
        modifier(ImageLayerPicker(session: session))
    }
}
#endif
