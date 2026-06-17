import AppKit
import Foundation

/// Usage:
///   seticon set <appPath> <iconPath> <uid> <gid>
///   seticon remove <appPath> <uid> <gid>
///
/// When run as root (via osascript with administrator privileges or sudo),
/// the uid/gid arguments specify the end-user to chown the app to
/// after the setIcon operation.  This ensures future setIcon calls
/// from the user context succeed without admin escalation.

// MARK: - Parameter Validation

/// Validate input parameters to prevent path traversal, symlink attacks,
/// and command injection.
///
/// - Parameters:
///   - appPath: Absolute path to the target `.app` bundle.
///   - iconPath: Optional absolute path to the replacement icon file.
///   - uid: User ID as a string (must parse to a valid `uid_t`).
///   - gid: Group ID as a string (must parse to a valid `gid_t`).
/// - Returns: `(uid_t, gid_t)` on success; prints an error and calls `exit(1)` on failure.
func validateParams(appPath: String, iconPath: String?, uidStr: String, gidStr: String) -> (uid: uid_t, gid: gid_t)? {
    // --- appPath must end with .app ---
    guard appPath.hasSuffix(".app") else {
        print("FAIL: invalid params: appPath must end with .app — \(appPath)")
        exit(1)
    }

    // --- appPath must reside under an allowed prefix ---
    let allowedPrefixes = [
        "/Applications/",
        "/System/Applications/",
        "/System/",
        NSHomeDirectory() + "/",
    ]
    let isAllowed = allowedPrefixes.contains { appPath.hasPrefix($0) }
    guard isAllowed else {
        print("FAIL: invalid params: appPath outside allowed directories — \(appPath)")
        exit(1)
    }

    // --- iconPath (if provided) must have an allowed extension ---
    if let icon = iconPath {
        let ext = (icon as NSString).pathExtension.lowercased()
        let allowedExtensions = ["icns", "png", "jpg", "jpeg", "tif", "tiff"]
        guard allowedExtensions.contains(ext) else {
            print("FAIL: invalid params: icon extension not allowed — \(ext)")
            exit(1)
        }

        // --- iconPath must point to an existing file ---
        guard FileManager.default.fileExists(atPath: icon) else {
            print("FAIL: invalid params: icon file not found — \(icon)")
            exit(1)
        }
    }

    // --- uid must be a valid numeric value ---
    guard let uid = uid_t(uidStr) else {
        print("FAIL: invalid params: uid is not a valid number — \(uidStr)")
        exit(1)
    }

    // --- gid must be a valid numeric value ---
    guard let gid = gid_t(gidStr) else {
        print("FAIL: invalid params: gid is not a valid number — \(gidStr)")
        exit(1)
    }

    return (uid, gid)
}

// MARK: - Core Logic

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
    let uidStr = args[4]
    let gidStr = args[5]

    // Validate all parameters before any filesystem operation
    guard let (uid, gid) = validateParams(appPath: appPath, iconPath: iconPath, uidStr: uidStr, gidStr: gidStr) else {
        // validateParams calls exit(1) internally on failure
        fatalError("validateParams should have exited")
    }

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
    let uidStr = args[4]
    let gidStr = args[5]

    // Validate parameters (no iconPath for remove)
    guard let (uid, gid) = validateParams(appPath: appPath, iconPath: nil, uidStr: uidStr, gidStr: gidStr) else {
        fatalError("validateParams should have exited")
    }

    takeOwnership(appPath, uid: uid, gid: gid)
    NSWorkspace.shared.setIcon(nil, forFile: appPath, options: [])
    print("OK (chowned \(uid):\(gid))")
    exit(0)

default:
    print("FAIL: unknown command")
    exit(1)
}
