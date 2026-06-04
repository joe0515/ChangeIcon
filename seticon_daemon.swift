import Foundation
import AppKit

let fm = FileManager.default

// Use shared location accessible by both root and user
let commandDir = URL(fileURLWithPath: "/Users/Shared/.ChangeIcon/Commands")
try? fm.createDirectory(at: commandDir, withIntermediateDirectories: true)

let commandFile = commandDir.appendingPathComponent("pending.json")
let resultFile = commandDir.appendingPathComponent("result.txt")
let logFile = commandDir.appendingPathComponent("daemon.log")

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let d = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else { try? d.write(to: logFile, options: .atomic) }
    }
    // Also print for launchd log
    print(msg)
}

log("STARTED uid=\(getuid()) euid=\(geteuid())")

while true {
    autoreleasepool {
        if fm.fileExists(atPath: commandFile.path) {
            do {
                let data = try Data(contentsOf: commandFile)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
                   let cmd = json["command"], let app = json["app"] {

                    var result = "UNKNOWN"

                    if cmd == "set", let icon = json["icon"] {
                        log("SET \(app) ← \(icon)")
                        if let img = NSImage(contentsOfFile: icon) {
                            let ok = NSWorkspace.shared.setIcon(img, forFile: app, options: [])
                            result = ok ? "OK" : "FAIL: setIcon=false"
                            log("result=\(result)")

                            // Notify system
                            let ls = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                            if fm.fileExists(atPath: ls) {
                                let p = Process(); p.executableURL = URL(fileURLWithPath: ls)
                                p.arguments = ["-f", app]; try? p.run(); p.waitUntilExit()
                            }
                            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
                            t.arguments = [app]; try? t.run(); t.waitUntilExit()
                        } else {
                            result = "FAIL: cannot load \(icon)"
                            log(result)
                        }
                    } else if cmd == "remove" {
                        log("REMOVE \(app)")
                        NSWorkspace.shared.setIcon(nil, forFile: app, options: [])
                        result = "OK"
                        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
                        t.arguments = [app]; try? t.run(); t.waitUntilExit()
                    }

                    try result.write(to: resultFile, atomically: true, encoding: .utf8)
                }
                try fm.removeItem(at: commandFile)
            } catch {
                log("ERROR: \(error.localizedDescription)")
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
}
