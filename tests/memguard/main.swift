import Foundation

// Tests the pure memory-headroom logic: MemoryGuard.launchWarning + swapCrossing. Headless.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let GB = 1_073_741_824.0

// --- launchWarning ---
// Plenty of free RAM, low swap → no warning.
chk(MemoryGuard.launchWarning(heapGB: 4, memUsed: 2 * GB, memTotal: 16 * GB, swapUsed: 0, swapTotal: 4 * GB) == nil,
    "launchWarning: ample headroom → nil")

// Heap bigger than free RAM → warns about the heap.
let tight = MemoryGuard.launchWarning(heapGB: 4, memUsed: 6 * GB, memTotal: 8 * GB, swapUsed: 0, swapTotal: 4 * GB)
chk(tight != nil && tight!.contains("heap"), "launchWarning: heap > free RAM warns", tight ?? "nil")

// High swap alone (heap fits) → warns about swap.
let swampy = MemoryGuard.launchWarning(heapGB: 1, memUsed: 2 * GB, memTotal: 8 * GB, swapUsed: 3.5 * GB, swapTotal: 4 * GB)
chk(swampy != nil && swampy!.contains("swap"), "launchWarning: high swap warns", swampy ?? "nil")

// Both problems → mentions both.
let both = MemoryGuard.launchWarning(heapGB: 8, memUsed: 6 * GB, memTotal: 8 * GB, swapUsed: 3 * GB, swapTotal: 4 * GB)
chk(both != nil && both!.contains("heap") && both!.contains("swap"), "launchWarning: both reasons listed", both ?? "nil")

// No swap device (swapTotal 0) must not divide-by-zero; heap fits → nil.
chk(MemoryGuard.launchWarning(heapGB: 2, memUsed: 2 * GB, memTotal: 8 * GB, swapUsed: 0, swapTotal: 0) == nil,
    "launchWarning: swapTotal=0 guarded")

// --- swapCrossing (edge trigger + hysteresis) ---
var r = MemoryGuard.swapCrossing(swapPercent: 40, wasWarned: false)
chk(r == (false, false), "swap: below threshold, not warned → stays quiet", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 65, wasWarned: false)
chk(r == (true, true), "swap: crossing above threshold → warn once", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 70, wasWarned: true)
chk(r == (false, true), "swap: still high, already warned → no repeat", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 55, wasWarned: true)
chk(r == (false, true), "swap: dipped but within hysteresis → stay armed", "\(r)")
r = MemoryGuard.swapCrossing(swapPercent: 45, wasWarned: true)
chk(r == (false, false), "swap: dropped below threshold-hysteresis → re-arm", "\(r)")

print(fail == 0 ? "ALL MEMGUARD TESTS PASSED" : "\(fail) MEMGUARD TEST(S) FAILED")
exit(Int32(fail))
