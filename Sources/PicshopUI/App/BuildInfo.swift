import Foundation

/// Which build is running: version, build number and the git stamp written
/// by Scripts/build-stamp.sh on CI. Shown in the Home header and Settings so
/// a screenshot always says which code it comes from.
public enum BuildInfo {
    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    public static var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    public static var commit: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PSBuildCommit") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "local" : value
    }
    public static var branch: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PSBuildBranch") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "" : value
    }
    public static var date: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PSBuildDate") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "" : value
    }
    /// "1.0.0 (42) · a1b2c3d" — the line to quote when reporting a bug.
    public static var stamp: String { "\(version) (\(buildNumber)) · \(commit)" }
}
