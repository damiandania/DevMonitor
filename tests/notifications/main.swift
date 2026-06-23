import Foundation

// Headless tests for the pure notification policy: gating by settings, event classification, throttle.

var fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("PASS \(msg)") } else { print("FAIL \(msg)"); fail = 1 }
}

// --- shouldNotify: master + per-category gating ---
var s = AppSettings()   // all notification flags default to true
check(NotificationPolicy.shouldNotify(.failures, s), "default: failures enabled")
check(NotificationPolicy.shouldNotify(.pressure, s), "default: pressure enabled")
s.notifyFailures = false
check(!NotificationPolicy.shouldNotify(.failures, s), "failures toggle gates failures")
check(NotificationPolicy.shouldNotify(.recovery, s), "other categories unaffected")
s.notificationsEnabled = false
check(!NotificationPolicy.shouldNotify(.recovery, s), "master off suppresses all (recovery)")
check(!NotificationPolicy.shouldNotify(.builds, s), "master off suppresses all (builds)")

// --- classify: event → (category, severity, action) ---
func cls(_ e: SupervisionEvent) -> (NotificationCategory, NotificationSeverity, NotificationAction) {
    NotificationPolicy.classify(e)
}
do { let (c, sev, a) = cls(.crashed(project: "x", code: 1))
     check(c == .failures && sev == .urgent && a == .restartOpen, "crashed → failures/urgent/restartOpen") }
do { let (c, sev, a) = cls(.failed(project: "x", reason: "boom"))
     check(c == .failures && sev == .urgent && a == .restartOpen, "failed → failures/urgent/restartOpen") }
do { let (c, sev, a) = cls(.oomRetry(project: "x", newHeapGB: 8))
     check(c == .failures && sev == .passive && a == .none, "oomRetry → failures/passive/none") }
do { let (c, sev, _) = cls(.hung(project: "x"))
     check(c == .failures && sev == .passive, "hung → failures/passive") }
do { let (c, _, _) = cls(.recycled(project: "x")); check(c == .recovery, "recycled → recovery") }
do { let (c, _, _) = cls(.recovered(project: "x")); check(c == .recovery, "recovered → recovery") }
do { let (c, sev, a) = cls(.buildFinished(project: "x", success: true))
     check(c == .builds && sev == .passive && a == .none, "build success → builds/passive/none") }
do { let (c, sev, a) = cls(.buildFinished(project: "x", success: false))
     check(c == .builds && sev == .urgent && a == .openLogs, "build failure → builds/urgent/openLogs") }

// --- make: title/body + carries the classification ---
let item = NotificationPolicy.make(from: .crashed(project: "Web", code: 9), projectID: nil)
check(item.title == "Dev server crashed" && item.body.contains("code 9"), "make: crashed title/body")
check(item.category == .failures && item.severity == .urgent && item.action == .restartOpen, "make: carries classification")
let oom = NotificationPolicy.make(from: .oomRetry(project: "Api", newHeapGB: 6), projectID: nil)
check(oom.body.contains("6 GB"), "make: oomRetry mentions the new heap")

// --- throttle ---
let now = Date()
check(!NotificationThrottle.shouldSuppress(key: "k", now: now, last: nil, window: 15), "no prior → not suppressed")
check(NotificationThrottle.shouldSuppress(key: "k", now: now, last: now.addingTimeInterval(-5), window: 15), "5s ago within 15s → suppressed")
check(!NotificationThrottle.shouldSuppress(key: "k", now: now, last: now.addingTimeInterval(-20), window: 15), "20s ago → not suppressed")

print(fail == 0 ? "ALL NOTIFICATIONS TESTS PASSED" : "SOME NOTIFICATIONS TESTS FAILED")
exit(Int32(fail))
