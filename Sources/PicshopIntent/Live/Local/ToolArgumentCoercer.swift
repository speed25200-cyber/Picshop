import Foundation
import PicshopCore

/// Turns a local model's tool arguments into the strict JSON ToolInputValidator expects.
///
/// Phase 0: the frozen signature; the arguments are passed through unchanged.
/// Phase 1 coerces arrays and numbers sent as strings, points given in 0...1000
/// and nulls before validation.
public enum ToolArgumentCoercer {
    /// Model arguments (arrays or numbers sent as strings, points in 0...1000, nulls) → the strict JSON ToolInputValidator expects.
    public static func rawToolUse(id: String, name: String, arguments: JSONValue) -> RawToolUse {
        RawToolUse(id: id, name: name, rawInput: arguments.serialized())
    }
}
