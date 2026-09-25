import Foundation

/// FNV-1a 64-bit: a hash that is the same on every launch and every device, unlike `Hasher`.
/// Keys that are stored (table memory) or compared across sessions (scene map ids) use it.
public enum StableHash {
    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let prime: UInt64 = 0x0000_0100_0000_01b3

    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// 16 lower-case hex digits.
    public static func hex(_ string: String) -> String {
        let value = fnv1a64(string)
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    /// A number written the same way everywhere: fixed decimals, no locale, no "-0".
    public static func token(_ value: Double, decimals: Int = 4) -> String {
        guard value.isFinite else { return "nan" }
        let scale = pow(10, Double(max(0, min(decimals, 9))))
        let rounded = (value * scale).rounded() / scale
        let text = String(format: "%.\(max(0, min(decimals, 9)))f", rounded == 0 ? 0 : rounded)
        return text
    }
}
