import WidgetKit
import SwiftUI

/// The extension's entry point. Bundles the Home Screen widget, the Lock Screen
/// accessory widgets, and — on iOS 16.2+ — the session Live Activity.
@main
struct BatteryWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionWidget()     // small square — 5-hour session
        WeeklyWidget()      // small square — 7-day weekly
        OverviewWidget()    // medium — both windows + Opus
        LockScreenWidget()
        liveActivity
    }

    @WidgetBundleBuilder
    private var liveActivity: some Widget {
        if #available(iOS 16.2, *) {
            UsageLiveActivity()
        }
    }
}
