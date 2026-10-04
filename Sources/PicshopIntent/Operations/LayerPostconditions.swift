import Foundation
import PicshopCore

/// W3 (§8.3): the postconditions of a layer operation that apply to one call. A spec lists every check its calls may
/// need (mergeLayers: the layer count down, or up for a stamp; layerMask: the mask changed, its coverage, the
/// composite after an apply); the call's own arguments pick the ones that hold, so a stamp is never failed for adding
/// a layer and a lock change is never checked on the fill. The structural checks (`OperationPostconditions`) and the
/// pixel plan (`PixelPostconditions`) both read this list.
public enum LayerPostconditions {
    /// The spec's postconditions this call answers for, in catalog order.
    public static func conditions(for call: OperationCall, spec: OperationSpec) -> [Postcondition] {
        let verify = spec.verify
        func structural(_ probe: StateProbe) -> [Postcondition] {
            verify.filter { if case .structural(probe, _) = $0 { return true } else { return false } }
        }
        func pixels(_ probe: PixelProbe) -> [Postcondition] {
            verify.filter { if case .pixels(probe.rawValue, _) = $0 { return true } else { return false } }
        }
        func unverifiable() -> [Postcondition] {
            verify.filter { if case .unverifiable = $0 { return true } else { return false } }
        }
        switch call.id.raw {
        case "mergeLayers":
            let stamp = call.args["mode"]?.string == "stamp"
            return verify.filter { condition in
                guard case .structural(.layerCount, let expectation) = condition else { return true }
                return stamp ? expectation == .increased : expectation == .decreased
            }
        case "layerMask":
            switch call.args["do"]?.string ?? "add" {
            case "paint": return unverifiable()
            case "add", "edit": return structural(.layerMasks) + pixels(.layerMaskCoverageInRange)
            case "apply": return structural(.layerMasks) + pixels(.compositeUnchanged)
            default: return structural(.layerMasks)
            }
        case "layerProperties":
            var result: [Postcondition] = []
            if call.args["fill"] != nil { result += structural(.layerFillOpacity) }
            if call.args["lock"] != nil { result += structural(.layerLock) }
            return result.isEmpty ? unverifiable() : result
        case "layerTransform":
            let moves = PhotoOperationHandlers.transformFields.contains { call.args[$0] != nil }
            return moves ? structural(.layerTransform) : unverifiable()
        case "groupLayers":
            let restructures = call.args["refs"] != nil || call.args["all"] != nil || call.args["ungroup"]?.bool == true
                || (call.args["collapse"] == nil && call.args["name"] == nil)
            return restructures ? verify : [.unverifiable("folds or names the group")]
        default:
            return verify
        }
    }

    /// Whether the call's conditions include pixel checks.
    public static func hasPixelChecks(_ call: OperationCall, spec: OperationSpec) -> Bool {
        conditions(for: call, spec: spec).contains { if case .pixels = $0 { return true } else { return false } }
    }

    /// The pixel plan of a W3 layer call (§8.3): the composite unchanged after a merge, a stamp, a via copy/cut or a
    /// mask applied; changed after a new fill or adjustment layer (a neutral adjustment layer changes nothing yet:
    /// unverifiable); the new or edited layer mask covering 0.2 %–98 % of its layer. L2 measures before and after on
    /// 256 px proxies; a merge whose pixels are not rendered yet is unverifiable (`PixelPostconditions.expensiveStep`).
    static func pixelPlan(for call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> PixelPostconditions.Plan? {
        guard let spec = OperationCatalog.shared.spec(call.id), spec.domains.contains(.photo), OperationGate.layerOperations.contains(call.id) else { return nil }
        var plan = PixelPostconditions.Plan()
        for condition in conditions(for: call, spec: spec) {
            guard case .pixels(let name, _) = condition, let probe = PixelProbe(rawValue: name) else { continue }
            if probe == .compositeUnchanged {
                plan.checks.append(PixelPostconditions.Check(PixelProbeRequest(.compositeUnchanged, region: .whole), .composite(changed: false)))
            } else if probe == .compositeChanged {
                if call.id == "addAdjustmentLayer", let layer = newLayer(before: before, after: after), PhotoOperationHandlers.isNeutralAdjustment(layer) {
                    plan.unverifiable.append("a neutral adjustment layer changes nothing yet")
                } else {
                    plan.checks.append(PixelPostconditions.Check(PixelProbeRequest(.compositeChanged, region: .whole), .composite(changed: true)))
                }
            } else if probe == .layerMaskCoverageInRange {
                // « ajoute un masque » with no area and no selection: a mask that shows everything, to paint on.
                let names = MaskAreaArgs(call.args, key: "where").namesSomething || call.args["useSelection"] != nil
                if call.id == "layerMask", (call.args["do"]?.string ?? "add") == "add", !names, before.selection == nil {
                    plan.unverifiable.append("a mask that shows everything, to paint on")
                    continue
                }
                plan.checks.append(PixelPostconditions.Check(PixelProbeRequest(.layerMaskCoverageInRange, region: .whole), .coverageInRange(mask: nil, target: nil)))
            }
        }
        return plan
    }

    /// The one layer a step added, nil when it added none or several.
    static func newLayer(before: PhotoDocument, after: PhotoDocument) -> Layer? {
        let old = Set(before.layers.map(\.id))
        let added = after.layers.filter { !old.contains($0.id) }
        return added.count == 1 ? added[0] : nil
    }
}
