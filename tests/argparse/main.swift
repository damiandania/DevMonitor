import Foundation

// Tests the CLI argument parser (DMParse) — the regressions behind the broken `--gb` handling,
// silently-ignored unknown flags, and unresolved relative paths.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// --gb consumes its value in ANY position and validates a positive integer.
let g1 = DMParse.parse(["--gb", "8", "/proj"], boolFlags: [], allowGB: true)
chk(g1.error == nil && g1.gb == 8 && g1.positionals == ["/proj"], "gb before path", g1.error ?? "")
let g2 = DMParse.parse(["/proj", "--gb", "8"], boolFlags: [], allowGB: true)
chk(g2.error == nil && g2.gb == 8 && g2.positionals == ["/proj"], "gb after path")
let g3 = DMParse.parse(["--gb=4"], boolFlags: [], allowGB: true)
chk(g3.error == nil && g3.gb == 4, "gb= form")

// Malformed --gb fails loudly (was: treated 'abc' as a path, '0' as a project name).
chk(DMParse.parse(["--gb", "abc"], boolFlags: [], allowGB: true).error != nil, "gb abc rejected")
chk(DMParse.parse(["--gb", "0"], boolFlags: [], allowGB: true).error != nil, "gb 0 rejected")
chk(DMParse.parse(["--gb", "-5"], boolFlags: [], allowGB: true).error != nil, "gb -5 rejected")
chk(DMParse.parse(["--gb"], boolFlags: [], allowGB: true).error != nil, "gb missing value rejected")

// A bare positional that isn't a --gb value is preserved.
let p1 = DMParse.parse(["abc"], boolFlags: [], allowGB: true)
chk(p1.error == nil && p1.positionals == ["abc"], "bare positional kept")

// Unknown flags are rejected, not silently ignored.
chk(DMParse.parse(["--bogus"], boolFlags: ["--json"], allowGB: false).error != nil, "unknown flag rejected")
let u2 = DMParse.parse(["--json"], boolFlags: ["--json"], allowGB: false)
chk(u2.error == nil && u2.flags.contains("--json"), "known bool flag accepted")
let w = DMParse.parse(["/proj", "--gb", "8", "--wait"], boolFlags: ["--wait"], allowGB: true)
chk(w.error == nil && w.gb == 8 && w.flags.contains("--wait") && w.positionals == ["/proj"], "up --gb N --wait together")
chk(DMParse.parse(["--gb", "8"], boolFlags: [], allowGB: false).error != nil, "gb rejected when command disallows it")

// Path resolution: relative resolves against cwd, normalizes, leaves absolute alone.
chk(DMParse.absolutePath("/a/b") == "/a/b", "abs stays abs")
chk(DMParse.absolutePath("foo", cwd: "/work") == "/work/foo", "relative resolves against cwd")
chk(DMParse.absolutePath("../x", cwd: "/work/sub") == "/work/x", "normalizes ..")

print(fail == 0 ? "ALL ARGPARSE TESTS PASSED" : "\(fail) ARGPARSE TEST(S) FAILED")
exit(Int32(fail))
