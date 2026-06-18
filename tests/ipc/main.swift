import Foundation

// Tests the IPC surface end-to-end at the wire level: the Codable protocol contract (incl. the
// structured status fields) and a real framed write→read roundtrip through IPCIO over a pipe.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// 1) IPCMessage / IPCServerInfo Codable roundtrip — the agent-facing structured fields survive.
let info = IPCServerInfo(name: "dm", path: "/p", state: "Running · :3000", port: 3000,
    logPath: "/l.log", ready: true, url: "http://localhost:3000/", pid: 42, exitCode: nil, lastError: nil)
guard let encMsg = try? JSONEncoder().encode(IPCMessage(type: "status", servers: [info], message: nil)),
      let backMsg = try? JSONDecoder().decode(IPCMessage.self, from: encMsg),
      let bi = backMsg.servers?.first else { print("FAIL ipc: IPCMessage roundtrip"); exit(1) }
chk(backMsg.type == "status" && backMsg.servers?.count == 1, "IPCMessage roundtrip")
chk(bi.ready == true && bi.url == "http://localhost:3000/" && bi.pid == 42 && bi.port == 3000 && bi.logPath == "/l.log",
    "IPCServerInfo structured fields preserved")

// 2) IPCRequest roundtrip.
guard let encReq = try? JSONEncoder().encode(IPCRequest(cmd: "up", path: "/proj", name: nil, gb: 8, all: nil)),
      let backReq = try? JSONDecoder().decode(IPCRequest.self, from: encReq) else { print("FAIL ipc: IPCRequest roundtrip"); exit(1) }
chk(backReq.cmd == "up" && backReq.path == "/proj" && backReq.gb == 8, "IPCRequest roundtrip")

// 3) Real framed I/O through IPCIO over a pipe: write → readLine → decode (the hub's exact framing).
var fds = [Int32](repeating: 0, count: 2)
chk(pipe(&fds) == 0, "pipe created")
let rfd = fds[0], wfd = fds[1]
IPCIO.write(wfd, IPCMessage(type: "ok", servers: nil, message: "launched dm (Nuxt, 8 GB)"))
close(wfd)
let line = IPCIO.readLine(rfd)
close(rfd)
chk(line != nil, "readLine returned a frame")
let decoded = line.flatMap { try? JSONDecoder().decode(IPCMessage.self, from: $0) }
chk(decoded?.type == "ok" && decoded?.message == "launched dm (Nuxt, 8 GB)", "framed write→read roundtrip")

print(fail == 0 ? "ALL IPC TESTS PASSED" : "\(fail) IPC TEST(S) FAILED")
exit(Int32(fail))
