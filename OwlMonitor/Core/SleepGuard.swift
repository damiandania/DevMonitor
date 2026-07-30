import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping AND from dimming/sleeping its display — the same pair of IOKit
/// power-management assertions `caffeinate -d -i` holds — so a long build or dev session isn't cut
/// off mid-way. Enabled for a fixed duration or indefinitely; session-only (never persisted, so a
/// relaunch always starts back in "allowed to sleep") and released on quit (`AppState.shutdown`) so
/// nothing outlives the app (macOS would also auto-release the assertions if the process died some
/// other way).
@MainActor
@Observable
final class SleepGuard {
    private(set) var isActive = false
    /// When the guard will turn itself off; nil while active means "indefinitely".
    private(set) var activeUntil: Date?
    /// The duration `enable(for:)` was called with — needed alongside `activeUntil` to compute the
    /// toolbar ring's remaining-time FRACTION (a bare deadline alone gives remaining time, not the
    /// proportion of the original duration). nil while active means "indefinitely" (no ring).
    private(set) var totalDuration: TimeInterval?
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var autoOffTask: Task<Void, Never>?

    /// Enable for `duration` seconds, or indefinitely when `duration` is nil. Re-arms cleanly if
    /// already active (e.g. picking a new duration while it's running).
    func enable(for duration: TimeInterval? = nil) {
        disable()
        let reason = "Owl Monitor: keep awake enabled" as CFString
        var sysID: IOPMAssertionID = 0
        var dispID: IOPMAssertionID = 0
        let sysOK = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &sysID) == kIOReturnSuccess
        let dispOK = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &dispID) == kIOReturnSuccess
        guard sysOK || dispOK else { return }   // both failed — nothing held, stay off
        systemAssertionID = sysOK ? sysID : 0
        displayAssertionID = dispOK ? dispID : 0
        isActive = true
        guard let duration else { return }
        totalDuration = duration
        activeUntil = Date().addingTimeInterval(duration)
        autoOffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.disable()
        }
    }

    func disable() {
        autoOffTask?.cancel()
        autoOffTask = nil
        guard isActive else { return }
        if systemAssertionID != 0 { IOPMAssertionRelease(systemAssertionID); systemAssertionID = 0 }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID); displayAssertionID = 0 }
        isActive = false
        activeUntil = nil
        totalDuration = nil
    }

    /// Fraction of the chosen duration still remaining (1 = just started, 0 = about to expire); nil
    /// while inactive or running indefinitely (nothing to show a ring for).
    nonisolated static func remainingFraction(activeUntil: Date?, totalDuration: TimeInterval?, now: Date) -> Double? {
        guard let activeUntil, let totalDuration, totalDuration > 0 else { return nil }
        return max(0, min(1, activeUntil.timeIntervalSince(now) / totalDuration))
    }
}
