import Foundation

// Tests GitInfo.branch — parsing .git/HEAD (branch ref, detached SHA, non-repo).

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

func tmpRepo(_ name: String, head: String) -> String {
    let dir = NSTemporaryDirectory() + name
    try? FileManager.default.removeItem(atPath: dir)
    try? FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
    try? head.write(toFile: dir + "/.git/HEAD", atomically: true, encoding: .utf8)
    return dir
}

let onRef = tmpRepo("dm-git-ref", head: "ref: refs/heads/feature/x\n")
chk(GitInfo.branch(for: onRef) == "feature/x", "branch from ref", GitInfo.branch(for: onRef) ?? "nil")

let detached = tmpRepo("dm-git-det", head: "0123456789abcdef0123\n")
chk(GitInfo.branch(for: detached) == "0123456", "detached HEAD → short SHA", GitInfo.branch(for: detached) ?? "nil")

chk(GitInfo.branch(for: "/no/such/dm-git-xyz") == nil, "non-repo path → nil")

print(fail == 0 ? "ALL GIT TESTS PASSED" : "\(fail) GIT TEST(S) FAILED")
exit(Int32(fail))
