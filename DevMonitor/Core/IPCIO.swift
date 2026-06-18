import Foundation
import Darwin

/// Blocking, line-delimited JSON socket I/O for the hub (used off the main actor). One JSON object
/// per line, `\n`-terminated — the same framing the `dev-monitor` CLI speaks.
enum IPCIO {
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    static func write(_ fd: Int32, _ message: IPCMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = Darwin.write(fd, base, raw.count) }
        }
    }
}
