//
//  dix-app-shots
//
//  Renders the app's windows OFFSCREEN to PNG (no window is ever ordered
//  front, nothing appears on screen) and measures the document window with a
//  real snapshot: open time, outline scrolling, zoom/relayout.
//
//    dix-app-shots <snap.dixsnap> -o <dir> [--size 1100x720] [--dark] [--only main,drives,...]
//
//  GPL v3
//

import AppKit
import DIXApp

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i ... i + 1)
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
let outDir = URL(fileURLWithPath: option("-o") ?? ".")
let size = (option("--size") ?? "1100x720").split(separator: "x").compactMap { Double($0) }
let dark = flag("--dark")
let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
guard let snapPath = args.first else {
    print("usage: dix-app-shots <snap.dixsnap> -o <dir> [--size WxH] [--dark] [--only main,drives,progress,kinds,info,selection,perf,zoomed,highlight,logical]")
    exit(2)
}
NSApplication.shared.setActivationPolicy(.prohibited)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
if snapPath == "--cloud-fixture" {
    OffscreenShots(outDir: outDir, dark: dark).runCloudFixture(size: NSSize(width: size.first ?? 1100, height: size.last ?? 720))
    exit(0)
}
OffscreenShots(outDir: outDir, dark: dark).run(snapshotURL: URL(fileURLWithPath: snapPath),
                                               size: NSSize(width: size.first ?? 1100, height: size.last ?? 720), only: only)
