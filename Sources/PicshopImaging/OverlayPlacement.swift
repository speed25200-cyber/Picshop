import Foundation
import PicshopCore

/// Where an overlay layer sits on the canvas when it is composited: the normalised centre and the
/// clockwise rotation in degrees. A text layer sits where its element says, because the text tool,
/// hit-testing (`textBounds`) and the executors move `TextElement.center` and turn `.rotation`; every
/// other overlay (image, shape, fill) follows its layer transform. Scale and flips always stay the
/// layer's. Pure, so the rule is tested on Linux; `PhotoRenderer` composites with it.
public enum OverlayPlacement {
    public static func placement(of layer: Layer) -> (center: PSPoint, rotation: Double) {
        if let element = layer.textElement { return (element.center, element.rotation) }
        return (layer.transform.center, layer.transform.rotation)
    }
}
