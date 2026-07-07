import Foundation

// Tests the pure logic behind the toolbar's countdown ring: SleepGuard.remainingFraction.
// The IOKit power-assertion side (enable/disable actually holding/releasing sleep) is exercised
// live, not here — see the scratch harnesses used during development.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let now = Date()

chk(SleepGuard.remainingFraction(activeUntil: nil, totalDuration: nil, now: now) == nil,
    "remainingFraction: inactive (no deadline) → nil")
chk(SleepGuard.remainingFraction(activeUntil: now.addingTimeInterval(900), totalDuration: nil, now: now) == nil,
    "remainingFraction: indefinite (no total duration) → nil")

let justStarted = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(900), totalDuration: 900, now: now)
chk(justStarted.map { abs($0 - 1.0) < 0.001 } ?? false, "remainingFraction: just enabled → ~1.0", "\(String(describing: justStarted))")

let halfway = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(450), totalDuration: 900, now: now)
chk(halfway.map { abs($0 - 0.5) < 0.001 } ?? false, "remainingFraction: halfway → ~0.5", "\(String(describing: halfway))")

let aboutToExpire = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(1), totalDuration: 900, now: now)
chk(aboutToExpire.map { $0 > 0 && $0 < 0.01 } ?? false, "remainingFraction: about to expire → near 0", "\(String(describing: aboutToExpire))")

let expired = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(-5), totalDuration: 900, now: now)
chk(expired == 0, "remainingFraction: past the deadline clamps at 0 (never negative)", "\(String(describing: expired))")

let overdue = SleepGuard.remainingFraction(
    activeUntil: now.addingTimeInterval(950), totalDuration: 900, now: now)
chk(overdue == 1, "remainingFraction: re-armed past the original total clamps at 1 (never over)", "\(String(describing: overdue))")

print(fail == 0 ? "ALL SLEEPGUARD TESTS PASSED" : "\(fail) SLEEPGUARD TEST(S) FAILED")
exit(Int32(fail))
