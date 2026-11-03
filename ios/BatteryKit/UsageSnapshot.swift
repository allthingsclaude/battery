import Foundation

/// A point-in-time usage sample. On macOS these are persisted to SQLite; on iOS
/// the app keeps a small in-memory ring buffer of them purely to feed the burn
/// rate regression, so no database is required on the phone.
///
/// Field set is a subset of the macOS `UsageSnapshot` — only what
/// `BurnRateCalculator` reads (`timestamp`, `sessionUtilization`, `sessionResetsAt`).
///
/// Despite their names, the two value fields hold whichever window was
/// *primary* when the sample was taken — the weekly window for an account with
/// no five-hour limit. `window` records which, so the buffer never regresses
/// one window's samples against the other's. (The names stay as they are to
/// keep the persisted buffer readable across the update.)
struct UsageSnapshot: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionUtilization: Double
    let sessionResetsAt: Date
    /// nil on samples recorded before weekly-only accounts existed — every one
    /// of those was a session sample.
    let window: UsagePayload.FocusWindow?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionUtilization: Double,
        sessionResetsAt: Date,
        window: UsagePayload.FocusWindow = .session
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
        self.window = window
    }

    /// The window this sample measured.
    var recordedWindow: UsagePayload.FocusWindow { window ?? .session }
}
