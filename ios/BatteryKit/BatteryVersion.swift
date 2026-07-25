import Foundation

/// The shipped version, read from the bundle rather than written down.
///
/// It used to be a literal in two places, which meant every release silently
/// left the User-Agent claiming whatever the last person to edit it had typed —
/// the kind of drift nobody notices because nothing breaks. `MARKETING_VERSION`
/// is already the single source of truth (`ios/project.yml`, overridden by the
/// release tag in CI), and both Info.plists reference it, so reading it back
/// out is exact by construction.
///
/// `Bundle.main` resolves to the app in the app process and to the `.appex` in
/// the widget/Live Activity process — both carry the same version, because App
/// Store Connect rejects a bundle whose embedded extension disagrees with its
/// host.
enum BatteryVersion {

    /// e.g. "0.7.3". Falls back to "0" only if the key is somehow absent, which
    /// would mean a malformed bundle.
    static let short: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// The build number — commit count in CI, "1" for a local build.
    static let build: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    /// What we send as `User-Agent` on every API and relay call.
    static let userAgent = "Battery-iOS/\(short)"
}
