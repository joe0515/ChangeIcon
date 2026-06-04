import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: seticon set|remove <appPath> [iconPath]")
    exit(1)
}

let command = args[1]
let appPath = args[2]

switch command {
case "set":
    guard args.count >= 4 else { print("FAIL: missing icon path"); exit(1) }
    let iconPath = args[3]
    guard let img = NSImage(contentsOfFile: iconPath) else {
        print("FAIL: cannot load image")
        exit(1)
    }
    let ok = NSWorkspace.shared.setIcon(img, forFile: appPath, options: [])
    print(ok ? "OK" : "FAIL: setIcon returned false")
    exit(ok ? 0 : 1)

case "remove":
    NSWorkspace.shared.setIcon(nil, forFile: appPath, options: [])
    // setIcon with nil always returns false per docs, but it does clear the icon
    print("OK")
    exit(0)

default:
    print("FAIL: unknown command")
    exit(1)
}
