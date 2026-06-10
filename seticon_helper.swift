import AppKit
import Foundation

/// Usage:
///   seticon set <appPath> <iconPath> <uid> <gid>
///   seticon remove <appPath> <uid> <gid>
///
/// When run as root (via osascript with administrator privileges),
/// the uid/gid arguments specify the end-user to chown the app to
/// after the setIcon operation.  This ensures future setIcon calls
/// from the user context succeed without admin escalation.

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("Usage: seticon set|remove <appPath> [iconPath] <uid> <gid>")
    exit(1)
}

let command = args[1]
let appPath = args[2]

// Recursively chown an .app bundle so the user owns it
func takeOwnership(_ path: String, uid: uid_t, gid: gid_t) {
    chown(path, uid, gid)
    if let enumerator = FileManager.default.enumerator(atPath: path) {
        while let file = enumerator.nextObject() as? String {
            chown(path + "/" + file, uid, gid)
        }
    }
}

switch command {
case "set":
    guard args.count >= 6 else { print("FAIL: missing icon path or uid/gid"); exit(1) }
    let iconPath = args[3]
    let uid = uid_t(args[4]) ?? 501
    let gid = gid_t(args[5]) ?? 20

    guard let img = NSImage(contentsOfFile: iconPath) else {
        print("FAIL: cannot load image")
        exit(1)
    }

    takeOwnership(appPath, uid: uid, gid: gid)
    let ok = NSWorkspace.shared.setIcon(img, forFile: appPath, options: [])
    print(ok ? "OK (chowned \(uid):\(gid))" : "FAIL: setIcon returned false")
    exit(ok ? 0 : 1)

case "remove":
    guard args.count >= 5 else { print("FAIL: missing uid/gid"); exit(1) }
    let uid = uid_t(args[4]) ?? 501
    let gid = gid_t(args[5]) ?? 20

    takeOwnership(appPath, uid: uid, gid: gid)
    NSWorkspace.shared.setIcon(nil, forFile: appPath, options: [])
    print("OK (chowned \(uid):\(gid))")
    exit(0)

default:
    print("FAIL: unknown command")
    exit(1)
}
